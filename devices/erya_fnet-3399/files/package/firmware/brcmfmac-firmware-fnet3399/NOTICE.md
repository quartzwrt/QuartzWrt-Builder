# FNet3399 AP6236（BCM43430B0）固件包 —— 来源与已知事项

## 来源

文件集与 Lemon1151/iStoreOS-RK3399 的
`fnet3399/packages/brcmfmac-firmware-fnet3399/` 逐字节一致（该移植的 model/compatible
与厂商 DTS 完全对齐：`erya,fnet-3399`，即本板专用移植）；其 PKG_SOURCE 为
`https://github.com/yizhanghong/rk3399-firmware.git` @ `ee9df54cab893ccf4c4030b6b813f9741fcb8687`
（该仓库为 ophub/firmware 系 RK3399 盒子固件集，含 AP6236 全套）。

## 文件清单（md5）

| 文件 | 字节 | md5 | 用途 |
| :--- | ---: | :--- | :--- |
| `brcmfmac43430b0-sdio.bin` | 428559 | `2e11f71a4e26ae3c8a18b63df18c989c` | brcmfmac SDIO 固件镜像（43430 rev≥2 → 43430B0） |
| `brcmfmac43430b0-sdio.txt` | 1147 | `6fef80454a2d6dd1a1d7bbbd624b7c0e` | 通用 NVRAM（模板占位 MAC `00:90:4c:c5:12:38`，内核检测到后会随机化） |
| `brcmfmac43430b0-sdio.erya,fnet-3399.txt` | 1147 | `99528d28ec7c65cd9c2d871d47f2ebb0` | 板级 NVRAM（board_type = 根 compatible 首串，`macaddr=06:2D:EE:BC:F2:C7`，本地管理地址） |
| `brcmfmac43430-sdio.clm_blob` | 7222 | `df4e4bdab69ca682a68d880cfd6ced24` | 厂商随包 CLM 数据（命名沿用厂商旧习惯，见下） |
| `BCM43430B0.hcd` | 46538 | `a59a27a46335037e67c3ff26765f8c04` | 蓝牙 patchram（btbcm，subver 0x410c → BCM43430B0） |
| `LICENSE` | — | — | Broadcom 二进制固件许可（linux-firmware `LICENCE.broadcom_bcm43xx`，允许原样再分发） |

注：iStoreOS 包里还有一个 `brcmfmac43430b0-sdio.erya,fnet-3399.bin`，与本包通用
`brcmfmac43430b0-sdio.bin` md5 相同（逐字节一致），故不重复投放——brcmfmac 板级名缺失时
自动回落通用名（`firmware.c`：先试 `<名>.<board_type>.<ext>`，失败 `fallback` 到 `<名>.<ext>`）。

## 已知事项（复核时勿误判）

1. **CLM blob 命名**：本包沿用厂商原名 `brcmfmac43430-sdio.clm_blob`。当前内核（6.12）该芯片
   实际查找名是 `brcmfmac43430b0-sdio.clm_blob`，即本文件不会被动加载（CLM 为可选件，
   缺失不致命，仅日志 `no clm_blob available`）。**不要为"修好"而改名**：CLM 下载失败在
   brcmfmac 中是致命错误（`common.c` → `brcmf_c_preinit_dcmds` 失败即无线起不来），
   而现有一份并非为该芯片校验的 CLM 是否会被 dongle 接受未经真机验证。
2. **NVRAM MAC**：板级 NVRAM 固定 `macaddr=06:2D:EE:BC:F2:C7`（本地管理地址），所有刷同版
   固件的机器会共用该 MAC；单机使用无碍，多机同网需在 `/etc/config/wireless` 里用
   `option macaddr` 覆盖（或改板级 txt 后重编）。
3. 固件为 Broadcom 二进制，随包投放至 `/lib/firmware/brcm/`；授权与来源见上。真机加载
   情况以 `dmesg | grep -i brcmfmac` 为准（`using brcmfmac43430b0-sdio.bin for chip 43430/2`
   之类行即为命中）。
