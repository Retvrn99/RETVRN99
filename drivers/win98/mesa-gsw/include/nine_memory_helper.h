/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_MESA_GSW_NINE_MEMORY_HELPER_H
#define RETVRN99_MESA_GSW_NINE_MEMORY_HELPER_H

#ifdef __cplusplus
extern "C" {
#endif

struct NineDevice9;
struct nine_allocator;
struct nine_allocation;

struct nine_allocation *nine_allocate(
    struct nine_allocator *allocator,
    unsigned size
);
void nine_free(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
);
void nine_free_worker(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
);
void *nine_get_pointer(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
);
void nine_pointer_weakrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
);
void nine_pointer_strongrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
);
void nine_pointer_delayedstrongrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation,
    unsigned *counter
);
struct nine_allocation *nine_suballocate(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation,
    int offset
);
struct nine_allocation *nine_wrap_external_pointer(
    struct nine_allocator *allocator,
    void *data
);
struct nine_allocator *nine_allocator_create(
    struct NineDevice9 *device,
    int memfd_virtualsizelimit
);
void nine_allocator_destroy(struct nine_allocator *allocator);

#ifdef __cplusplus
}
#endif

#endif
