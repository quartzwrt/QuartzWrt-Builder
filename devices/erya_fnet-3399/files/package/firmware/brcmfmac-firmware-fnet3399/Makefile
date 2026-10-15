#
# FNet3399（SW799 核心板板载 Ampak AP6236 / BCM43430B0）WiFi + 蓝牙固件
#
# 设备适配层包：由 devices/erya_fnet-3399/files/package/firmware/ 原样投放进基座树，
# 仅 FNet3399 构建可见。文件集与 Lemon1151/iStoreOS-RK3399 的
# fnet3399/packages/brcmfmac-firmware-fnet3399 逐字节一致（md5 与来源见同目录 NOTICE）。
#
# 授权：Broadcom 二进制固件许可（linux-firmware 同款 LICENCE.broadcom_bcm43xx，
# 允许原样再分发）——见同目录 LICENSE，随包投放至 /lib/firmware/brcm/。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=brcmfmac-firmware-fnet3399
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/brcmfmac-firmware-fnet3399
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Broadcom AP6236 (BCM43430B0) WiFi/BT firmware for Erya FNet3399
  URL:=https://github.com/yizhanghong/rk3399-firmware
endef

define Package/brcmfmac-firmware-fnet3399/description
  AP6236 (BCM43430B0) firmware for the SW799 core board carried by Erya FNet3399:
  brcmfmac SDIO WiFi image + NVRAM (generic and board-specific) and the btbcm
  Bluetooth patchram (HCD).
endef

define Build/Compile
	true
endef

define Package/brcmfmac-firmware-fnet3399/install
	$(INSTALL_DIR) $(1)/lib/firmware/brcm
	$(INSTALL_DATA) ./files/lib/firmware/brcm/brcmfmac43430b0-sdio.bin \
		$(1)/lib/firmware/brcm/brcmfmac43430b0-sdio.bin
	$(INSTALL_DATA) ./files/lib/firmware/brcm/brcmfmac43430b0-sdio.txt \
		$(1)/lib/firmware/brcm/brcmfmac43430b0-sdio.txt
	$(INSTALL_DATA) "./files/lib/firmware/brcm/brcmfmac43430b0-sdio.erya,fnet-3399.txt" \
		"$(1)/lib/firmware/brcm/brcmfmac43430b0-sdio.erya,fnet-3399.txt"
	$(INSTALL_DATA) ./files/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob \
		$(1)/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob
	$(INSTALL_DATA) ./files/lib/firmware/brcm/BCM43430B0.hcd \
		$(1)/lib/firmware/brcm/BCM43430B0.hcd
	$(INSTALL_DATA) ./LICENSE \
		$(1)/lib/firmware/brcm/LICENCE.broadcom_bcm43xx
endef

$(eval $(call BuildPackage,brcmfmac-firmware-fnet3399))
