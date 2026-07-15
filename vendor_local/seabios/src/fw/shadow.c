// SPDX-License-Identifier: LGPL-3.0-only
// Support for enabling/disabling BIOS ram shadowing.
//
// Copyright (C) 2008-2010  Kevin O'Connor <kevin@koconnor.net>
// Copyright (C) 2006 Fabrice Bellard
//
// This file may be distributed under the terms of the GNU LGPLv3 license.

#include "config.h" // CONFIG_*
#include "dev-q35.h" // PCI_VENDOR_ID_INTEL
#include "dev-piix.h" // I440FX_PAM0
#include "hw/pci.h" // pci_config_writeb
#include "hw/pci_ids.h" // PCI_VENDOR_ID_INTEL
#include "hw/pci_regs.h" // PCI_VENDOR_ID
#include "malloc.h" // rom_get_last
#include "output.h" // dprintf
#include "paravirt.h" // runningOnXen
#include "fw/retvrn99-amd750.h" // RETVRN99_AMD756_*
#include "string.h" // memset
#include "util.h" // make_bios_writable
#include "x86.h" // wbinvd

// On the emulators, the bios at 0xf0000 is also at 0xffff0000
#define BIOS_SRC_OFFSET 0xfff00000

union pamdata_u {
    u8 data8[8];
    u32 data32[2];
};

// Enable shadowing and copy bios.
static void
__make_bios_writable_intel(u16 bdf, u32 pam0)
{
    // Read in current PAM settings from pci config space
    union pamdata_u pamdata;
    pamdata.data32[0] = pci_ioconfig_readl(bdf, ALIGN_DOWN(pam0, 4));
    pamdata.data32[1] = pci_ioconfig_readl(bdf, ALIGN_DOWN(pam0, 4) + 4);
    u8 *pam = &pamdata.data8[pam0 & 0x03];

    // Make ram from 0xc0000-0xf0000 writable
    int i;
    for (i=0; i<6; i++)
        pam[i + 1] = 0x33;

    // Make ram from 0xf0000-0x100000 writable
    int ram_present = pam[0] & 0x10;
    pam[0] = 0x30;

    // Write PAM settings back to pci config space
    pci_ioconfig_writel(bdf, ALIGN_DOWN(pam0, 4), pamdata.data32[0]);
    pci_ioconfig_writel(bdf, ALIGN_DOWN(pam0, 4) + 4, pamdata.data32[1]);

    if (!ram_present)
        // Copy bios.
        memcpy(VSYMBOL(code32flat_start)
               , VSYMBOL(code32flat_start) + BIOS_SRC_OFFSET
               , SYMBOL(code32flat_end) - SYMBOL(code32flat_start));
}

static void
make_bios_writable_intel(u16 bdf, u32 pam0)
{
    int reg = pci_ioconfig_readb(bdf, pam0);
    if (!(reg & 0x10)) {
        // QEMU doesn't fully implement the piix shadow capabilities -
        // if ram isn't backing the bios segment when shadowing is
        // disabled, the code itself won't be in memory.  So, run the
        // code from the high-memory flash location.
        u32 pos = (u32)__make_bios_writable_intel + BIOS_SRC_OFFSET;
        void (*func)(u16 bdf, u32 pam0) = (void*)pos;
        func(bdf, pam0);
        return;
    }
    // Ram already present - just enable writes
    __make_bios_writable_intel(bdf, pam0);
}

static void
make_bios_readonly_intel(u16 bdf, u32 pam0)
{
    // Flush any pending writes before locking memory.
    wbinvd();

    // Read in current PAM settings from pci config space
    union pamdata_u pamdata;
    pamdata.data32[0] = pci_config_readl(bdf, ALIGN_DOWN(pam0, 4));
    pamdata.data32[1] = pci_config_readl(bdf, ALIGN_DOWN(pam0, 4) + 4);
    u8 *pam = &pamdata.data8[pam0 & 0x03];

    // Write protect roms from 0xc0000-0xf0000
    u32 romlast = BUILD_BIOS_ADDR, rommax = BUILD_BIOS_ADDR;
    if (CONFIG_WRITABLE_UPPERMEMORY)
        romlast = rom_get_last();
    if (CONFIG_MALLOC_UPPERMEMORY)
        rommax = rom_get_max();
    int i;
    for (i=0; i<6; i++) {
        u32 mem = BUILD_ROM_START + i * 32*1024;
        if (romlast < mem + 16*1024 || rommax < mem + 32*1024) {
            if (romlast >= mem && rommax >= mem + 16*1024)
                pam[i + 1] = 0x31;
            break;
        }
        pam[i + 1] = 0x11;
    }

    // Write protect 0xf0000-0x100000
    pam[0] = 0x10;

    // Write PAM settings back to pci config space
    pci_config_writel(bdf, ALIGN_DOWN(pam0, 4), pamdata.data32[0]);
    pci_config_writel(bdf, ALIGN_DOWN(pam0, 4) + 4, pamdata.data32[1]);
}

static int ShadowBDF = -1;

static void
make_bios_writable_amd750(void)
{
    int bdf = RETVRN99_AMD756_ISA_BDF;
    u32 vendev = pci_ioconfig_readl(bdf, PCI_VENDOR_ID);
    if (vendev != ((u32)PCI_DEVICE_ID_AMD_VIPER_7408 << 16
                   | PCI_VENDOR_ID_AMD)) {
        dprintf(1, "Unable to prepare AMD-750 BIOS shadow - ISA bridge not found\n");
        return;
    }
    // AMD-751 has no PAM.  The low image is RAM; RD7 exposes the
    // second 64K of the pristine high-ROM source used for the copy.
    u8 decode = pci_ioconfig_readb(
        bdf, RETVRN99_AMD756_ROM_DECODE_CONTROL);
    pci_ioconfig_writeb(bdf, RETVRN99_AMD756_ROM_DECODE_CONTROL,
                        decode | RETVRN99_AMD756_HIGH_BIOS_128K_DECODE);
    memcpy(VSYMBOL(code32flat_start)
           , VSYMBOL(code32flat_start) + BIOS_SRC_OFFSET
           , SYMBOL(code32flat_end) - SYMBOL(code32flat_start));
}

static void
make_bios_readonly_amd750(void)
{
    // GSW-886 does not expose MTRRs, so no low-shadow lock is available.
    wbinvd();
}

// Make the 0xc0000-0x100000 area read/writable.
void
make_bios_writable(void)
{
    if (!CONFIG_QEMU || runningOnXen())
        return;

    dprintf(3, "enabling shadow ram\n");

    // At this point, statically allocated variables can't be written,
    // so do this search manually.
    int bdf;
    pci_ioconfig_foreachbdf(bdf, 0) {
        u32 vendev = pci_ioconfig_readl(bdf, PCI_VENDOR_ID);
        u16 vendor = vendev & 0xffff, device = vendev >> 16;
        if (vendor == PCI_VENDOR_ID_AMD
            && device == PCI_DEVICE_ID_AMD_FE_GATE_7006) {
            make_bios_writable_amd750();
            code_mutable_preinit();
            ShadowBDF = bdf;
            return;
        }
        if (vendor == PCI_VENDOR_ID_INTEL
            && device == PCI_DEVICE_ID_INTEL_82441) {
            make_bios_writable_intel(bdf, I440FX_PAM0);
            code_mutable_preinit();
            ShadowBDF = bdf;
            return;
        }
        if (vendor == PCI_VENDOR_ID_INTEL
            && device == PCI_DEVICE_ID_INTEL_Q35_MCH) {
            make_bios_writable_intel(bdf, Q35_HOST_BRIDGE_PAM0);
            code_mutable_preinit();
            ShadowBDF = bdf;
            return;
        }
    }
    dprintf(1, "Unable to unlock ram - bridge not found\n");
}

// Make the BIOS code segment area (0xf0000) read-only.
void
make_bios_readonly(void)
{
    if (!CONFIG_QEMU || runningOnXen())
        return;
    dprintf(3, "locking shadow ram\n");

    if (ShadowBDF < 0) {
        dprintf(1, "Unable to lock ram - bridge not found\n");
        return;
    }

    u32 vendev = pci_config_readl(ShadowBDF, PCI_VENDOR_ID);
    u16 vendor = vendev & 0xffff, device = vendev >> 16;
    if (vendor == PCI_VENDOR_ID_AMD
        && device == PCI_DEVICE_ID_AMD_FE_GATE_7006) {
        make_bios_readonly_amd750();
        return;
    }
    if (vendor == PCI_VENDOR_ID_INTEL
        && device == PCI_DEVICE_ID_INTEL_82441)
        make_bios_readonly_intel(ShadowBDF, I440FX_PAM0);
    else if (vendor == PCI_VENDOR_ID_INTEL
             && device == PCI_DEVICE_ID_INTEL_Q35_MCH)
        make_bios_readonly_intel(ShadowBDF, Q35_HOST_BRIDGE_PAM0);
    else
        dprintf(1, "Unable to lock ram - unsupported bridge\n");
}

void
qemu_reboot(void)
{
    if (!CONFIG_QEMU || runningOnXen())
        return;
    // QEMU doesn't map 0xc0000-0xfffff back to the original rom on a
    // reset, so do that manually before invoking a hard reset.
    void *flash = (void*)BIOS_SRC_OFFSET;
    u32 hrp = (u32)&HaveRunPost;
    if (readl(flash + hrp)) {
        // There isn't a pristine copy of the BIOS at 0xffff0000 to copy
        if (HaveRunPost == 3) {
            // In a reboot loop.  Try to shutdown the machine instead.
            dprintf(1, "Unable to hard-reboot machine - attempting shutdown.\n");
            apm_shutdown();
        }
        make_bios_writable();
        HaveRunPost = 3;
    } else {
        // Copy the BIOS making sure to only reset HaveRunPost at end
        make_bios_writable();
        u32 cstart = SYMBOL(code32flat_start), cend = SYMBOL(code32flat_end);
        memcpy((void*)cstart, flash + cstart, hrp - cstart);
        memcpy((void*)hrp + 4, flash + hrp + 4, cend - (hrp + 4));
        barrier();
        HaveRunPost = 0;
        barrier();
    }

    // Request a QEMU system reset.  Do the reset in this function as
    // the BIOS code was overwritten above and not all BIOS
    // functionality may be available.

    // Attempt PCI style reset
    outb(0x02, PORT_PCI_REBOOT);
    outb(0x06, PORT_PCI_REBOOT);

    // Next try triple faulting the CPU to force a reset
    asm volatile("int3");
}
