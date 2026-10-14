#!/usr/bin/env bash
# apk 公钥 key id 计算（WP-9 共用；被 gen/inject/verify/publish 脚本 source）
#
# apk 源码 crypto_openssl.c apk_pkey_init：key id = sha512(i2d_PublicKey(pkey))[:16]，
# 对 EC 密钥即 sha512(**EC 原始点**，65 字节 0x04||X||Y)[:16]——apk 索引签名块
# `# sig v00 h04 <id>...` 的前 16 字节即该值，设备端 apk 用 /etc/apk/keys/*.pem 的
# 同款计算做匹配。
#
# 注意（实测坑）：`openssl ec -text` 的 "ASN1 OID: prime256v1" 行既带冒号又含十六进制
# 字符（e/2/5/6…）——按冒号过滤会把它混进来，导致 key id 计算错位（实测踩中）。
# 因此只取 `pub:` 与 `ASN1` 之间的十六进制行，用 awk 状态机精确切分。

quartz_apk_key_id() { # $1 = 公钥 PEM 路径
  openssl ec -pubin -in "$1" -text -noout 2>/dev/null |
    awk '/^pub:/{f=1;next} /^ASN1/{f=0} f' | tr -d ' :\n' |
    python3 -c 'import sys,hashlib; d=sys.stdin.read().strip(); print(hashlib.sha512(bytes.fromhex(d)).hexdigest()[:32])'
}
