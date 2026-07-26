/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static void gsw_vbe_count(GSW_SESSION *session, const BYTE *bytes, DWORD length)
{
	DWORD offset = 0;
	while(offset < length)
	{
		DWORD tabs = 0;
		DWORD field = 0;
		DWORD field_length = 0;
		while(offset < length && !(bytes[offset] == '\r' && offset + 1 < length && bytes[offset + 1] == '\n'))
		{
			if(bytes[offset] == '\t')
			{
				tabs++;
				if(tabs == 10) field = offset + 1;
				else if(tabs == 11) field_length = offset - field;
			}
			offset++;
		}
		session->tested++;
		if(field_length == 4 && bytes[field] == 'W') session->warnings++;
		else if(field_length == 4 && bytes[field] == 'F') session->failed++;
		else if(field_length == 11 && bytes[field] == 'U') session->unavailable++;
		if(offset + 1 < length) offset += 2;
	}
}

BOOL gsw_vbe_import(GSW_SESSION *session)
{
	STARTUPINFOA startup;
	PROCESS_INFORMATION process;
	char normal_command[] = "C:\\GSWGFX\\GSWVBE.EXE";
	char exhaustive_command[] = "C:\\GSWGFX\\GSWVBE.EXE /exhaustive";
	char *command;
	HANDLE file = INVALID_HANDLE_VALUE;
	DWORD exit_code = 2;
	DWORD size;
	DWORD read = 0;
	BYTE *bytes = NULL;
	BOOL success = FALSE;
	if(session == NULL) return FALSE;
	command = session->options.exhaustive ? exhaustive_command : normal_command;
	gsw_zero(&startup, sizeof(startup));
	gsw_zero(&process, sizeof(process));
	if(!session->options.import_vbe)
	{
		DeleteFileA(GSW_VBE_PATH);
		startup.cb = sizeof(startup);
		if(!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, "C:\\GSWGFX", &startup, &process))
			return FALSE;
		if(WaitForSingleObject(process.hProcess, 120000UL) != WAIT_OBJECT_0) goto cleanup;
		if(!GetExitCodeProcess(process.hProcess, &exit_code) || exit_code != 0) goto cleanup;
	}
	file = CreateFileA(GSW_VBE_PATH, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
		FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
	if(file == INVALID_HANDLE_VALUE) goto cleanup;
	size = GetFileSize(file, NULL);
	if(size == INVALID_FILE_SIZE || size == 0 || size > 128UL * 1024UL) goto cleanup;
	bytes = (BYTE *)HeapAlloc(GetProcessHeap(), 0, size);
	if(bytes == NULL) goto cleanup;
	if(!ReadFile(file, bytes, size, &read, NULL) || read != size) goto cleanup;
	if(!gsw_report_import_rows(&session->report, bytes, size)) goto cleanup;
	gsw_vbe_count(session, bytes, size);
	success = TRUE;
cleanup:
	if(file != INVALID_HANDLE_VALUE) CloseHandle(file);
	if(bytes != NULL) HeapFree(GetProcessHeap(), 0, bytes);
	if(process.hThread != NULL) CloseHandle(process.hThread);
	if(process.hProcess != NULL) CloseHandle(process.hProcess);
	if(success && !DeleteFileA(GSW_VBE_PATH)) success = FALSE;
	return success;
}
