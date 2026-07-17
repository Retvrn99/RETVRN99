# SPDX-License-Identifier: GPL-3.0-only

CC=gcc
WINDRES=windres
HOST_CC=gcc
CSTD=gnu99
OBJ=.o
VERSION_BUILD=0
DEFS=-DGSW_DDHAL
TUNE=-march=pentium2 -mtune=core2 -pipe
TUNE_LD=,--strip-all
LIBS=-luser32 -lkernel32 -lgcc -lgdi32 -ladvapi32
CFLAGS=-std=$(CSTD) -Wall -ffreestanding -fno-exceptions -ffast-math -nostdlib $(DEFS) -DNOCRT -DNOCRT_FILE -DNOCRT_FLOAT -DNOCRT_MEM -DNOCRT_CALC -Inocrt -Iregex -O3 -fomit-frame-pointer -DNDEBUG $(TUNE) -DVMHAL9X_BUILD=$(VERSION_BUILD)
LDFLAGS=-static -nostdlib -nodefaultlibs -L.
DLLFLAGS=-o $@ -shared -Wl,--dll,--no-insert-timestamp,--out-implib,lib$(@:dll=a),--exclude-all-symbols,--exclude-libs=pthread,--disable-dynamicbase,--disable-nxcompat,--subsystem,windows,--image-base,$(BASE_$@)$(TUNE_LD)

BASE_gswhal9x.dll=0xB00B0000
BASE_gswdd32.dll=0x32500000

NOCRT_OBJS=nocrt/nocrt.c.o nocrt/nocrt_math.c.o nocrt/nocrt_math_calc.c.o \
	nocrt/nocrt_file_win.c.o nocrt/nocrt_mem_win.c.o
HAL_OBJS=$(NOCRT_OBJS) nocrt/nocrt_dll.c.o vmhal9x.c.o 3d_accel.c.o \
	gsw_ddraw.c.o gsw_backend.c.o debug.c.o dump.c.o memory.c.o gswhal9x.res
BRIDGE_OBJS=$(NOCRT_OBJS) nocrt/nocrt_dll.c.o gsw_bridge_main.c.o fbhda_gsw.c.o \
	debug.c.o dump.c.o gswdd32.res

.PHONY: gsw clean
gsw: gswhal9x.dll gswdd32.dll

%.c.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.res: %.rc
	$(WINDRES) -DWINDRES -DVMHAL9X_BUILD=$(VERSION_BUILD) --input $< --output $@ --output-format=coff

fixlink.exe:
	$(HOST_CC) -std=$(CSTD) fixlink/fixlink.c -o fixlink.exe

gswdd32.dll: $(BRIDGE_OBJS)
	$(CC) $(LDFLAGS) $(BRIDGE_OBJS) gswdd32.def $(LIBS) $(DLLFLAGS)

gswhal9x.dll: $(HAL_OBJS) fixlink.exe gswdd32.dll
	$(CC) $(LDFLAGS) $(HAL_OBJS) gswhal9x.def $(LIBS) $(DLLFLAGS)
	.\fixlink.exe -shared $@

clean:
	-$(RM) $(HAL_OBJS) $(BRIDGE_OBJS) fixlink.exe gswhal9x.dll gswdd32.dll libgswhal9x.a libgswdd32.a
