#!/usr/bin/env python3
"""带密码认证的本地命令执行（pty 驱动）——用于 ssh / scp / rsync 到需要密码的远端。

WSL 环境既无 sshpass 也无 SSH key（远端 home 目录可能不存在、无法放 authorized_keys），
本脚本用 pty 运行本地命令，在出现 "password" 提示时自动输入（只输入一次）。

用法:
    SSH_PASS='<密码>' python3 scripts/ssh-pass.py -- ssh -p 22 user@host 'cmd'
    SSH_PASS='<密码>' python3 scripts/ssh-pass.py -- rsync -av --delete -e 'ssh -p 22' \
        ./feed-out/ user@host:/path/to/target/
    # 也可用 --password-env NAME 指定别的环境变量名

注意: 密码只经环境变量传入（不落盘、不进 git）；输出实时透传，退出码原样返回。
"""
import argparse
import os
import pty
import select
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--password-env", default="SSH_PASS", help="携带密码的环境变量名（默认 SSH_PASS）")
    ap.add_argument("--timeout", type=float, default=3600.0, help="总超时秒数（默认 3600）")
    ap.add_argument("cmd", nargs=argparse.REMAINDER, help="-- 之后的命令")
    a = ap.parse_args()

    cmd = a.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        ap.error("需要在 -- 之后给出命令，如：-- rsync -av src/ user@host:/path/")

    pw = os.environ.get(a.password_env, "")
    if not pw:
        sys.stderr.write(f"警告：环境变量 {a.password_env} 为空（若远端不需要密码可忽略）\n")

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.execvp(cmd[0], cmd)

    sent = False
    hostkey = False
    buf = b""
    start = time.time()
    while time.time() - start < a.timeout:
        r, _, _ = select.select([fd], [], [], 1)
        if not r:
            continue
        try:
            data = os.read(fd, 8192)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        buf += data
        # 首次连接的主机密钥确认（yes/no）——自动接受（与 password 分开判定）
        if not hostkey and (b"are you sure you want to continue connecting" in buf.lower()
                            or b"(yes/no" in buf.lower()):
            os.write(fd, b"yes\n")
            hostkey = True
            buf = b""
            continue
        if not sent and b"password" in buf.lower():
            os.write(fd, (pw + "\n").encode())
            sent = True

    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
