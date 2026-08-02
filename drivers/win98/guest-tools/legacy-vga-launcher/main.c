/* SPDX-License-Identifier: GPL-3.0-only */

#define WIN32_LEAN_AND_MEAN
#define WINVER 0x0400
#define _WIN32_WINNT 0x0400

#include <windows.h>

#define PIF_RUNNER_CONSOLE_LOG "C:\\QUAKE\\ID1\\QCONSOLE.LOG"
#define PIF_RUNNER_LOG "C:\\QUAKE\\PIFRUN.LOG"
#define PIF_RUNNER_MARKER "RETVRN99_NORMAL_EXIT"
#define PIF_RUNNER_MAX_TITLE 128
#define PIF_RUNNER_MAX_LOG (128UL * 1024UL)
#define PIF_RUNNER_WINDOW_WAIT_MS 30000UL
#define PIF_RUNNER_COMPLETION_WAIT_MS 240000UL
#define PIF_RUNNER_CLOSE_WAIT_MS 10000UL
#define PIF_RUNNER_POLL_MS 100UL

typedef struct PIF_RUNNER_WINDOW_SEARCH {
    HWND window;
} PIF_RUNNER_WINDOW_SEARCH;

static HANDLE runner_log = INVALID_HANDLE_VALUE;

static DWORD runner_length(const char *text)
{
    DWORD length = 0;
    while (text[length] != 0) length++;
    return length;
}

static char runner_upper(char value)
{
    if (value >= 'a' && value <= 'z') return (char)(value - ('a' - 'A'));
    return value;
}

static int runner_contains(const BYTE *bytes, DWORD count, const char *text)
{
    DWORD text_length = runner_length(text);
    DWORD offset;
    DWORD index;
    if (text_length == 0 || count < text_length) return 0;
    for (offset = 0; offset <= count - text_length; offset++) {
        for (index = 0; index < text_length; index++) {
            if (bytes[offset + index] != (BYTE)text[index]) break;
        }
        if (index == text_length) return 1;
    }
    return 0;
}

static int runner_contains_case(const char *text, const char *match)
{
    DWORD text_length = runner_length(text);
    DWORD match_length = runner_length(match);
    DWORD offset;
    DWORD index;
    if (match_length == 0 || text_length < match_length) return 0;
    for (offset = 0; offset <= text_length - match_length; offset++) {
        for (index = 0; index < match_length; index++) {
            if (runner_upper(text[offset + index]) != runner_upper(match[index])) break;
        }
        if (index == match_length) return 1;
    }
    return 0;
}

static int runner_equal(const char *left, const char *right)
{
    DWORD index = 0;
    while (left[index] != 0 && right[index] != 0) {
        if (left[index] != right[index]) return 0;
        index++;
    }
    return left[index] == right[index];
}

static int runner_equal_case(const char *left, const char *right)
{
    DWORD index = 0;
    while (left[index] != 0 && right[index] != 0) {
        if (runner_upper(left[index]) != runner_upper(right[index])) return 0;
        index++;
    }
    return left[index] == right[index];
}

static const char *runner_parameters(void)
{
    const char *command = GetCommandLineA();
    if (*command == '"') {
        command++;
        while (*command != 0 && *command != '"') command++;
        if (*command == '"') command++;
    } else {
        while (*command != 0 && *command != ' ' && *command != '\t') command++;
    }
    while (*command == ' ' || *command == '\t') command++;
    return command;
}

static void runner_write(const char *text)
{
    DWORD written;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD length = runner_length(text);
    if (output != NULL && output != INVALID_HANDLE_VALUE)
        (void)WriteFile(output, text, length, &written, NULL);
    if (runner_log != NULL && runner_log != INVALID_HANDLE_VALUE)
        (void)WriteFile(runner_log, text, length, &written, NULL);
}

static BOOL CALLBACK runner_find_window(HWND window, LPARAM parameter)
{
    PIF_RUNNER_WINDOW_SEARCH *search = (PIF_RUNNER_WINDOW_SEARCH *)parameter;
    char title[PIF_RUNNER_MAX_TITLE];
    title[0] = 0;
    (void)GetWindowTextA(window, title, sizeof(title));
    if (!runner_contains_case(title, "QUAKE")) return TRUE;
    search->window = window;
    return !runner_equal_case(title, "QUAKE");
}

static HWND runner_wait_for_window(void)
{
    DWORD started = GetTickCount();
    while (GetTickCount() - started < PIF_RUNNER_WINDOW_WAIT_MS) {
        PIF_RUNNER_WINDOW_SEARCH search;
        search.window = NULL;
        (void)EnumWindows(runner_find_window, (LPARAM)&search);
        if (search.window != NULL) return search.window;
        Sleep(PIF_RUNNER_POLL_MS);
    }
    return NULL;
}

static int runner_read_completion(int *timedemo, int *marker)
{
    HANDLE file;
    DWORD size;
    DWORD read = 0;
    BYTE *bytes;
    int success = 0;
    file = CreateFileA(
        PIF_RUNNER_CONSOLE_LOG,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE) return 1;
    size = GetFileSize(file, NULL);
    if (size == INVALID_FILE_SIZE || size > PIF_RUNNER_MAX_LOG) goto cleanup;
    if (size == 0) {
        success = 1;
        goto cleanup;
    }
    bytes = (BYTE *)HeapAlloc(GetProcessHeap(), 0, size);
    if (bytes == NULL) goto cleanup;
    if (ReadFile(file, bytes, size, &read, NULL) && read == size) {
        if (runner_contains(bytes, size, " frames ") &&
            runner_contains(bytes, size, " seconds ") &&
            runner_contains(bytes, size, " fps"))
            *timedemo = 1;
        if (runner_contains(bytes, size, PIF_RUNNER_MARKER)) *marker = 1;
        success = 1;
    }
    HeapFree(GetProcessHeap(), 0, bytes);
cleanup:
    CloseHandle(file);
    return success;
}

static int runner_title_completed(HWND window)
{
    char title[PIF_RUNNER_MAX_TITLE];
    title[0] = 0;
    if (!IsWindow(window) || GetWindowTextA(window, title, sizeof(title)) == 0) return 0;
    return runner_contains_case(title, "QUAKE") &&
        !runner_equal_case(title, "QUAKE");
}

static int runner_wait_for_completion(HWND window)
{
    DWORD started = GetTickCount();
    int timedemo = 0;
    int marker = 0;
    while (GetTickCount() - started < PIF_RUNNER_COMPLETION_WAIT_MS) {
        if (!runner_read_completion(&timedemo, &marker)) {
            runner_write("PIFRUN console-log-read-failed\r\n");
            return 0;
        }
        if (timedemo && marker) {
            if (!IsWindow(window)) return 1;
            if (runner_title_completed(window)) return 1;
        }
        Sleep(PIF_RUNNER_POLL_MS);
    }
    runner_write("PIFRUN normal-completion-timeout\r\n");
    return 0;
}

static int runner_close_completed_window(HWND window)
{
    DWORD started;
    if (!IsWindow(window)) return 1;
    if (!PostMessageA(window, WM_CLOSE, 0, 0)) return 0;
    started = GetTickCount();
    while (GetTickCount() - started < PIF_RUNNER_CLOSE_WAIT_MS) {
        if (!IsWindow(window)) return 1;
        Sleep(PIF_RUNNER_POLL_MS);
    }
    return 0;
}

static DWORD runner_execute(const char *parameters)
{
    HWND window;
    if (!runner_equal(parameters, "/wait")) {
        runner_write("PIFRUN invalid-arguments\r\n");
        return 2;
    }
    window = runner_wait_for_window();
    if (window == NULL) {
        runner_write("PIFRUN task-window-not-found\r\n");
        return 6;
    }
    if (!runner_wait_for_completion(window)) return 8;
    if (!runner_close_completed_window(window)) {
        runner_write("PIFRUN completed-window-close-failed\r\n");
        return 9;
    }
    runner_write("PIFRUN normal-completion\r\n");
    return 0;
}

void mainCRTStartup(void)
{
    const char *parameters = runner_parameters();
    DWORD result;
    runner_log = CreateFileA(
        PIF_RUNNER_LOG,
        GENERIC_WRITE,
        FILE_SHARE_READ,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    result = runner_execute(parameters);
    if (runner_log != INVALID_HANDLE_VALUE) CloseHandle(runner_log);
    ExitProcess(result);
}
