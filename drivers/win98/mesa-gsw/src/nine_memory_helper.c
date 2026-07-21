/* SPDX-License-Identifier: GPL-3.0-only */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <limits.h>
#include <stdint.h>

#include "nine_memory_helper.h"

#define GSW_NINE_OWNS_MEMORY 0x01U
#define GSW_NINE_EXTERNAL_ROOT 0x02U
#define GSW_NINE_OWNER_RELEASED 0x04U
#define GSW_NINE_ALIGNMENT 64U

struct nine_allocation {
    struct nine_allocation *next;
    struct nine_allocation *previous;
    struct nine_allocation *parent;
    void *pointer;
    void *heap_pointer;
    unsigned size;
    unsigned child_count;
    unsigned flags;
};

struct nine_allocator {
    HANDLE heap;
    CRITICAL_SECTION lock;
    struct nine_allocation *head;
    int destroying;
};

static struct nine_allocation *gsw_nine_find_locked(
    struct nine_allocator *allocator,
    const struct nine_allocation *allocation
)
{
    struct nine_allocation *current = allocator->head;
    while (current != NULL) {
        if (current == allocation) return current;
        current = current->next;
    }
    return NULL;
}

static void gsw_nine_link_locked(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    allocation->previous = NULL;
    allocation->next = allocator->head;
    if (allocator->head != NULL) allocator->head->previous = allocation;
    allocator->head = allocation;
}

static void gsw_nine_unlink_locked(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    if (allocation->previous != NULL)
        allocation->previous->next = allocation->next;
    else
        allocator->head = allocation->next;
    if (allocation->next != NULL)
        allocation->next->previous = allocation->previous;
}

static void gsw_nine_dispose_locked(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    gsw_nine_unlink_locked(allocator, allocation);
    if ((allocation->flags & GSW_NINE_OWNS_MEMORY) != 0)
        HeapFree(allocator->heap, 0, allocation->heap_pointer);
    HeapFree(allocator->heap, 0, allocation);
}

static struct nine_allocation *gsw_nine_new_record(
    struct nine_allocator *allocator
)
{
    return (struct nine_allocation *)HeapAlloc(
        allocator->heap,
        HEAP_ZERO_MEMORY,
        sizeof(struct nine_allocation)
    );
}

struct nine_allocation *nine_allocate(
    struct nine_allocator *allocator,
    unsigned size
)
{
    struct nine_allocation *allocation;
    void *memory;
    uintptr_t raw_address;
    uintptr_t aligned_address;
    SIZE_T reserve;

    if (allocator == NULL || size == 0) return NULL;
    if ((SIZE_T)size > (SIZE_T)-1 - (GSW_NINE_ALIGNMENT - 1U)) return NULL;
    allocation = gsw_nine_new_record(allocator);
    if (allocation == NULL) return NULL;
    reserve = (SIZE_T)size + (GSW_NINE_ALIGNMENT - 1U);
    memory = HeapAlloc(allocator->heap, 0, reserve);
    if (memory == NULL) {
        HeapFree(allocator->heap, 0, allocation);
        return NULL;
    }

    raw_address = (uintptr_t)memory;
    aligned_address = (raw_address + (GSW_NINE_ALIGNMENT - 1U)) &
        ~((uintptr_t)GSW_NINE_ALIGNMENT - 1U);
    allocation->pointer = (void *)aligned_address;
    allocation->heap_pointer = memory;
    allocation->size = size;
    allocation->flags = GSW_NINE_OWNS_MEMORY;

    EnterCriticalSection(&allocator->lock);
    if (allocator->destroying) {
        LeaveCriticalSection(&allocator->lock);
        HeapFree(allocator->heap, 0, memory);
        HeapFree(allocator->heap, 0, allocation);
        return NULL;
    }
    gsw_nine_link_locked(allocator, allocation);
    LeaveCriticalSection(&allocator->lock);
    return allocation;
}

void nine_free(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    struct nine_allocation *current;
    struct nine_allocation *parent;

    if (allocator == NULL || allocation == NULL) return;
    EnterCriticalSection(&allocator->lock);
    current = gsw_nine_find_locked(allocator, allocation);
    if (current == NULL) {
        LeaveCriticalSection(&allocator->lock);
        return;
    }

    parent = current->parent;
    if (parent != NULL) {
        gsw_nine_dispose_locked(allocator, current);
        if (parent->child_count != 0) parent->child_count--;
        if (parent->child_count == 0 &&
            (parent->flags & (GSW_NINE_EXTERNAL_ROOT |
                              GSW_NINE_OWNER_RELEASED)) != 0)
            gsw_nine_dispose_locked(allocator, parent);
    } else if (current->child_count != 0) {
        current->flags |= GSW_NINE_OWNER_RELEASED;
    } else {
        gsw_nine_dispose_locked(allocator, current);
    }
    LeaveCriticalSection(&allocator->lock);
}

void nine_free_worker(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    nine_free(allocator, allocation);
}

void *nine_get_pointer(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    struct nine_allocation *current;
    void *pointer = NULL;

    if (allocator == NULL || allocation == NULL) return NULL;
    EnterCriticalSection(&allocator->lock);
    current = gsw_nine_find_locked(allocator, allocation);
    if (current != NULL &&
        !((current->flags & GSW_NINE_OWNER_RELEASED) != 0 &&
          current->parent == NULL))
        pointer = current->pointer;
    LeaveCriticalSection(&allocator->lock);
    return pointer;
}

void nine_pointer_weakrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    (void)allocator;
    (void)allocation;
}

void nine_pointer_strongrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation
)
{
    (void)allocator;
    (void)allocation;
}

void nine_pointer_delayedstrongrelease(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation,
    unsigned *counter
)
{
    (void)allocator;
    (void)allocation;
    (void)counter;
}

struct nine_allocation *nine_suballocate(
    struct nine_allocator *allocator,
    struct nine_allocation *allocation,
    int offset
)
{
    struct nine_allocation *child;
    struct nine_allocation *parent;
    uintptr_t base;
    unsigned displacement;

    if (allocator == NULL || allocation == NULL || offset < 0) return NULL;
    child = gsw_nine_new_record(allocator);
    if (child == NULL) return NULL;

    EnterCriticalSection(&allocator->lock);
    parent = gsw_nine_find_locked(allocator, allocation);
    displacement = (unsigned)offset;
    if (parent == NULL || parent->parent != NULL ||
        (parent->flags & GSW_NINE_OWNER_RELEASED) != 0 ||
        parent->child_count == UINT_MAX ||
        ((parent->flags & GSW_NINE_OWNS_MEMORY) != 0 &&
         displacement >= parent->size)) {
        LeaveCriticalSection(&allocator->lock);
        HeapFree(allocator->heap, 0, child);
        return NULL;
    }

    base = (uintptr_t)parent->pointer;
    if ((uintptr_t)displacement > UINTPTR_MAX - base) {
        LeaveCriticalSection(&allocator->lock);
        HeapFree(allocator->heap, 0, child);
        return NULL;
    }

    child->parent = parent;
    child->pointer = (void *)(base + (uintptr_t)displacement);
    if ((parent->flags & GSW_NINE_OWNS_MEMORY) != 0)
        child->size = parent->size - displacement;
    parent->child_count++;
    gsw_nine_link_locked(allocator, child);
    LeaveCriticalSection(&allocator->lock);
    return child;
}

struct nine_allocation *nine_wrap_external_pointer(
    struct nine_allocator *allocator,
    void *data
)
{
    struct nine_allocation *allocation;

    if (allocator == NULL || data == NULL) return NULL;
    allocation = gsw_nine_new_record(allocator);
    if (allocation == NULL) return NULL;
    allocation->pointer = data;
    allocation->flags = GSW_NINE_EXTERNAL_ROOT;

    EnterCriticalSection(&allocator->lock);
    if (allocator->destroying) {
        LeaveCriticalSection(&allocator->lock);
        HeapFree(allocator->heap, 0, allocation);
        return NULL;
    }
    gsw_nine_link_locked(allocator, allocation);
    LeaveCriticalSection(&allocator->lock);
    return allocation;
}

struct nine_allocator *nine_allocator_create(
    struct NineDevice9 *device,
    int memfd_virtualsizelimit
)
{
    struct nine_allocator *allocator;
    HANDLE heap = GetProcessHeap();

    (void)device;
    (void)memfd_virtualsizelimit;
    if (heap == NULL) return NULL;
    allocator = (struct nine_allocator *)HeapAlloc(
        heap,
        HEAP_ZERO_MEMORY,
        sizeof(struct nine_allocator)
    );
    if (allocator == NULL) return NULL;
    allocator->heap = heap;
    InitializeCriticalSection(&allocator->lock);
    return allocator;
}

void nine_allocator_destroy(struct nine_allocator *allocator)
{
    struct nine_allocation *current;
    struct nine_allocation *next;
    HANDLE heap;

    if (allocator == NULL) return;
    heap = allocator->heap;
    EnterCriticalSection(&allocator->lock);
    allocator->destroying = 1;
    current = allocator->head;
    allocator->head = NULL;
    LeaveCriticalSection(&allocator->lock);

    while (current != NULL) {
        next = current->next;
        if ((current->flags & GSW_NINE_OWNS_MEMORY) != 0)
            HeapFree(heap, 0, current->heap_pointer);
        HeapFree(heap, 0, current);
        current = next;
    }
    DeleteCriticalSection(&allocator->lock);
    HeapFree(heap, 0, allocator);
}
