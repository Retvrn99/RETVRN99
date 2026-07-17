/* SPDX-License-Identifier: GPL-3.0-only */

#include <windows.h>
#include "gsw3d_abi.h"

#define GSW3D_SMOKE_CONTEXT_ID 1UL
#define GSW3D_SMOKE_SURFACE_ID 1UL
#define GSW3D_SMOKE_VERTEX_ID  2UL
#define GSW3D_SMOKE_WIDTH      640UL
#define GSW3D_SMOKE_HEIGHT     480UL
#define GSW3D_SMOKE_TIMEOUT_MS 10000UL

typedef char SmokeQuerySizeCheck[(sizeof(GSW3DQuery) == 32) ? 1 : -1];
typedef char SmokeContextSizeCheck[(sizeof(GSW3DContextRequest) == 8) ? 1 : -1];
typedef char SmokeSubmitSizeCheck[(sizeof(GSW3DSubmitRequest) == 12) ? 1 : -1];
typedef char SmokeUploadSizeCheck[(sizeof(GSW3DUploadRequest) == 20) ? 1 : -1];
typedef char SmokePresentSizeCheck[(sizeof(GSW3DPresentRequest) == 48) ? 1 : -1];
typedef char SmokeFenceSizeCheck[(sizeof(GSW3DFencePollRequest) == 12) ? 1 : -1];
typedef char SmokeResultSizeCheck[(sizeof(GSW3DResult) == 32) ? 1 : -1];

static HANDLE smoke_log = INVALID_HANDLE_VALUE;
static BYTE smoke_input[sizeof(GSW3DSubmitRequest) + 360];

static void smoke_zero(void *destination, DWORD bytes)
{
	BYTE *output = (BYTE *)destination;
	DWORD i;
	for(i = 0; i < bytes; i++) output[i] = 0;
}

static void smoke_copy(void *destination, const void *source, DWORD bytes)
{
	BYTE *output = (BYTE *)destination;
	const BYTE *input = (const BYTE *)source;
	DWORD i;
	for(i = 0; i < bytes; i++) output[i] = input[i];
}

static void smoke_write_handle(HANDLE handle, const char *text, DWORD bytes)
{
	DWORD written;
	if(handle != NULL && handle != INVALID_HANDLE_VALUE)
		(void)WriteFile(handle, text, bytes, &written, NULL);
}

static void smoke_write(const char *text, DWORD bytes)
{
	smoke_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), text, bytes);
	smoke_write_handle(smoke_log, text, bytes);
}

#define SMOKE_TEXT(value) smoke_write(value, sizeof(value) - 1)

static void smoke_write_hex(DWORD value)
{
	static const char digits[] = "0123456789ABCDEF";
	char output[8];
	DWORD i;
	for(i = 0; i < 8; i++)
		output[i] = digits[(value >> ((7 - i) * 4)) & 0xF];
	smoke_write(output, sizeof(output));
}

static void smoke_word(BYTE *bytes, DWORD offset, DWORD value)
{
	bytes[offset] = (BYTE)value;
	bytes[offset + 1] = (BYTE)(value >> 8);
	bytes[offset + 2] = (BYTE)(value >> 16);
	bytes[offset + 3] = (BYTE)(value >> 24);
}

static void smoke_command(BYTE *bytes, DWORD offset, DWORD opcode, DWORD body_bytes)
{
	smoke_word(bytes, offset, opcode);
	smoke_word(bytes, offset + 4, body_bytes);
}

static void smoke_surface(
	BYTE *bytes, DWORD offset, DWORD id, DWORD flags, DWORD format,
	DWORD width, DWORD height
)
{
	smoke_command(bytes, offset, 1070, 56);
	smoke_word(bytes, offset + 8, id);
	smoke_word(bytes, offset + 12, flags);
	smoke_word(bytes, offset + 16, format);
	smoke_word(bytes, offset + 20, 1);
	smoke_word(bytes, offset + 52, width);
	smoke_word(bytes, offset + 56, height);
	smoke_word(bytes, offset + 60, 1);
}

static void smoke_definitions(BYTE *bytes)
{
	smoke_zero(bytes, 128);
	smoke_surface(bytes, 0, GSW3D_SMOKE_SURFACE_ID, 0x40, 1,
		GSW3D_SMOKE_WIDTH, GSW3D_SMOKE_HEIGHT);
	smoke_surface(bytes, 64, GSW3D_SMOKE_VERTEX_ID, 0x12, 37, 60, 1);
}

static void smoke_vertices(BYTE *bytes)
{
	static const DWORD words[15] = {
		0x43A00000UL, 0x42A00000UL, 0x3F000000UL, 0x3F800000UL, 0xFFFF0000UL,
		0x440C0000UL, 0x43C80000UL, 0x3F000000UL, 0x3F800000UL, 0xFF00FF00UL,
		0x42A00000UL, 0x43C80000UL, 0x3F000000UL, 0x3F800000UL, 0xFF0000FFUL
	};
	DWORD i;
	for(i = 0; i < 15; i++) smoke_word(bytes, i * 4, words[i]);
}

static void smoke_render(BYTE *bytes)
{
	static const DWORD render_target[5] = {1, 2, 1, 0, 0};
	static const DWORD viewport[5] = {1, 0, 0, 640, 480};
	static const DWORD render_states[15] = {
		1, 1, 0, 2, 0, 5, 0, 9, 0, 35, 1, 47, 15, 30, 2
	};
	static const DWORD texture_states[16] = {
		1, 0, 1, 0xFFFFFFFFUL, 0, 2, 2, 0, 3, 3, 0, 5, 2, 0, 6, 3
	};
	static const DWORD clear[9] = {
		1, 1, 0xFF101018UL, 0x3F800000UL, 0, 0, 0, 640, 480
	};
	static const DWORD draw[28] = {
		1, 2, 1, 3, 0, 9, 0, 2, 0, 20, 0, 0, 4, 0,
		10, 0, 2, 16, 20, 0, 0, 1, 1, 0xFFFFFFFFUL, 0, 0, 0, 0
	};
	DWORD i;

	smoke_zero(bytes, 360);
	smoke_command(bytes, 0, 1050, 20);
	for(i = 0; i < 5; i++) smoke_word(bytes, 8 + i * 4, render_target[i]);
	smoke_command(bytes, 28, 1055, 20);
	for(i = 0; i < 5; i++) smoke_word(bytes, 36 + i * 4, viewport[i]);
	smoke_command(bytes, 56, 1049, 60);
	for(i = 0; i < 15; i++) smoke_word(bytes, 64 + i * 4, render_states[i]);
	smoke_command(bytes, 124, 1051, 64);
	for(i = 0; i < 16; i++) smoke_word(bytes, 132 + i * 4, texture_states[i]);
	smoke_command(bytes, 196, 1057, 36);
	for(i = 0; i < 9; i++) smoke_word(bytes, 204 + i * 4, clear[i]);
	smoke_command(bytes, 240, 1063, 112);
	for(i = 0; i < 28; i++) smoke_word(bytes, 248 + i * 4, draw[i]);
}

static BOOL smoke_ioctl(
	HANDLE device, DWORD code, const void *input, DWORD input_bytes,
	void *output, DWORD output_bytes
)
{
	DWORD returned = 0;
	return DeviceIoControl(
		device, code, (LPVOID)input, input_bytes, output, output_bytes,
		&returned, NULL
	);
}

static BOOL smoke_wait(HANDLE device, const GSW3DResult *submission)
{
	GSW3DFencePollRequest request;
	GSW3DResult result;
	DWORD started;
	if(submission == NULL || submission->success == 0 ||
	   (submission->fence_low == 0 && submission->fence_high == 0)) return FALSE;
	request.cb = sizeof(request);
	request.fence_low = submission->fence_low;
	request.fence_high = submission->fence_high;
	started = GetTickCount();
	while(GetTickCount() - started < GSW3D_SMOKE_TIMEOUT_MS)
	{
		smoke_zero(&result, sizeof(result));
		if(!smoke_ioctl(device, GSW3D_IOCTL_FENCE_POLL, &request, sizeof(request),
			&result, sizeof(result))) return FALSE;
		if(result.cb != sizeof(result)) return FALSE;
		if(result.success != 0) return TRUE;
		if((result.status & GSW3D_STATUS_ERROR) != 0 || result.error != GSW3D_ERROR_NONE)
			return FALSE;
		Sleep(1);
	}
	return FALSE;
}

static BOOL smoke_context(HANDLE device, BOOL create, GSW3DResult *result)
{
	GSW3DContextRequest request;
	request.cb = sizeof(request);
	request.context_id = GSW3D_SMOKE_CONTEXT_ID;
	smoke_zero(result, sizeof(*result));
	return smoke_ioctl(
		device, create ? GSW3D_IOCTL_CONTEXT_CREATE : GSW3D_IOCTL_CONTEXT_DESTROY,
		&request, sizeof(request), result, sizeof(*result)
	) && result->cb == sizeof(*result) && result->success != 0;
}

static BOOL smoke_submit(HANDLE device, const BYTE *batch, DWORD bytes, GSW3DResult *result)
{
	GSW3DSubmitRequest request;
	request.cb = sizeof(request);
	request.context_id = GSW3D_SMOKE_CONTEXT_ID;
	request.byte_count = bytes;
	smoke_copy(smoke_input, &request, sizeof(request));
	smoke_copy(smoke_input + sizeof(request), batch, bytes);
	smoke_zero(result, sizeof(*result));
	return smoke_ioctl(
		device, GSW3D_IOCTL_SUBMIT, smoke_input, sizeof(request) + bytes,
		result, sizeof(*result)
	) && result->cb == sizeof(*result) && result->success != 0;
}

static BOOL smoke_upload(HANDLE device, const BYTE *data, DWORD bytes, GSW3DResult *result)
{
	GSW3DUploadRequest request;
	request.cb = sizeof(request);
	request.resource_id = GSW3D_SMOKE_VERTEX_ID;
	request.destination_offset_low = 0;
	request.destination_offset_high = 0;
	request.byte_count = bytes;
	smoke_copy(smoke_input, &request, sizeof(request));
	smoke_copy(smoke_input + sizeof(request), data, bytes);
	smoke_zero(result, sizeof(*result));
	return smoke_ioctl(
		device, GSW3D_IOCTL_UPLOAD, smoke_input, sizeof(request) + bytes,
		result, sizeof(*result)
	) && result->cb == sizeof(*result) && result->success != 0;
}

static BOOL smoke_present(HANDLE device, GSW3DResult *result)
{
	GSW3DPresentRequest request;
	smoke_zero(&request, sizeof(request));
	request.cb = sizeof(request);
	request.context_id = GSW3D_SMOKE_CONTEXT_ID;
	request.surface_id = GSW3D_SMOKE_SURFACE_ID;
	request.source_width = GSW3D_SMOKE_WIDTH;
	request.source_height = GSW3D_SMOKE_HEIGHT;
	request.destination_width = GSW3D_SMOKE_WIDTH;
	request.destination_height = GSW3D_SMOKE_HEIGHT;
	request.interval = 1;
	smoke_zero(result, sizeof(*result));
	return smoke_ioctl(
		device, GSW3D_IOCTL_PRESENT, &request, sizeof(request), result, sizeof(*result)
	) && result->cb == sizeof(*result) && result->success != 0;
}

static void smoke_destroy_batch(BYTE *bytes)
{
	smoke_zero(bytes, 24);
	smoke_command(bytes, 0, 1041, 4);
	smoke_word(bytes, 8, GSW3D_SMOKE_VERTEX_ID);
	smoke_command(bytes, 12, 1041, 4);
	smoke_word(bytes, 20, GSW3D_SMOKE_SURFACE_ID);
}

static HANDLE smoke_open_device(void)
{
	HANDLE device = CreateFileA(
		"\\\\.\\gswmini.vxd", 0, 0, NULL, CREATE_NEW,
		FILE_FLAG_DELETE_ON_CLOSE, NULL
	);
	if(device == INVALID_HANDLE_VALUE)
	{
		device = CreateFileA(
			"\\\\.\\GSWVXD", 0, 0, NULL, CREATE_NEW,
			FILE_FLAG_DELETE_ON_CLOSE, NULL
		);
	}
	return device;
}

#if defined(GSW3D_SMOKE_FIXTURE_DUMP)
static DWORD smoke_run(void)
{
	HANDLE fixture;
	BYTE definitions[128];
	BYTE vertices[60];
	BYTE render[360];
	BYTE destroy[24];

	smoke_definitions(definitions);
	smoke_vertices(vertices);
	smoke_render(render);
	smoke_destroy_batch(destroy);
	fixture = CreateFileA(
		"GSW3D.FIX", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
		FILE_ATTRIBUTE_NORMAL, NULL
	);
	if(fixture == INVALID_HANDLE_VALUE) return 20;
	smoke_write_handle(fixture, (const char *)definitions, sizeof(definitions));
	smoke_write_handle(fixture, (const char *)vertices, sizeof(vertices));
	smoke_write_handle(fixture, (const char *)render, sizeof(render));
	smoke_write_handle(fixture, (const char *)destroy, sizeof(destroy));
	CloseHandle(fixture);
	return 0;
}
#else
static DWORD smoke_run(void)
{
	HANDLE device;
	GSW3DQuery query;
	GSW3DResult result;
	BYTE definitions[128];
	BYTE vertices[60];
	BYTE render[360];
	BYTE destroy[24];
	DWORD required;
	DWORD present_fence_low;
	DWORD present_fence_high;

	smoke_log = CreateFileA(
		"GSW3D.LOG", GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
		FILE_ATTRIBUTE_NORMAL, NULL
	);
	SMOKE_TEXT("GSW3D_SMOKE BEGIN\r\n");
	device = smoke_open_device();
	if(device == INVALID_HANDLE_VALUE)
	{
		SMOKE_TEXT("GSW3D_SMOKE UNAVAILABLE open\r\n");
		return 2;
	}

	smoke_zero(&query, sizeof(query));
	if(!smoke_ioctl(device, GSW3D_IOCTL_QUERY, NULL, 0, &query, sizeof(query)))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL query\r\n");
		CloseHandle(device);
		return 3;
	}
	if(query.available == 0)
	{
		SMOKE_TEXT("GSW3D_SMOKE UNAVAILABLE capability\r\n");
		CloseHandle(device);
		return 2;
	}
	required = GSW3D_CAP_SVGA9 | GSW3D_CAP_DIRECT_PRESENT |
		GSW3D_CAP_RESOURCE_UPLOAD | GSW3D_CAP_ASYNC_COMPLETION;
	if(query.cb != sizeof(query) || query.version != GSW3D_ABI_VERSION ||
	   (query.capabilities & required) != required ||
	   query.packet_format != GSW3D_PACKET_SVGA9 ||
	   query.staging_bytes < GSW3D_STAGING_BYTES ||
	   query.maximum_batch_bytes < 360 ||
	   (query.present_intervals & (1UL << 1)) == 0)
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL contract\r\n");
		CloseHandle(device);
		return 4;
	}

	smoke_definitions(definitions);
	smoke_vertices(vertices);
	smoke_render(render);
	smoke_destroy_batch(destroy);
	if(!smoke_context(device, TRUE, &result) || !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL context-create\r\n");
		CloseHandle(device);
		return 5;
	}
	if(!smoke_submit(device, definitions, sizeof(definitions), &result) ||
	   !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL definitions\r\n");
		CloseHandle(device);
		return 6;
	}
	if(!smoke_upload(device, vertices, sizeof(vertices), &result) ||
	   !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL upload\r\n");
		CloseHandle(device);
		return 7;
	}
	if(!smoke_submit(device, render, sizeof(render), &result) ||
	   !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL render\r\n");
		CloseHandle(device);
		return 8;
	}
	if(!smoke_present(device, &result) || !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL present\r\n");
		CloseHandle(device);
		return 9;
	}
	present_fence_low = result.fence_low;
	present_fence_high = result.fence_high;
	Sleep(2000);
	if(!smoke_submit(device, destroy, sizeof(destroy), &result) ||
	   !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL resource-destroy\r\n");
		CloseHandle(device);
		return 10;
	}
	if(!smoke_context(device, FALSE, &result) || !smoke_wait(device, &result))
	{
		SMOKE_TEXT("GSW3D_SMOKE FAIL context-destroy\r\n");
		CloseHandle(device);
		return 11;
	}
	SMOKE_TEXT("GSW3D_SMOKE PASS fence=");
	smoke_write_hex(present_fence_high);
	SMOKE_TEXT(":");
	smoke_write_hex(present_fence_low);
	SMOKE_TEXT("\r\n");
	CloseHandle(device);
	if(smoke_log != INVALID_HANDLE_VALUE) CloseHandle(smoke_log);
	return 0;
}
#endif

void mainCRTStartup(void)
{
	ExitProcess(smoke_run());
}
