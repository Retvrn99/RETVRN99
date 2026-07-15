// SPDX-License-Identifier: LGPL-3.0-only
// PIR table generation (for emulators)
// DO NOT ADD NEW FEATURES HERE.  (See paravirt.c / biostables.c instead.)
//
// Copyright (C) 2008  Kevin O'Connor <kevin@koconnor.net>
// Copyright (C) 2002  MandrakeSoft S.A.
//
// This file may be distributed under the terms of the GNU LGPLv3 license.

#include "config.h" // CONFIG_*
#include "fw/retvrn99-amd750.h" // RETVRN99_AMD750_PIRQ_*
#include "output.h" // dprintf
#include "std/pirtable.h" // struct pir_header
#include "string.h" // checksum
#include "util.h" // PirAddr

struct pir_table {
    struct pir_header pir;
    struct pir_slot slots[2];
} PACKED;

static struct pir_table PIR_TABLE = {
    .pir = {
        .version = 0x0100,
        .size = sizeof(struct pir_table),
        .router_devfunc = RETVRN99_AMD756_ISA_DEVFUNC,
        .exclusive_irqs = RETVRN99_AMD750_PIRQ_EXCLUSIVE_BITMAP,
        // PIRQ programming belongs to the omitted AMD-756 PM function.
        // Keep 00:07.0 as the topology anchor without claiming compatibility
        // with a programmable PCI interrupt router.
        .compatible_devid = 0,
    },
    .slots = {
        {
            // Embedded GSW VGA at 00:02.0.  The link rotation is shared with
            // the emulator: INTA maps to PIRQB and therefore IRQ11.
            .bus = 0,
            .dev = RETVRN99_GSW_VGA_DEVICE << 3,
            .links = {
                {
                    .link = RETVRN99_AMD750_PIRQ_LINK(
                        RETVRN99_GSW_VGA_DEVICE, 1),
                    .bitmap = RETVRN99_AMD750_PIRQ_BITMAP(
                        RETVRN99_GSW_VGA_DEVICE, 1),
                },
            },
            .slot_nr = 0, // embedded
        }, {
            // AMD-756 IDE at 00:07.1 uses INTA/PIRQC when native.
            .bus = 0,
            .dev = RETVRN99_AMD756_ISA_DEVICE << 3,
            .links = {
                {
                    .link = RETVRN99_AMD750_PIRQ_LINK(
                        RETVRN99_AMD756_ISA_DEVICE, 1),
                    .bitmap = RETVRN99_AMD750_PIRQ_BITMAP(
                        RETVRN99_AMD756_ISA_DEVICE, 1),
                },
            },
            .slot_nr = 0, // embedded
        },
    }
};

void
pirtable_setup(void)
{
    if (! CONFIG_PIRTABLE)
        return;

    dprintf(3, "init PIR table\n");

    PIR_TABLE.pir.signature = PIR_SIGNATURE;
    PIR_TABLE.pir.checksum -= checksum(&PIR_TABLE, sizeof(PIR_TABLE));
    copy_pir(&PIR_TABLE);
}
