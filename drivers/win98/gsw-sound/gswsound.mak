# SPDX-License-Identifier: GPL-3.0-only
# One clean GSW-Sound build. scripts/build-win98-gsw-sound.ps1 verifies the
# pinned inputs and invokes this makefile twice into distinct absent roots.

!ifndef WATCOM
!error WATCOM must name the verified Open Watcom 1.9 extraction
!endif
!ifndef GSW_SOUND_OUT
!error GSW_SOUND_OUT must name an external output root
!endif

WATCOM_BIN = $(WATCOM)\binnt
CC16 = $(WATCOM_BIN)\wcc.exe
CC32 = $(WATCOM_BIN)\wcc386.exe
WCL16 = $(WATCOM_BIN)\wcl.exe
WCL32 = $(WATCOM_BIN)\wcl386.exe
WLIB = $(WATCOM_BIN)\wlib.exe
LINK = $(WATCOM_BIN)\wlink.exe
RC = $(WATCOM_BIN)\wrc.exe

OBJDIR = $(GSW_SOUND_OUT)\obj
SUPPORT = build-support
INC16 = -i="$(WATCOM)\h\win" -i="$(WATCOM)\h" -i=include -i=drv
INC32 = -i="$(WATCOM)\h\nt" -i="$(WATCOM)\h\win" -i="$(WATCOM)\h" &
        -i=$(SUPPORT) -i=include -i=vxd
C16 = -q -bt=windows -ml -3 -os -s -zq -zc $(INC16)
C32 = -q -wx -s -zls -mf -dVXD32 -dWIN40_OR_LATER -fpi87 -ei -oeatxhn -6s -fp6 $(INC32)

DRV_OBJS = $(OBJDIR)\gswsound_drv.obj $(OBJDIR)\gswsound_mixer.obj &
           $(OBJDIR)\gswsound_pm16.obj
VXD_OBJS = $(OBJDIR)\gswsound_vxd.obj $(OBJDIR)\gswsound_transport.obj &
           $(OBJDIR)\vxdwraps.obj

all: dirs $(GSW_SOUND_OUT)\GSWSOUND.INF $(GSW_SOUND_OUT)\GSWSOUND.DRV &
     $(GSW_SOUND_OUT)\GSWSOUND.VXD .symbolic

dirs: .symbolic
	@if not exist "$(GSW_SOUND_OUT)" mkdir "$(GSW_SOUND_OUT)"
	@if not exist "$(OBJDIR)" mkdir "$(OBJDIR)"

$(OBJDIR)\gswsound_drv.obj: drv\gswsound_drv.c .autodepend
	$(CC16) $(C16) -fo=$@ $<

$(OBJDIR)\gswsound_mixer.obj: drv\gswsound_mixer.c .autodepend
	$(CC16) $(C16) -fo=$@ $<

$(OBJDIR)\gswsound_pm16.obj: drv\gswsound_pm16.c .autodepend
	$(CC16) $(C16) -fo=$@ $<

$(OBJDIR)\gswsound.res: drv\gswsound.rc .autodepend
	$(RC) -q -r -bt=windows -fo=$@ $(INC16) $<

$(OBJDIR)\mmsystem.lib: $(SUPPORT)\mmsystem.lbc
	$(WLIB) -b -q -n -fo -ii @$< $@

$(OBJDIR)\fixlink.exe: $(SUPPORT)\fixlink.c
	$(WCL32) -q -os -s -zq -i="$(WATCOM)\h" -fe=$@ $<

$(OBJDIR)\gswsound_vxd.obj: vxd\gswsound_vxd.c .autodepend
	$(CC32) $(C32) -fo=$@ $<

$(OBJDIR)\gswsound_transport.obj: vxd\gswsound_transport.c .autodepend
	$(CC32) $(C32) -fo=$@ $<

$(OBJDIR)\vxdwraps.obj: $(SUPPORT)\vxdwraps.c .autodepend
	$(CC32) $(C32) -fo=$@ $<

$(GSW_SOUND_OUT)\GSWSOUND.INF: GSWSOUND.INF
	@copy /B /Y $< $@ >NUL

$(GSW_SOUND_OUT)\GSWSOUND.DRV: $(DRV_OBJS) $(OBJDIR)\gswsound.res &
        $(OBJDIR)\mmsystem.lib $(OBJDIR)\fixlink.exe drv\gswsound.def
	$(LINK) @<<
system windows dll initglobal memory
option quiet
option nodefaultlibs
option map=$(OBJDIR)\gswsound-drv.map
option oneautodata
option heapsize=1024
option modname=GSWSOUND
option description 'RETVRN99 GSW-Sound Windows 98 waveOut driver'
name $@
libfile $(WATCOM)\lib286\win\libentry.obj
file $(OBJDIR)\gswsound_drv.obj
file $(OBJDIR)\gswsound_mixer.obj
file $(OBJDIR)\gswsound_pm16.obj
library $(OBJDIR)\mmsystem.lib
library $(WATCOM)\lib286\win\windows.lib
library $(WATCOM)\lib286\win\clibl.lib
segment '_TEXT' PRELOAD FIXED
segment '_DATA' PRELOAD FIXED
segment 'CONST' PRELOAD FIXED
segment '_BSS' PRELOAD FIXED
export WEP.1 resident
export DriverProc.2
export wodMessage.3
export mxdMessage.4
<<
	$(RC) -q $(OBJDIR)\gswsound.res $@
	$(OBJDIR)\fixlink.exe -40 $@

$(GSW_SOUND_OUT)\GSWSOUND.VXD: $(VXD_OBJS) $(OBJDIR)\fixlink.exe vxd\gswsound.def
	$(LINK) @<<
system win_vxd dynamic
option quiet
option nodefaultlibs
option map=$(OBJDIR)\gswsound-vxd.map
name $@
file $(OBJDIR)\gswsound_vxd.obj
file $(OBJDIR)\gswsound_transport.obj
file $(OBJDIR)\vxdwraps.obj
segment '_TEXT' PRELOAD NONDISCARDABLE IOPL
segment '_DATA' PRELOAD NONDISCARDABLE IOPL
segment 'CONST' PRELOAD NONDISCARDABLE IOPL
segment '_BSS' PRELOAD NONDISCARDABLE IOPL
export GSWSOUND_DDB.1
<<
	$(OBJDIR)\fixlink.exe -vxd32 $@
