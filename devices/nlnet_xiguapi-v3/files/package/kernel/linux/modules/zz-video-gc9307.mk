#
# fb-tft-gc9307 — fbtft driver for the GalaxyCore GC9307 SPI LCD controller
#
# Panel: GoldenMorning T147BG-C08-06 / T147BG-H12-07 (1.47", 172x320,
# 4-line SPI), mounted landscape (320x172) on the NLnet XiGuaPi V3.
#
# The driver source and Kconfig/Makefile hunks are delivered by the
# NL68K device layer:
#   files/target/linux/rockchip/files/drivers/staging/fbtft/fb_gc9307.c
#   files/target/linux/rockchip/patches-6.12/999-fbtft-gc9307.patch
#
# File name prefixes "zz-" so this module list is parsed after video.mk,
# which defines $(VIDEO_MENU).
#
define KernelPackage/fb-tft-gc9307
  SUBMENU:=$(VIDEO_MENU)
  TITLE:=FB driver for the GC9307 LCD Controller
  DEPENDS:=+kmod-fb-tft
  KCONFIG:=CONFIG_FB_TFT_GC9307
  FILES:=$(LINUX_DIR)/drivers/staging/fbtft/fb_gc9307.ko
  AUTOLOAD:=$(call AutoLoad,09,fb_gc9307)
endef

define KernelPackage/fb-tft-gc9307/description
 Framebuffer driver for the GalaxyCore GC9307 SPI LCD controller used by
 the 1.47" 172x320 panel on the NLnet XiGuaPi V3.
endef

$(eval $(call KernelPackage,fb-tft-gc9307))
