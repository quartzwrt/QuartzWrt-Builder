// SPDX-License-Identifier: GPL-2.0+
/*
 * FB driver for the GalaxyCore GC9307 LCD controller
 *
 * Used by the 1.47" IPS panel on the NLnet XiGuaPi V3 (NL68K):
 *   GoldenMorning T147BG-C08-06 / T147BG-H12-07
 *   172(H)RGB x 320(V), 4-line SPI (8-bit bus + D/C), 3 white LED backlight.
 *
 * The panel is mounted landscape: the DT sets rotate = <270>, so fbtft
 * exposes a 320x172 framebuffer; the calibrated MADCTL is MY|MX|MV|BGR
 * (0xE8) and the address window starts at source line 34 (172 of 240).
 *
 * Initialization sequence taken from the panel vendor's
 * "1.47寸IPS初始化GC9307+HSD" (register values only; driver written for
 * QuartzWrt).  Vendor DTS/firmware used an out-of-tree fbtft driver with
 * compatible "gc9307"; this driver is the in-tree equivalent.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <video/mipi_display.h>

#include "fbtft.h"

#define DRVNAME		"fb_gc9307"
#define WIDTH		172
#define HEIGHT		320
#define TXBUFLEN	(4 * PAGE_SIZE)

/*
 * 面板有效区是 172 行，而 GC9307 的 source 驱动有 240 行；这 172 行居中，
 * 上下各留 34 行。地址窗口必须从第 34 行开始，否则画面整体偏移 34 行，
 * 未覆盖的边缘会残留上一帧（厂商固件）的内容。
 */
#define ROW_OFFSET	34

static int init_display(struct fbtft_par *par)
{
	par->fbtftops.reset(par);

	/* Inter register enable */
	write_reg(par, 0xFE);
	write_reg(par, 0xEF);

	/*
	 * 0x36 (MADCTL) and 0x3A (pixel format) are written again by
	 * set_var()/fbtft core; keep the vendor values here for a
	 * self-contained power-on sequence.
	 */
	write_reg(par, MIPI_DCS_SET_ADDRESS_MODE, 0x48);
	write_reg(par, MIPI_DCS_SET_PIXEL_FORMAT, 0x05);	/* RGB565 */

	write_reg(par, 0x85, 0xC0);
	write_reg(par, 0x86, 0x98);
	write_reg(par, 0x87, 0x28);
	write_reg(par, 0x89, 0x33);
	write_reg(par, 0x8B, 0x84);
	write_reg(par, 0x8D, 0x3B);
	write_reg(par, 0x8E, 0x0F);
	write_reg(par, 0x8F, 0x70);

	write_reg(par, 0xE8, 0x13, 0x17);
	write_reg(par, 0xEC, 0x57, 0x07, 0xFF);
	write_reg(par, 0xED, 0x18, 0x09);

	write_reg(par, 0xC9, 0x10);

	write_reg(par, 0xFF, 0x61);
	write_reg(par, 0x99, 0x3A);
	write_reg(par, 0x9D, 0x43);
	write_reg(par, 0x98, 0x3E);
	write_reg(par, 0x9C, 0x4B);

	/* Gamma */
	write_reg(par, 0xF0, 0x06, 0x08, 0x08, 0x06, 0x05, 0x1D);
	write_reg(par, 0xF2, 0x00, 0x01, 0x09, 0x07, 0x04, 0x23);
	write_reg(par, 0xF1, 0x3B, 0x68, 0x66, 0x36, 0x35, 0x2F);
	write_reg(par, 0xF3, 0x37, 0x6A, 0x66, 0x37, 0x35, 0x35);

	write_reg(par, 0xFA, 0x80, 0x0F);
	write_reg(par, 0xBE, 0x11);	/* source bias */
	write_reg(par, 0xCB, 0x02);
	write_reg(par, 0xCD, 0x22);
	write_reg(par, 0x9B, 0xFF);

	write_reg(par, 0x35, 0x00);	/* tearing effect line on */
	write_reg(par, 0x44, 0x00, 0x0A);	/* tear scanline */

	write_reg(par, MIPI_DCS_EXIT_SLEEP_MODE);
	mdelay(200);
	write_reg(par, MIPI_DCS_SET_DISPLAY_ON);
	mdelay(20);

	return 0;
}

static void set_addr_win(struct fbtft_par *par, int xs, int ys, int xe, int ye)
{
	ys += ROW_OFFSET;
	ye += ROW_OFFSET;

	write_reg(par, MIPI_DCS_SET_COLUMN_ADDRESS,
		  (xs >> 8) & 0xFF, xs & 0xFF, (xe >> 8) & 0xFF, xe & 0xFF);
	write_reg(par, MIPI_DCS_SET_PAGE_ADDRESS,
		  (ys >> 8) & 0xFF, ys & 0xFF, (ye >> 8) & 0xFF, ye & 0xFF);
	write_reg(par, MIPI_DCS_WRITE_MEMORY_START);
}

#define MEM_MY	BIT(7)	/* row address order */
#define MEM_MX	BIT(6)	/* column address order */
#define MEM_MV	BIT(5)	/* row / column exchange */
#define MEM_BGR	BIT(3)	/* RGB-BGR order */

static int set_var(struct fbtft_par *par)
{
	/*
	 * 这块 T147BG 面板的物理滤色片是 BGR 顺序（厂商初始化 0x36=0x48
	 * 也带 BGR 位），因此这里固定 BGR；否则红/蓝互换。
	 * rotate=270 时面板需要 MV|MY|MX（0xE8；真机校准：上下/左右均
	 * 翻转后才与外壳方向一致），不是 ST7789 常见的 MV|MX。
	 */
	u8 madctl = MEM_BGR;

	switch (par->info->var.rotate) {
	case 0:
		break;
	case 90:
		madctl |= MEM_MV | MEM_MX;
		break;
	case 180:
		madctl |= MEM_MX | MEM_MY;
		break;
	case 270:
		madctl |= MEM_MV | MEM_MY | MEM_MX;
		break;
	default:
		return -EINVAL;
	}

	write_reg(par, MIPI_DCS_SET_ADDRESS_MODE, madctl);

	return 0;
}

static struct fbtft_display display = {
	.regwidth = 8,
	.buswidth = 8,
	.width = WIDTH,
	.height = HEIGHT,
	.bpp = 16,
	.fps = 10,
	.txbuflen = TXBUFLEN,
	.fbtftops = {
		.init_display = init_display,
		.set_addr_win = set_addr_win,
		.set_var = set_var,
	},
};

FBTFT_REGISTER_SPI_DRIVER(DRVNAME, "galaxycore", "gc9307", &display);

MODULE_ALIAS("spi:" DRVNAME);
MODULE_ALIAS("spi:gc9307");

MODULE_DESCRIPTION("FB driver for the GalaxyCore GC9307 LCD controller");
MODULE_LICENSE("GPL");
