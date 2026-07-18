# SPDX-License-Identifier: GPL-3.0-only

RETVRN99_GSW_RELEASE = 1
!include makefile
FLAGS += -DHWBLT

GSW_DRV_OBJS = &
  dibcall.obj dibthunk.obj dddrv_gsw.obj drvlib.obj enable.obj gsw_gdi.obj &
  init.obj control_gsw.obj pm16_calls_gsw.obj palette.obj sswhook.obj &
  modes.obj scrsw.obj

GSW_VXD_OBJS = &
  pci.obj gsw_transport.obj gsw3d_transport.obj gsw3d_ioctl.obj gsw_ddraw.obj vxd_fbhda.obj &
  vxd_fbhda_dd.obj vxd_lib.obj vxd_main_gsw.obj vxd_vbe_gsw.obj &
  vxd_vdd_gsw.obj vxd_mouse.obj vxd_wram.obj vxd_async.obj vxd_terror.obj

!ifdef DDK98_PATH
GSWMINI_DRV_RC = $(RC16) $(RC16_FLAGS) res\gswmini.rc $@
!else
GSWMINI_DRV_RC = wrc -q gswmini.res $@ && $(FIXLINK_EXE) -40 $@
!endif

gsw : gswmini.drv gswmini.vxd gswmini.inf .symbolic

gsw_transport.obj : gsw_transport.c gsw_transport.h .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) gsw_transport.c

gsw3d_transport.obj : gsw3d_transport.c gsw_transport.h gsw3d_abi.h .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) gsw3d_transport.c

gsw3d_ioctl.obj : gsw3d_ioctl.c gsw_transport.h gsw3d_abi.h .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) gsw3d_ioctl.c

gsw_ddraw.obj : gsw_ddraw.c gsw_transport.h .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) gsw_ddraw.c

gsw_gdi.obj : gsw_gdi.c gsw_gdi.h gsw_gdi_abi.h .autodepend
	$(CC) $(CFLAGS) -zW $(INCS) $(FLAGS) gsw_gdi.c

dddrv_gsw.obj : dddrv_gsw.c .autodepend
	$(CC) $(CFLAGS) -zW $(INCS) $(FLAGS) dddrv_gsw.c

control_gsw.obj : control_gsw.c .autodepend
	$(CC) $(CFLAGS) -zW $(INCS) $(FLAGS) control_gsw.c

pm16_calls_gsw.obj : pm16_calls_gsw.c .autodepend
	$(CC) $(CFLAGS) -zW $(INCS) $(FLAGS) $<

vxd_main_gsw.obj : vxd_main_gsw.c .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) $<

vxd_vbe_gsw.obj : vxd_vbe_gsw.c gsw_transport.h .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) vxd_vbe_gsw.c

vxd_vdd_gsw.obj : vxd_vdd_gsw.c .autodepend
	$(CC32) $(CFLAGS32) $(INCS) $(FLAGS) $<

gswmini.res : res/gswmini.rc res/colortab.bin res/config.bin res/fonts.bin res/fonts120.bin .autodepend
	wrc -q -r -ad -bt=windows -fo=$@ -Ires -I$(%WATCOM)/h/win $(FLAGS) res/gswmini.rc

gswmini.drv : $(GSW_DRV_OBJS) gswmini.res dibeng.lib $(FIXLINK_EXE)
	wlink op quiet, start=DriverInit_ disable 2055 $(DBGFILE) @<<gswmini.lnk
system windows dll initglobal
file dibcall.obj
file dibthunk.obj
file dddrv_gsw.obj
file drvlib.obj
file enable.obj
file gsw_gdi.obj
file init.obj
file control_gsw.obj
file pm16_calls_gsw.obj
file palette.obj
file sswhook.obj
file modes.obj
file scrsw.obj
name gswmini.drv
option map=gswmini.map
library dibeng.lib
library clibs.lib
option modname=DISPLAY
option description 'DISPLAY : 100, 96, 96 : DIB Engine based Mini display driver.'
option oneautodata
segment type data preload fixed
segment '_TEXT'  preload shared
segment '_INIT'  preload moveable
export BitBlt.1
export ColorInfo.2
export Control.3
export Disable.4
export Enable.5
export EnumDFonts.6
export EnumObj.7
export Output.8
export Pixel.9
export RealizeObject.10
export StrBlt.11
export ScanLR.12
export DeviceMode.13
export ExtTextOut.14
export GetCharWidth.15
export DeviceBitmap.16
export FastBorder.17
export SetAttribute.18
export DibBlt.19
export CreateDIBitmap.20
export DibToDevice.21
export SetPalette.22
export GetPalette.23
export SetPaletteTranslate.24
export GetPaletteTranslate.25
export UpdateColors.26
export StretchBlt.27
export StretchDIBits.28
export SelectBitmap.29
export BitmapBits.30
export ReEnable.31
export DDIGammaRamp.32
export Inquire.101
export SetCursor.102
export MoveCursor.103
export CheckCursor.104
export GetDriverResourceID.450
export UserRepaintDisable.500
export ValidateMode.700
import GlobalSmartPageLock  KERNEL.230
<<
	$(GSWMINI_DRV_RC)

gswmini.vxd : $(GSW_VXD_OBJS) $(FIXLINK_EXE)
	wlink op quiet $(DBGFILE32) @<<gswmini.lnk
system win_vxd dynamic
option map=gswmini-vxd.map
option nodefaultlibs
name gswmini.vxd
file vxd_main_gsw.obj
file pci.obj
file gsw_transport.obj
file gsw3d_transport.obj
file gsw3d_ioctl.obj
file gsw_ddraw.obj
file vxd_fbhda.obj
file vxd_fbhda_dd.obj
file vxd_lib.obj
file vxd_vbe_gsw.obj
file vxd_vdd_gsw.obj
file vxd_mouse.obj
file vxd_wram.obj
file vxd_async.obj
file vxd_terror.obj
segment '_TEXT'  PRELOAD NONDISCARDABLE IOPL
segment '_DATA'  PRELOAD NONDISCARDABLE IOPL
segment 'CONST'  PRELOAD NONDISCARDABLE IOPL
segment 'CONST2' PRELOAD NONDISCARDABLE IOPL
segment '_BSS'   PRELOAD NONDISCARDABLE IOPL
export VXD_DDB.1
<<
	$(FIXLINK_EXE) -vxd32 $@
