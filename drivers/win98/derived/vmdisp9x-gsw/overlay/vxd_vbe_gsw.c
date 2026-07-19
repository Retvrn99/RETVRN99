/* SPDX-License-Identifier: GPL-3.0-only */

#define QEMU
#define GSW

#define VBE_init_hw GSW_base_VBE_init_hw
#define VBE_valid GSW_base_VBE_valid
#define VBE_validmode GSW_base_VBE_validmode
#define VBE_setmode GSW_base_VBE_setmode
#define FBHDA_swap GSW_base_FBHDA_swap

#include "vxd_vbe.c"

#undef FBHDA_swap
#undef VBE_setmode
#undef VBE_validmode
#undef VBE_valid
#undef VBE_init_hw

#include "gsw_transport.h"
#include "wram.h"

extern DWORD ThisVM;
BOOL update_pm16(DWORD vm, DWORD oldmap, DWORD linear, DWORD size);

static char gsw_vxd_name[] = "gswmini.vxd";

static BOOL GSW_init_failure(void)
{
	vbe_is_valid = FALSE;
	GSW_transport_shutdown();
	FBHDA_release_hw();
	wram_release();
	return FALSE;
}

static BOOL GSW_bind_framebuffer(void)
{
	DWORD framebuffer_bytes;
	DWORD old_framebuffer_bytes;
	void *framebuffer;
	void *old_framebuffer;

	framebuffer = GSW_transport_framebuffer();
	framebuffer_bytes = GSW_transport_framebuffer_bytes();
	if(hda == NULL || framebuffer == NULL || framebuffer_bytes == 0)
		return FALSE;

	old_framebuffer = hda->vram_pm32;
	old_framebuffer_bytes = hda->vram_size_virt;
	if((old_framebuffer != framebuffer || old_framebuffer_bytes != framebuffer_bytes) &&
	   hda->vram_pm16 != 0 &&
	   !update_pm16(ThisVM, hda->vram_pm16, (DWORD)framebuffer, framebuffer_bytes))
		return FALSE;
	hda->vram_pm32 = framebuffer;
	hda->vram_phylin = framebuffer;
	hda->vram_size = framebuffer_bytes;
	hda->vram_size_bar = framebuffer_bytes;
	hda->vram_size_virt = framebuffer_bytes;
	return TRUE;
}

BOOL VBE_init_hw(void)
{
	if(wram == NULL && !wram_init(64UL * 1024UL))
		return FALSE;
	if(!GSW_transport_init())
		return GSW_init_failure();
	if(!GSW_base_VBE_init_hw())
		return GSW_init_failure();
	if(!GSW_bind_framebuffer())
		return GSW_init_failure();
	memset(hda->vxdname, 0, sizeof(hda->vxdname));
	memcpy(hda->vxdname, gsw_vxd_name, sizeof(gsw_vxd_name));
	vbe_chip_id = GSW_PCI_DEVICE_ID;

	return TRUE;
}

BOOL VBE_valid(void)
{
	return GSW_transport_ready() && GSW_base_VBE_valid();
}

BOOL VBE_validmode(DWORD width, DWORD height, DWORD bpp)
{
	DWORD pitch;

	if(!GSW_transport_ready() || hda == NULL)
		return FALSE;
	if(!GSW_base_VBE_validmode(width, height, bpp))
		return FALSE;
	pitch = VBE_pitch(width, bpp);
	return GSW_transport_mode_valid(width, height, pitch, bpp);
}

BOOL VBE_setmode(DWORD width, DWORD height, DWORD bpp)
{
	/* OP_VBE_SETMODE is serialized by vxd_main.c's critical section. */
	if(!GSW_transport_rebind() || !GSW_bind_framebuffer())
		return FALSE;
	if(!VBE_validmode(width, height, bpp))
		return FALSE;
	if(!GSW_base_VBE_setmode(width, height, bpp))
		return FALSE;
	if(!GSW_transport_set_mode(hda->width, hda->height, hda->pitch, hda->bpp))
		return FALSE;
	return GSW_transport_present(0, hda->width, hda->height, hda->pitch, hda->bpp);
}

BOOL FBHDA_swap(DWORD offset, DWORD flags)
{
	if((flags & FBHDA_SWAP_QUERY) != 0)
		return GSW_transport_ready() &&
		       (GSW_transport_capabilities() & GSW_VGA_CAP_SURFACE_OFFSET) != 0;
	if(!GSW_transport_ready() || hda == NULL ||
	   offset > hda->vram_size || hda->stride > hda->vram_size - offset)
		return FALSE;
	if(!GSW_transport_present(
		offset,
		hda->width,
		hda->height,
		hda->pitch,
		hda->bpp
	))
		return FALSE;
	hda->surface = offset;
	return TRUE;
}
