#!/usr/bin/env python3
"""VM 命令通道（WP-9 OTA 演练用；派生自 quartz-daemon/dev/vm-ssh.py）。

WSL 环境既无 sshpass 也无 SSH key，本脚本用 pty 驱动 ssh 并在密码提示出现时
自动输入。密码按候选序列尝试（全新镜像空口令 / test-in-vm.sh 约定的 quartz）。

用法:
    python3 scripts/vm-ssh-pass.py 'ubus call system.board'
    python3 scripts/vm-ssh-pass.py --fetch /etc/quartz-build-id
    VM_SSH_PORT=2322 VM_PASSES='quartz,' python3 scripts/vm-ssh-pass.py 'true'

退出码: 远端命令退出码（经 __EXIT__ 标记回传）。
"""
import argparse
import os
import pty
import select
import sys
import time

VM_HOST = os.environ.get("VM_HOST", "127.0.0.1")
VM_PORT = os.environ.get("VM_SSH_PORT", "2222")
VM_USER = os.environ.get("VM_USER", "root")
VM_PASSES = os.environ.get("VM_PASSES", "quartz,").split(",")


def _run_once(passwd: str, remote_cmd: str, timeout: float) -> tuple[int, bytes]:
    wrapped = f"{remote_cmd}\necho __EXIT__$?\n"
    cmd = [
        "ssh", "-p", VM_PORT,
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
        "-o", "LogLevel=ERROR",
        f"{VM_USER}@{VM_HOST}", wrapped,
    ]
    pid, fd = pty.fork()
    if pid == 0:  # child
        os.execvp(cmd[0], cmd)
    buf = b""
    sent = False
    start = time.time()
    while time.time() - start < timeout:
        r, _, _ = select.select([fd], [], [], 1)
        if r:
            try:
                data = os.read(fd, 8192)
            except OSError:
                break
            if not data:
                break
            buf += data
            if (not sent) and (b"password" in buf.lower()):
                os.write(fd, (passwd + "\n").encode())
                sent = True
    if b"password" in buf.lower():
        idx = buf.lower().rfind(b"password")
        nl = buf.find(b"\n", idx)
        if 0 <= nl < 512:
            buf = buf[nl + 1:]
    code = 255
    marker = b"__EXIT__"
    if marker in buf:
        tail = buf.rsplit(marker, 1)[1].strip().split(b"\n")[0]
        try:
            code = int(tail)
        except ValueError:
            pass
        buf = buf.rsplit(marker, 1)[0]
    return code, buf


def run_remote(remote_cmd: str, timeout: float = 60.0) -> tuple[int, bytes]:
    last = (255, b"")
    for pw in VM_PASSES:
        code, out = _run_once(pw, remote_cmd, timeout)
        if code != 255:
            return code, out
        last = (code, out)
    return last


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", nargs="?", help="remote command (single string)")
    ap.add_argument("--fetch", help="remote file path to fetch via cat")
    ap.add_argument("--out", help="local output path for --fetch (default stdout)")
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()

    if args.fetch:
        code, out = run_remote(f"cat {args.fetch}", args.timeout)
        if code != 0:
            sys.stderr.write(out.decode(errors="replace"))
            return code
        if args.out:
            with open(args.out, "wb") as f:
                f.write(out)
            print(f"fetched {args.fetch} -> {args.out} ({len(out)} bytes)", file=sys.stderr)
        else:
            sys.stdout.buffer.write(out)
        return 0

    if not args.command:
        ap.error("need COMMAND or --fetch")
    code, out = run_remote(args.command, args.timeout)
    sys.stdout.buffer.write(out)
    return code


if __name__ == "__main__":
    sys.exit(main())
