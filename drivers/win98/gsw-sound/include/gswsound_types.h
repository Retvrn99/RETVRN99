/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_TYPES_H
#define RETVRN99_GSWSOUND_TYPES_H

typedef unsigned char  gsw_u8;
typedef unsigned short gsw_u16;
typedef unsigned long  gsw_u32;
typedef unsigned __int64 gsw_u64;
typedef signed short   gsw_i16;

#define GSW_STATIC_ASSERT(name, condition) typedef char name[(condition) ? 1 : -1]

GSW_STATIC_ASSERT(gsw_u8_is_one_byte, sizeof(gsw_u8) == 1);
GSW_STATIC_ASSERT(gsw_u16_is_two_bytes, sizeof(gsw_u16) == 2);
GSW_STATIC_ASSERT(gsw_u32_is_four_bytes, sizeof(gsw_u32) == 4);
GSW_STATIC_ASSERT(gsw_u64_is_eight_bytes, sizeof(gsw_u64) == 8);
GSW_STATIC_ASSERT(gsw_i16_is_two_bytes, sizeof(gsw_i16) == 2);

#endif
