/* SPDX-License-Identifier: GPL-3.0-only */
#include "git_sha1.h"
#include "nine_memory_helper.h"

#if !defined(__i386__) || defined(__x86_64__)
#error The GSW guest compile profile must target i686.
#endif
#if !defined(__MMX__) || !defined(__SSE__) || !defined(__SSE2__) || \
    !defined(__SSE3__)
#error The GSW guest compile profile requires MMX through SSE3.
#endif
#if defined(__SSE4A__) || defined(__SSE4_1__) || defined(__SSE4_2__) || \
    defined(__AVX__) || defined(__AVX2__) || \
    defined(__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16)
#error The GSW guest compile profile exceeds SSE3 or enables CX16.
#endif

typedef char gsw_package_version_is_present[
    sizeof(PACKAGE_VERSION) > 1 ? 1 : -1
];
typedef char gsw_source_identity_is_present[
    sizeof(MESA_GIT_SHA1) > 1 ? 1 : -1
];

static struct nine_allocator *gsw_probe_allocator;
static struct nine_allocation *gsw_probe_allocation;

void gsw_mesa_original_interface_compile_probe(void)
{
    void *pointer = nine_get_pointer(gsw_probe_allocator, gsw_probe_allocation);
    (void)pointer;
}
