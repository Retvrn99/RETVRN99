/* SPDX-License-Identifier: GPL-3.0-only */

#ifndef GSW_DISPLAY_ARBITER_H
#define GSW_DISPLAY_ARBITER_H

#define GSW_DISPLAY_VBE_REJECT_AX 0x034FU
#define GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH 0x0001U

typedef unsigned long GSW_Display_VM;

typedef enum GSW_Display_Lifecycle {
    GSW_DISPLAY_COLD = 0,
    GSW_DISPLAY_READY,
    GSW_DISPLAY_REGISTERED,
    GSW_DISPLAY_DISABLING,
    GSW_DISPLAY_EXITED
} GSW_Display_Lifecycle;

typedef enum GSW_Display_Authority {
    GSW_DISPLAY_FIRMWARE = 0,
    GSW_DISPLAY_WINDOWS_DESKTOP,
    GSW_DISPLAY_FOREGROUND_VGA
} GSW_Display_Authority;

typedef enum GSW_Display_Transition {
    GSW_DISPLAY_TRANSITION_NONE = 0,
    GSW_DISPLAY_TO_FOREGROUND_VGA,
    GSW_DISPLAY_TO_WINDOWS_DESKTOP,
    GSW_DISPLAY_DESKTOP_RECONFIGURE
} GSW_Display_Transition;

typedef enum GSW_Display_Event_Kind {
    GSW_DISPLAY_EVENT_DEVICE_READY = 0,
    GSW_DISPLAY_EVENT_DEVICE_REGISTERED,
    GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND,
    GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND,
    GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP,
    GSW_DISPLAY_EVENT_VDD_POST_DESKTOP,
    GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED,
    GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED,
    GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN,
    GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END,
    GSW_DISPLAY_EVENT_DRIVER_DISABLING,
    GSW_DISPLAY_EVENT_DEVICE_EXIT,
    GSW_DISPLAY_EVENT_SYSTEM_EXIT,
    GSW_DISPLAY_EVENT_BIOS_MODE_SET,
    GSW_DISPLAY_EVENT_VBE_MODE_SET,
    GSW_DISPLAY_EVENT_DISPI_ACCESS,
    GSW_DISPLAY_EVENT_PHYSICAL_OWNER
} GSW_Display_Event_Kind;

typedef enum GSW_Display_Action {
    GSW_DISPLAY_FORWARD = 0,
    GSW_DISPLAY_CONSUME,
    GSW_DISPLAY_REJECT_VBE
} GSW_Display_Action;

typedef enum GSW_Display_Dispi_Trap {
    GSW_DISPLAY_DISPI_BYPASS = 0,
    GSW_DISPLAY_DISPI_INTERCEPT
} GSW_Display_Dispi_Trap;

typedef struct GSW_Display_Arbiter {
    GSW_Display_Lifecycle lifecycle;
    GSW_Display_Authority authority;
    GSW_Display_Transition transition;
    GSW_Display_VM windows_vm;
    GSW_Display_VM authority_vm;
    GSW_Display_VM transition_vm;
    unsigned long generation;
} GSW_Display_Arbiter;

typedef struct GSW_Display_Event {
    GSW_Display_Event_Kind kind;
    GSW_Display_VM vm;
    GSW_Display_VM observed_physical_owner;
    unsigned short value;
    unsigned short flags;
} GSW_Display_Event;

typedef struct GSW_Display_Result {
    GSW_Display_Arbiter next;
    GSW_Display_Action action;
    GSW_Display_Dispi_Trap dispi_trap;
    unsigned short vbe_ax;
    unsigned char protocol_fault;
} GSW_Display_Result;

GSW_Display_Result gsw_display_step(
    GSW_Display_Arbiter state,
    GSW_Display_Event event
);

#endif
