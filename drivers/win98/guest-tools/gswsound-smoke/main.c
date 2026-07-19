/* SPDX-License-Identifier: GPL-3.0-only */

#define WIN32_LEAN_AND_MEAN
#define WINVER 0x0400
#define _WIN32_WINNT 0x0400

#include <windows.h>
#include <mmsystem.h>

#include "../../gsw-sound/include/gswsound_telemetry.h"

#define GSW_SOUND_WAVE_NAME "RETVRN99 GSW-Sound"
#define GSW_SOUND_MIXER_NAME "RETVRN99 GSW-Sound Mixer"
#define GSW_SOUND_LOG_NAME "GSWSOUND.LOG"
#define GSW_SOUND_AUDIO_BYTES 65536UL
#define GSW_SOUND_WAIT_MS 5000UL
#define GSW_SOUND_INVALID_ID 0xFFFFFFFFUL

static HANDLE smoke_log = INVALID_HANDLE_VALUE;
static BYTE *smoke_audio;
static volatile LONG smoke_done_count;
static volatile LONG smoke_bad_callback;
static DWORD smoke_callback_cookie;
static UINT smoke_wave_device = (UINT)GSW_SOUND_INVALID_ID;
static UINT smoke_mixer_device = (UINT)GSW_SOUND_INVALID_ID;
static DWORD smoke_failures;

static void smoke_zero(void *destination, DWORD bytes)
{
    BYTE *output = (BYTE *)destination;
    DWORD index;
    for (index = 0; index < bytes; index++) output[index] = 0;
}

static DWORD smoke_length(const char *text)
{
    DWORD length = 0;
    while (text[length] != 0) length++;
    return length;
}

static void smoke_write_handle(HANDLE handle, const char *text, DWORD bytes)
{
    DWORD written;
    if (handle != NULL && handle != INVALID_HANDLE_VALUE)
        (void)WriteFile(handle, text, bytes, &written, NULL);
}

static void smoke_write(const char *text)
{
    DWORD bytes = smoke_length(text);
    smoke_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), text, bytes);
    smoke_write_handle(smoke_log, text, bytes);
}

static void smoke_write_uint(DWORD value)
{
    char output[10];
    DWORD digits = 0;
    DWORD index;
    do {
        output[digits++] = (char)('0' + value % 10UL);
        value /= 10UL;
    } while (value != 0 && digits < sizeof(output));
    for (index = 0; index < digits / 2; index++) {
        char temporary = output[index];
        output[index] = output[digits - index - 1];
        output[digits - index - 1] = temporary;
    }
    smoke_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), output, digits);
    smoke_write_handle(smoke_log, output, digits);
}

static void smoke_write_hex(DWORD value)
{
    static const char digits[] = "0123456789ABCDEF";
    char output[8];
    DWORD index;
    for (index = 0; index < 8; index++) {
        output[7 - index] = digits[value & 0xFUL];
        value >>= 4;
    }
    smoke_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), output, sizeof(output));
    smoke_write_handle(smoke_log, output, sizeof(output));
}

static const char *smoke_telemetry_checkpoint_name(DWORD checkpoint)
{
    switch ((GSW_SOUND_TELEMETRY_CHECKPOINT)checkpoint) {
    case GSW_SOUND_TELEMETRY_SEED: return "seed";
    case GSW_SOUND_TELEMETRY_PNP: return "pnp";
    case GSW_SOUND_TELEMETRY_REGISTER: return "register";
    case GSW_SOUND_TELEMETRY_START: return "start";
    case GSW_SOUND_TELEMETRY_RESOURCE: return "resource";
    case GSW_SOUND_TELEMETRY_MAP: return "map";
    case GSW_SOUND_TELEMETRY_PAGE: return "page";
    case GSW_SOUND_TELEMETRY_BIND: return "bind";
    case GSW_SOUND_TELEMETRY_IRQ: return "irq";
    case GSW_SOUND_TELEMETRY_MODE: return "mode";
    case GSW_SOUND_TELEMETRY_SUCCESS: return "success";
    default: return "unknown";
    }
}

static const char *smoke_telemetry_outcome_name(DWORD outcome)
{
    switch ((GSW_SOUND_TELEMETRY_OUTCOME)outcome) {
    case GSW_SOUND_TELEMETRY_NOT_RUN: return "not-run";
    case GSW_SOUND_TELEMETRY_ENTER: return "enter";
    case GSW_SOUND_TELEMETRY_PASSED: return "passed";
    case GSW_SOUND_TELEMETRY_FAILED: return "failed";
    default: return "unknown";
    }
}

static void smoke_report_start_telemetry(void)
{
    GSW_SOUND_START_TELEMETRY telemetry;
    HKEY key = NULL;
    DWORD type = 0;
    DWORD bytes = sizeof(telemetry);
    LONG error;
    smoke_zero(&telemetry, sizeof(telemetry));
    error = RegOpenKeyA(
        HKEY_LOCAL_MACHINE,
        GSW_SOUND_TELEMETRY_REGISTRY_KEY,
        &key
    );
    if (error == ERROR_SUCCESS) {
        error = RegQueryValueExA(
            key,
            GSW_SOUND_TELEMETRY_VALUE_NAME,
            NULL,
            &type,
            (BYTE *)&telemetry,
            &bytes
        );
        (void)RegCloseKey(key);
    }
    if (error != ERROR_SUCCESS) {
        smoke_write("TELEMETRY unavailable error=");
        smoke_write_uint((DWORD)error);
        smoke_write("\r\n");
        return;
    }
    if (type != REG_BINARY || bytes != sizeof(telemetry) ||
        telemetry.magic != GSW_SOUND_TELEMETRY_MAGIC ||
        telemetry.version != GSW_SOUND_TELEMETRY_VERSION ||
        telemetry.record_bytes != sizeof(telemetry)) {
        smoke_write("TELEMETRY invalid type=");
        smoke_write_uint(type);
        smoke_write(" bytes=");
        smoke_write_uint(bytes);
        smoke_write("\r\n");
        return;
    }
    smoke_write("TELEMETRY checkpoint=");
    smoke_write(smoke_telemetry_checkpoint_name(telemetry.checkpoint));
    smoke_write(" outcome=");
    smoke_write(smoke_telemetry_outcome_name(telemetry.outcome));
    smoke_write(" sequence=");
    smoke_write_uint(telemetry.sequence);
    smoke_write(" detail0=0x");
    smoke_write_hex(telemetry.detail0);
    smoke_write(" detail1=0x");
    smoke_write_hex(telemetry.detail1);
    smoke_write("\r\n");
}

static int smoke_name_equals(const char *left, const char *right)
{
    DWORD index = 0;
    while (left[index] != 0 && right[index] != 0) {
        if (left[index] != right[index]) return 0;
        index++;
    }
    return left[index] == right[index];
}

static void smoke_result(const char *name, int passed)
{
    smoke_write(name);
    smoke_write(passed ? " PASS\r\n" : " FAIL\r\n");
    if (!passed) smoke_failures++;
}

static void CALLBACK smoke_wave_callback(
    HWAVEOUT wave,
    UINT message,
    DWORD_PTR instance,
    DWORD_PTR parameter_one,
    DWORD_PTR parameter_two
)
{
    (void)wave;
    (void)parameter_one;
    (void)parameter_two;
    if (message != WOM_DONE) return;
    if (instance != (DWORD_PTR)&smoke_callback_cookie) {
        InterlockedIncrement(&smoke_bad_callback);
        return;
    }
    InterlockedIncrement(&smoke_done_count);
}

static int smoke_wait_done(WAVEHDR *header, LONG expected, DWORD timeout)
{
    DWORD started = GetTickCount();
    while (GetTickCount() - started < timeout) {
        if ((header->dwFlags & WHDR_DONE) != 0 &&
            smoke_done_count >= expected && smoke_bad_callback == 0)
            return 1;
        Sleep(1);
    }
    return 0;
}

static int smoke_unprepare(HWAVEOUT wave, WAVEHDR *header)
{
    DWORD started = GetTickCount();
    MMRESULT result;
    do {
        result = waveOutUnprepareHeader(wave, header, sizeof(*header));
        if (result == MMSYSERR_NOERROR) return 1;
        if (result != WAVERR_STILLPLAYING) return 0;
        Sleep(1);
    } while (GetTickCount() - started < GSW_SOUND_WAIT_MS);
    return 0;
}

static void smoke_format(
    WAVEFORMATEX *format,
    DWORD rate,
    WORD bits,
    WORD channels
)
{
    smoke_zero(format, sizeof(*format));
    format->wFormatTag = WAVE_FORMAT_PCM;
    format->nChannels = channels;
    format->nSamplesPerSec = rate;
    format->wBitsPerSample = bits;
    format->nBlockAlign = (WORD)(channels * (bits / 8));
    format->nAvgBytesPerSec = rate * format->nBlockAlign;
}

static DWORD smoke_tone(
    const WAVEFORMATEX *format,
    DWORD milliseconds,
    DWORD frequency
)
{
    DWORD frames = (format->nSamplesPerSec * milliseconds) / 1000UL;
    DWORD bytes = frames * format->nBlockAlign;
    DWORD phase = 0;
    DWORD step = (frequency * 65536UL) / format->nSamplesPerSec;
    DWORD frame;
    BYTE *output = smoke_audio;
    if (bytes > GSW_SOUND_AUDIO_BYTES) return 0;
    for (frame = 0; frame < frames; frame++) {
        DWORD triangle = phase < 32768UL ? phase : 65535UL - phase;
        LONG sample = ((LONG)triangle - 16384L) * 12000L / 16384L;
        WORD channel;
        for (channel = 0; channel < format->nChannels; channel++) {
            if (format->wBitsPerSample == 8) {
                *output++ = (BYTE)(128L + sample / 256L);
            } else {
                WORD encoded = (WORD)(SHORT)sample;
                *output++ = (BYTE)encoded;
                *output++ = (BYTE)(encoded >> 8);
            }
        }
        phase = (phase + step) & 0xFFFFUL;
    }
    return bytes;
}

static int smoke_open_wave(HWAVEOUT *wave, WAVEFORMATEX *format)
{
    smoke_done_count = 0;
    smoke_bad_callback = 0;
    *wave = NULL;
    return waveOutOpen(
        wave,
        smoke_wave_device,
        format,
        (DWORD_PTR)smoke_wave_callback,
        (DWORD_PTR)&smoke_callback_cookie,
        CALLBACK_FUNCTION
    ) == MMSYSERR_NOERROR;
}

static int smoke_test_format(DWORD rate, WORD bits, WORD channels, DWORD frequency)
{
    WAVEFORMATEX format;
    WAVEHDR header;
    HWAVEOUT wave;
    DWORD bytes;
    int passed = 0;
    int prepared = 0;
    smoke_format(&format, rate, bits, channels);
    bytes = smoke_tone(&format, 60UL, frequency);
    if (bytes == 0 || !smoke_open_wave(&wave, &format)) return 0;
    smoke_zero(&header, sizeof(header));
    header.lpData = (LPSTR)smoke_audio;
    header.dwBufferLength = bytes;
    if (waveOutPrepareHeader(wave, &header, sizeof(header)) != MMSYSERR_NOERROR)
        goto done;
    prepared = 1;
    if (waveOutWrite(wave, &header, sizeof(header)) != MMSYSERR_NOERROR)
        goto done;
    if (!smoke_wait_done(&header, 1, GSW_SOUND_WAIT_MS)) goto done;
    passed = 1;
done:
    if (!passed) (void)waveOutReset(wave);
    if (prepared && !smoke_unprepare(wave, &header)) passed = 0;
    if (waveOutClose(wave) != MMSYSERR_NOERROR) passed = 0;
    return passed;
}

static void smoke_report_format(DWORD rate, WORD bits, WORD channels, int passed)
{
    smoke_write("FORMAT ");
    smoke_write_uint(rate);
    smoke_write("/");
    smoke_write_uint(bits);
    smoke_write("/");
    smoke_write_uint(channels);
    smoke_result("", passed);
}

static int smoke_play_loop(
    HWAVEOUT wave,
    WAVEHDR *header,
    DWORD bytes,
    DWORD loops,
    int break_loop
)
{
    int passed = 0;
    smoke_done_count = 0;
    smoke_bad_callback = 0;
    smoke_zero(header, sizeof(*header));
    header->lpData = (LPSTR)smoke_audio;
    header->dwBufferLength = bytes;
    header->dwFlags = WHDR_BEGINLOOP | WHDR_ENDLOOP;
    header->dwLoops = loops;
    if (waveOutPrepareHeader(wave, header, sizeof(*header)) != MMSYSERR_NOERROR)
        return 0;
    if (waveOutWrite(wave, header, sizeof(*header)) != MMSYSERR_NOERROR)
        goto done;
    if (break_loop) {
        Sleep(70);
        if (waveOutBreakLoop(wave) != MMSYSERR_NOERROR) goto done;
    }
    if (!smoke_wait_done(header, 1, GSW_SOUND_WAIT_MS)) goto done;
    passed = 1;
done:
    if (!passed) (void)waveOutReset(wave);
    if (!smoke_unprepare(wave, header)) passed = 0;
    return passed;
}

static int smoke_test_loops(void)
{
    WAVEFORMATEX format;
    WAVEHDR header;
    HWAVEOUT wave;
    DWORD bytes;
    int finite_passed;
    int break_passed;
    int close_passed;
    smoke_format(&format, 44100UL, 16, 2);
    bytes = smoke_tone(&format, 45UL, 523UL);
    if (bytes == 0 || !smoke_open_wave(&wave, &format)) {
        smoke_result("LOOP finite", 0);
        smoke_result("LOOP break", 0);
        return 0;
    }
    finite_passed = smoke_play_loop(wave, &header, bytes, 3, 0);
    smoke_result("LOOP finite", finite_passed);
    break_passed = smoke_play_loop(wave, &header, bytes, 20, 1);
    smoke_result("LOOP break", break_passed);
    close_passed = waveOutClose(wave) == MMSYSERR_NOERROR;
    if (!close_passed) smoke_result("LOOP close", 0);
    return finite_passed && break_passed && close_passed;
}

static int smoke_get_bytes(HWAVEOUT wave, DWORD *bytes)
{
    MMTIME position;
    smoke_zero(&position, sizeof(position));
    position.wType = TIME_BYTES;
    if (waveOutGetPosition(wave, &position, sizeof(position)) != MMSYSERR_NOERROR ||
        position.wType != TIME_BYTES)
        return 0;
    *bytes = position.u.cb;
    return 1;
}

static int smoke_test_transport(void)
{
    WAVEFORMATEX format;
    WAVEHDR header;
    HWAVEOUT wave;
    DWORD bytes;
    DWORD before;
    DWORD after;
    DWORD tolerance;
    int pause_passed = 0;
    int reset_passed = 0;
    int prepared = 0;
    smoke_format(&format, 44100UL, 16, 2);
    bytes = smoke_tone(&format, 250UL, 330UL);
    if (bytes == 0 || !smoke_open_wave(&wave, &format)) {
        smoke_result("TRANSPORT pause-position-restart", 0);
        smoke_result("TRANSPORT reset", 0);
        return 0;
    }
    smoke_zero(&header, sizeof(header));
    header.lpData = (LPSTR)smoke_audio;
    header.dwBufferLength = bytes;
    if (waveOutPrepareHeader(wave, &header, sizeof(header)) != MMSYSERR_NOERROR)
        goto reset_case;
    prepared = 1;
    if (waveOutWrite(wave, &header, sizeof(header)) != MMSYSERR_NOERROR)
        goto reset_case;
    Sleep(20);
    if (waveOutPause(wave) != MMSYSERR_NOERROR || !smoke_get_bytes(wave, &before))
        goto reset_case;
    Sleep(60);
    if (!smoke_get_bytes(wave, &after)) goto reset_case;
    tolerance = (format.nAvgBytesPerSec + 999UL) / 1000UL;
    if (after < before || after - before > tolerance) goto reset_case;
    if (waveOutRestart(wave) != MMSYSERR_NOERROR) goto reset_case;
    if (!smoke_wait_done(&header, 1, GSW_SOUND_WAIT_MS)) goto reset_case;
    if (!smoke_get_bytes(wave, &after) || after < bytes) goto reset_case;
    pause_passed = 1;
reset_case:
    if (!pause_passed) (void)waveOutReset(wave);
    if (prepared) {
        if (!smoke_unprepare(wave, &header)) pause_passed = 0;
        prepared = 0;
    }
    smoke_result("TRANSPORT pause-position-restart", pause_passed);

    smoke_done_count = 0;
    smoke_bad_callback = 0;
    bytes = smoke_tone(&format, 250UL, 262UL);
    smoke_zero(&header, sizeof(header));
    header.lpData = (LPSTR)smoke_audio;
    header.dwBufferLength = bytes;
    if (waveOutPrepareHeader(wave, &header, sizeof(header)) == MMSYSERR_NOERROR) {
        prepared = 1;
        if (waveOutWrite(wave, &header, sizeof(header)) == MMSYSERR_NOERROR) {
            Sleep(20);
            if (waveOutReset(wave) == MMSYSERR_NOERROR &&
                smoke_wait_done(&header, 1, GSW_SOUND_WAIT_MS))
                reset_passed = 1;
        }
    }
    if (!reset_passed) (void)waveOutReset(wave);
    if (prepared && !smoke_unprepare(wave, &header)) reset_passed = 0;
    if (waveOutClose(wave) != MMSYSERR_NOERROR) reset_passed = 0;
    smoke_result("TRANSPORT reset", reset_passed);
    return pause_passed && reset_passed;
}

static int smoke_find_devices(void)
{
    UINT wave_count = waveOutGetNumDevs();
    UINT mixer_count = mixerGetNumDevs();
    UINT index;
    WAVEOUTCAPSA wave_caps;
    MIXERCAPSA mixer_caps;
    smoke_write("ENUM waveOut=");
    smoke_write_uint(wave_count);
    smoke_write(" mixer=");
    smoke_write_uint(mixer_count);
    smoke_write("\r\n");
    for (index = 0; index < wave_count; index++) {
        smoke_zero(&wave_caps, sizeof(wave_caps));
        if (waveOutGetDevCapsA(index, &wave_caps, sizeof(wave_caps)) == MMSYSERR_NOERROR &&
            smoke_name_equals(wave_caps.szPname, GSW_SOUND_WAVE_NAME))
            smoke_wave_device = index;
    }
    for (index = 0; index < mixer_count; index++) {
        smoke_zero(&mixer_caps, sizeof(mixer_caps));
        if (mixerGetDevCapsA(index, &mixer_caps, sizeof(mixer_caps)) == MMSYSERR_NOERROR &&
            smoke_name_equals(mixer_caps.szPname, GSW_SOUND_MIXER_NAME))
            smoke_mixer_device = index;
    }
    smoke_result("ENUM GSW-Sound waveOut", smoke_wave_device != (UINT)GSW_SOUND_INVALID_ID);
    smoke_result("ENUM GSW-Sound mixer", smoke_mixer_device != (UINT)GSW_SOUND_INVALID_ID);
    return smoke_wave_device != (UINT)GSW_SOUND_INVALID_ID &&
        smoke_mixer_device != (UINT)GSW_SOUND_INVALID_ID;
}

static int smoke_mixer_control(
    HMIXER mixer,
    DWORD component_type,
    const char *label
)
{
    MIXERLINEA line;
    MIXERLINECONTROLSA controls;
    MIXERCONTROLA control;
    MIXERCONTROLDETAILS details;
    MIXERCONTROLDETAILS_UNSIGNED value;
    DWORD original;
    DWORD changed;
    int passed = 0;
    smoke_zero(&line, sizeof(line));
    line.cbStruct = sizeof(line);
    line.dwComponentType = component_type;
    if (mixerGetLineInfoA(
            (HMIXEROBJ)mixer,
            &line,
            MIXER_OBJECTF_HMIXER | MIXER_GETLINEINFOF_COMPONENTTYPE
        ) != MMSYSERR_NOERROR)
        goto done;
    smoke_zero(&control, sizeof(control));
    smoke_zero(&controls, sizeof(controls));
    controls.cbStruct = sizeof(controls);
    controls.dwLineID = line.dwLineID;
    controls.dwControlType = MIXERCONTROL_CONTROLTYPE_VOLUME;
    controls.cControls = 1;
    controls.cbmxctrl = sizeof(control);
    controls.pamxctrl = &control;
    if (mixerGetLineControlsA(
            (HMIXEROBJ)mixer,
            &controls,
            MIXER_OBJECTF_HMIXER | MIXER_GETLINECONTROLSF_ONEBYTYPE
        ) != MMSYSERR_NOERROR)
        goto done;
    smoke_zero(&details, sizeof(details));
    smoke_zero(&value, sizeof(value));
    details.cbStruct = sizeof(details);
    details.dwControlID = control.dwControlID;
    details.cChannels = 1;
    details.cMultipleItems = 0;
    details.cbDetails = sizeof(value);
    details.paDetails = &value;
    if (mixerGetControlDetailsA(
            (HMIXEROBJ)mixer,
            &details,
            MIXER_OBJECTF_HMIXER | MIXER_GETCONTROLDETAILSF_VALUE
        ) != MMSYSERR_NOERROR)
        goto done;
    original = value.dwValue;
    changed = original == 0xA000UL ? 0xB000UL : 0xA000UL;
    value.dwValue = changed;
    if (mixerSetControlDetails(
            (HMIXEROBJ)mixer,
            &details,
            MIXER_OBJECTF_HMIXER | MIXER_SETCONTROLDETAILSF_VALUE
        ) != MMSYSERR_NOERROR)
        goto restore;
    value.dwValue = 0;
    if (mixerGetControlDetailsA(
            (HMIXEROBJ)mixer,
            &details,
            MIXER_OBJECTF_HMIXER | MIXER_GETCONTROLDETAILSF_VALUE
        ) != MMSYSERR_NOERROR || value.dwValue != changed)
        goto restore;
    passed = 1;
restore:
    value.dwValue = original;
    if (mixerSetControlDetails(
            (HMIXEROBJ)mixer,
            &details,
            MIXER_OBJECTF_HMIXER | MIXER_SETCONTROLDETAILSF_VALUE
        ) != MMSYSERR_NOERROR)
        passed = 0;
    value.dwValue = 0;
    if (mixerGetControlDetailsA(
            (HMIXEROBJ)mixer,
            &details,
            MIXER_OBJECTF_HMIXER | MIXER_GETCONTROLDETAILSF_VALUE
        ) != MMSYSERR_NOERROR || value.dwValue != original)
        passed = 0;
done:
    smoke_result(label, passed);
    return passed;
}

static int smoke_test_mixer(void)
{
    HMIXER mixer = NULL;
    int master;
    int wave;
    int closed;
    if (mixerOpen(&mixer, smoke_mixer_device, 0, 0, 0) != MMSYSERR_NOERROR) {
        smoke_result("MIXER Master volume", 0);
        smoke_result("MIXER Wave volume", 0);
        return 0;
    }
    master = smoke_mixer_control(
        mixer, MIXERLINE_COMPONENTTYPE_DST_SPEAKERS, "MIXER Master volume"
    );
    wave = smoke_mixer_control(
        mixer, MIXERLINE_COMPONENTTYPE_SRC_WAVEOUT, "MIXER Wave volume"
    );
    closed = mixerClose(mixer) == MMSYSERR_NOERROR;
    if (!closed) smoke_result("MIXER close", 0);
    return master && wave && closed;
}

static DWORD smoke_run(void)
{
    static const DWORD rates[4] = {11025UL, 22050UL, 44100UL, 48000UL};
    DWORD rate_index;
    WORD bits;
    WORD channels;
    DWORD frequency = 220UL;
    smoke_log = CreateFileA(
        GSW_SOUND_LOG_NAME,
        GENERIC_WRITE,
        FILE_SHARE_READ,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    smoke_write("GSWSOUND_SMOKE BEGIN\r\n");
    smoke_report_start_telemetry();
    smoke_audio = (BYTE *)VirtualAlloc(
        NULL, GSW_SOUND_AUDIO_BYTES, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
    );
    if (smoke_audio == NULL) {
        smoke_result("SETUP audio-buffer", 0);
        return 2;
    }
    if (!smoke_find_devices()) goto finish;
    (void)smoke_test_mixer();
    for (rate_index = 0; rate_index < 4; rate_index++) {
        for (bits = 8; bits <= 16; bits = (WORD)(bits + 8)) {
            for (channels = 1; channels <= 2; channels++) {
                int passed = smoke_test_format(
                    rates[rate_index], bits, channels, frequency
                );
                smoke_report_format(rates[rate_index], bits, channels, passed);
                frequency += 23UL;
            }
        }
    }
    (void)smoke_test_loops();
    (void)smoke_test_transport();
finish:
    (void)VirtualFree(smoke_audio, 0, MEM_RELEASE);
    if (smoke_failures == 0) {
        smoke_write("GSWSOUND_SMOKE PASS\r\n");
    } else {
        smoke_write("GSWSOUND_SMOKE FAIL count=");
        smoke_write_uint(smoke_failures);
        smoke_write("\r\n");
    }
    if (smoke_log != INVALID_HANDLE_VALUE) CloseHandle(smoke_log);
    return smoke_failures == 0 ? 0 : (smoke_failures > 254 ? 255 : smoke_failures);
}

void mainCRTStartup(void)
{
    ExitProcess(smoke_run());
}
