// SPDX-License-Identifier: GPL-3.0-only
package hv

// WHPX bindings. Struct layout copied from WinHvPlatformDefs.h /
// WinHvEmulation.h (SDK 10.0.26100) — sizes matter.

import win32 "core:sys/windows"

HRESULT :: win32.HRESULT

WHV_PARTITION_HANDLE :: rawptr
WHV_EMULATOR_HANDLE :: rawptr

WHV_CAPABILITY_CODE :: enum u32 {
	HypervisorPresent = 0x00000000,
}

WHV_PARTITION_PROPERTY_CODE :: enum u32 {
	ExtendedVmExits = 0x00000001,
	ProcessorCount  = 0x00001FFF,
}

WHV_MAP_GPA_RANGE_FLAG_READ: u32 : 0x1
WHV_MAP_GPA_RANGE_FLAG_WRITE: u32 : 0x2
WHV_MAP_GPA_RANGE_FLAG_EXECUTE: u32 : 0x4

WHV_REGISTER_NAME :: enum u32 {
	Rax                         = 0x00000000,
	Rcx                         = 0x00000001,
	Rdx                         = 0x00000002,
	Rbx                         = 0x00000003,
	Rsp                         = 0x00000004,
	Rbp                         = 0x00000005,
	Rsi                         = 0x00000006,
	Rdi                         = 0x00000007,
	R8                          = 0x00000008,
	R9                          = 0x00000009,
	R10                         = 0x0000000A,
	R11                         = 0x0000000B,
	R12                         = 0x0000000C,
	R13                         = 0x0000000D,
	R14                         = 0x0000000E,
	R15                         = 0x0000000F,
	Rip                         = 0x00000010,
	Rflags                      = 0x00000011,
	Es                          = 0x00000012,
	Cs                          = 0x00000013,
	Ss                          = 0x00000014,
	Ds                          = 0x00000015,
	Fs                          = 0x00000016,
	Gs                          = 0x00000017,
	Ldtr                        = 0x00000018,
	Tr                          = 0x00000019,
	Idtr                        = 0x0000001A,
	Gdtr                        = 0x0000001B,
	Cr0                         = 0x0000001C,
	Cr2                         = 0x0000001D,
	Cr3                         = 0x0000001E,
	Cr4                         = 0x0000001F,
	PendingInterruption         = 0x80000000,
	InterruptState              = 0x80000001,
	PendingEvent                = 0x80000002,
	DeliverabilityNotifications = 0x80000004,
}

// 16 bytes
WHV_X64_SEGMENT_REGISTER :: struct {
	Base:       u64,
	Limit:      u32,
	Selector:   u16,
	Attributes: u16,
}

WHV_X64_TABLE_REGISTER :: struct {
	Pad:   [3]u16,
	Limit: u16,
	Base:  u64,
}

// 16-byte union; the SDK aligns it to 16 via WHV_UINT128 (DECLSPEC_ALIGN(16)) —
// WinHvPlatform.dll does aligned SSE access on register value arrays.
WHV_REGISTER_VALUE :: struct #raw_union #align(16) {
	Reg128:  [2]u64,
	Reg64:   u64,
	Reg32:   u32,
	Reg16:   u16,
	Reg8:    u8,
	Segment: WHV_X64_SEGMENT_REGISTER,
	Table:   WHV_X64_TABLE_REGISTER,
}

#assert(size_of(WHV_REGISTER_VALUE) == 16)
#assert(align_of(WHV_REGISTER_VALUE) == 16)
#assert(size_of(WHV_X64_SEGMENT_REGISTER) == 16)

WHV_RUN_VP_EXIT_REASON :: enum u32 {
	None                   = 0x00000000,
	MemoryAccess           = 0x00000001,
	X64IoPortAccess        = 0x00000002,
	UnrecoverableException = 0x00000004,
	InvalidVpRegisterValue = 0x00000005,
	UnsupportedFeature     = 0x00000006,
	X64InterruptWindow     = 0x00000007,
	X64Halt                = 0x00000008,
	X64ApicEoi             = 0x00000009,
	X64MsrAccess           = 0x00001000,
	X64Cpuid               = 0x00001001,
	Exception              = 0x00001002,
	Canceled               = 0x00002001,
}

// 40 bytes
WHV_VP_EXIT_CONTEXT :: struct {
	ExecutionState:       u16,
	InstructionLengthCr8: u8, // bits 0-3 length, 4-7 CR8
	Reserved:             u8,
	Reserved2:            u32,
	Cs:                   WHV_X64_SEGMENT_REGISTER,
	Rip:                  u64,
	Rflags:               u64,
}

#assert(size_of(WHV_VP_EXIT_CONTEXT) == 40)

WHV_MEMORY_ACCESS_CONTEXT :: struct {
	InstructionByteCount: u8,
	Reserved:             [3]u8,
	InstructionBytes:     [16]u8,
	AccessInfo:           u32,
	Gpa:                  u64,
	Gva:                  u64,
}

#assert(size_of(WHV_MEMORY_ACCESS_CONTEXT) == 40)

WHV_X64_IO_PORT_ACCESS_CONTEXT :: struct {
	InstructionByteCount: u8,
	Reserved:             [3]u8,
	InstructionBytes:     [16]u8,
	AccessInfo:           u32,
	PortNumber:           u16,
	Reserved2:            [3]u16,
	Rax:                  u64,
	Rcx:                  u64,
	Rsi:                  u64,
	Rdi:                  u64,
	Ds:                   WHV_X64_SEGMENT_REGISTER,
	Es:                   WHV_X64_SEGMENT_REGISTER,
}

#assert(size_of(WHV_X64_IO_PORT_ACCESS_CONTEXT) == 96)

// padding covers the union members we do not use (SDK: 224 total)
WHV_RUN_VP_EXIT_CONTEXT :: struct {
	ExitReason: WHV_RUN_VP_EXIT_REASON,
	Reserved:   u32,
	VpContext:  WHV_VP_EXIT_CONTEXT,
	u:          struct #raw_union {
		MemoryAccess: WHV_MEMORY_ACCESS_CONTEXT,
		IoPortAccess: WHV_X64_IO_PORT_ACCESS_CONTEXT,
		_pad:         [176]u8,
	},
}

#assert(size_of(WHV_RUN_VP_EXIT_CONTEXT) == 224)

WHV_EMULATOR_STATUS :: struct #raw_union {
	AsUINT32: u32, // bit 0 = EmulationSuccessful
}

WHV_EMULATOR_MEMORY_ACCESS_INFO :: struct {
	GpaAddress: u64,
	Direction:  u8, // 0 = read, 1 = write
	AccessSize: u8,
	Data:       [8]u8,
}

WHV_EMULATOR_IO_ACCESS_INFO :: struct {
	Direction:  u8, // 0 = in, 1 = out
	Port:       u16,
	AccessSize: u16,
	Data:       u32,
}

#assert(size_of(WHV_EMULATOR_IO_ACCESS_INFO) == 12)

WHV_EMULATOR_CALLBACKS :: struct {
	Size:             u32,
	Reserved:         u32,
	IoPort:           proc "system" (ctx: rawptr, io: ^WHV_EMULATOR_IO_ACCESS_INFO) -> HRESULT,
	Memory:           proc "system" (ctx: rawptr, mem: ^WHV_EMULATOR_MEMORY_ACCESS_INFO) -> HRESULT,
	GetRegs:          proc "system" (ctx: rawptr, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT,
	SetRegs:          proc "system" (ctx: rawptr, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT,
	TranslateGvaPage: proc "system" (ctx: rawptr, gva: u64, flags: u32, result: ^u32, gpa: ^u64) -> HRESULT,
}

foreign import whp "system:WinHvPlatform.lib"
foreign import whe "system:WinHvEmulation.lib"

@(default_calling_convention = "system")
foreign whp {
	WHvGetCapability :: proc(code: WHV_CAPABILITY_CODE, buf: rawptr, buf_size: u32, written: ^u32) -> HRESULT ---
	WHvCreatePartition :: proc(part: ^WHV_PARTITION_HANDLE) -> HRESULT ---
	WHvSetPartitionProperty :: proc(part: WHV_PARTITION_HANDLE, code: WHV_PARTITION_PROPERTY_CODE, buf: rawptr, buf_size: u32) -> HRESULT ---
	WHvSetupPartition :: proc(part: WHV_PARTITION_HANDLE) -> HRESULT ---
	WHvMapGpaRange :: proc(part: WHV_PARTITION_HANDLE, source: rawptr, gpa: u64, size: u64, flags: u32) -> HRESULT ---
	WHvCreateVirtualProcessor :: proc(part: WHV_PARTITION_HANDLE, index: u32, flags: u32) -> HRESULT ---
	WHvRunVirtualProcessor :: proc(part: WHV_PARTITION_HANDLE, index: u32, exit_ctx: rawptr, exit_ctx_size: u32) -> HRESULT ---
	WHvCancelRunVirtualProcessor :: proc(part: WHV_PARTITION_HANDLE, index: u32, flags: u32) -> HRESULT ---
	WHvGetVirtualProcessorRegisters :: proc(part: WHV_PARTITION_HANDLE, index: u32, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT ---
	WHvSetVirtualProcessorRegisters :: proc(part: WHV_PARTITION_HANDLE, index: u32, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT ---
	WHvDeletePartition :: proc(part: WHV_PARTITION_HANDLE) -> HRESULT ---
}

@(default_calling_convention = "system")
foreign whe {
	WHvEmulatorCreateEmulator :: proc(callbacks: ^WHV_EMULATOR_CALLBACKS, emu: ^WHV_EMULATOR_HANDLE) -> HRESULT ---
	WHvEmulatorDestroyEmulator :: proc(emu: WHV_EMULATOR_HANDLE) -> HRESULT ---
	WHvEmulatorTryIoEmulation :: proc(emu: WHV_EMULATOR_HANDLE, ctx: rawptr, vp_ctx: ^WHV_VP_EXIT_CONTEXT, io_ctx: ^WHV_X64_IO_PORT_ACCESS_CONTEXT, status: ^WHV_EMULATOR_STATUS) -> HRESULT ---
	WHvEmulatorTryMmioEmulation :: proc(emu: WHV_EMULATOR_HANDLE, ctx: rawptr, vp_ctx: ^WHV_VP_EXIT_CONTEXT, mmio_ctx: ^WHV_MEMORY_ACCESS_CONTEXT, status: ^WHV_EMULATOR_STATUS) -> HRESULT ---
}
