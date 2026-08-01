/* SPDX-License-Identifier: GPL-3.0-only */

#include "gsw_display_arbiter.h"

static GSW_Display_Dispi_Trap gsw_display_trap_for(
    GSW_Display_Arbiter state
)
{
    if (state.lifecycle == GSW_DISPLAY_REGISTERED) {
        return GSW_DISPLAY_DISPI_INTERCEPT;
    }
    return GSW_DISPLAY_DISPI_BYPASS;
}

static int gsw_display_event_has_fresh_owner(GSW_Display_Event event)
{
    return (event.flags & GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH) != 0U;
}

static int gsw_display_request_is_authorized(
    GSW_Display_Arbiter state,
    GSW_Display_VM vm
)
{
    if (state.transition != GSW_DISPLAY_TRANSITION_NONE) {
        return vm != 0UL && vm == state.transition_vm;
    }
    if (state.authority == GSW_DISPLAY_FOREGROUND_VGA) {
        return vm != 0UL && vm == state.authority_vm;
    }
    return 0;
}

static void gsw_display_set_transition(
    GSW_Display_Result *result,
    GSW_Display_Transition transition,
    GSW_Display_VM vm
)
{
    result->next.transition = transition;
    result->next.transition_vm = vm;
}

static void gsw_display_commit_authority(
    GSW_Display_Result *result,
    GSW_Display_Authority authority,
    GSW_Display_VM vm
)
{
    int changed;

    changed = result->next.authority != authority ||
              result->next.authority_vm != vm ||
              result->next.transition != GSW_DISPLAY_TRANSITION_NONE;
    result->next.authority = authority;
    result->next.authority_vm = vm;
    result->next.transition = GSW_DISPLAY_TRANSITION_NONE;
    result->next.transition_vm = 0UL;
    if (changed) {
        result->next.generation++;
    }
}

static void gsw_display_commit_post(
    GSW_Display_Result *result,
    GSW_Display_Event event,
    GSW_Display_Transition expected_transition,
    GSW_Display_Authority target_authority,
    GSW_Display_VM target_vm
)
{
    int exact;
    int fresh;

    fresh = gsw_display_event_has_fresh_owner(event);
    if (fresh && event.observed_physical_owner != target_vm) {
        result->protocol_fault = 1U;
        return;
    }

    if (result->next.transition == GSW_DISPLAY_TRANSITION_NONE &&
        result->next.authority == target_authority &&
        result->next.authority_vm == target_vm) {
        return;
    }

    exact = result->next.transition == expected_transition &&
            result->next.transition_vm == target_vm;
    if (exact || fresh) {
        gsw_display_commit_authority(result, target_authority, target_vm);
        return;
    }

    result->protocol_fault = 1U;
}

static void gsw_display_handle_request(
    GSW_Display_Result *result,
    GSW_Display_Event event
)
{
    int authorized;

    if (result->next.lifecycle == GSW_DISPLAY_COLD ||
        result->next.lifecycle == GSW_DISPLAY_READY ||
        result->next.lifecycle == GSW_DISPLAY_EXITED) {
        return;
    }

    if (result->next.lifecycle == GSW_DISPLAY_DISABLING) {
        if (event.kind == GSW_DISPLAY_EVENT_DISPI_ACCESS) {
            return;
        }
        if (event.kind == GSW_DISPLAY_EVENT_BIOS_MODE_SET &&
            event.vm == result->next.windows_vm &&
            (event.value == 0x0003U || event.value == 0x0083U)) {
            return;
        }
        if (event.kind == GSW_DISPLAY_EVENT_VBE_MODE_SET) {
            result->action = GSW_DISPLAY_REJECT_VBE;
            result->vbe_ax = GSW_DISPLAY_VBE_REJECT_AX;
        } else {
            result->action = GSW_DISPLAY_CONSUME;
        }
        return;
    }

    authorized = gsw_display_request_is_authorized(result->next, event.vm);
    if (authorized) {
        return;
    }

    if (event.kind == GSW_DISPLAY_EVENT_VBE_MODE_SET) {
        result->action = GSW_DISPLAY_REJECT_VBE;
        result->vbe_ax = GSW_DISPLAY_VBE_REJECT_AX;
    } else {
        result->action = GSW_DISPLAY_CONSUME;
    }
}

GSW_Display_Result gsw_display_step(
    GSW_Display_Arbiter state,
    GSW_Display_Event event
)
{
    GSW_Display_Result result;
    GSW_Display_VM target_vm;

    result.next = state;
    result.action = GSW_DISPLAY_FORWARD;
    result.dispi_trap = gsw_display_trap_for(state);
    result.vbe_ax = 0U;
    result.protocol_fault = 0U;

    switch (event.kind) {
    case GSW_DISPLAY_EVENT_DEVICE_READY:
        if (state.lifecycle == GSW_DISPLAY_COLD) {
            result.next.lifecycle = GSW_DISPLAY_READY;
        } else if (state.lifecycle != GSW_DISPLAY_READY) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DEVICE_REGISTERED:
        if (state.lifecycle == GSW_DISPLAY_READY && event.vm != 0UL) {
            result.next.lifecycle = GSW_DISPLAY_REGISTERED;
            result.next.windows_vm = event.vm;
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_DESKTOP_RECONFIGURE,
                event.vm
            );
        } else if (state.lifecycle == GSW_DISPLAY_DISABLING &&
                   event.vm != 0UL && event.vm == state.windows_vm) {
            result.next.lifecycle = GSW_DISPLAY_REGISTERED;
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_DESKTOP_RECONFIGURE,
                state.windows_vm
            );
        } else if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
                   event.vm == 0UL || event.vm != state.windows_vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition == GSW_DISPLAY_TRANSITION_NONE) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_TO_FOREGROUND_VGA,
                event.vm
            );
        } else if (state.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE &&
                   state.transition_vm == event.vm) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_TO_FOREGROUND_VGA,
                event.vm
            );
        } else if (state.transition != GSW_DISPLAY_TO_FOREGROUND_VGA ||
                   state.transition_vm != event.vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else {
            gsw_display_commit_post(
                &result,
                event,
                GSW_DISPLAY_TO_FOREGROUND_VGA,
                GSW_DISPLAY_FOREGROUND_VGA,
                event.vm
            );
        }
        break;

    case GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != state.windows_vm || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition == GSW_DISPLAY_TRANSITION_NONE) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_TO_WINDOWS_DESKTOP,
                state.windows_vm
            );
        } else if (state.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE &&
                   state.transition_vm == state.windows_vm) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_TO_WINDOWS_DESKTOP,
                state.windows_vm
            );
        } else if (state.transition != GSW_DISPLAY_TO_WINDOWS_DESKTOP ||
                   state.transition_vm != state.windows_vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_VDD_POST_DESKTOP:
        target_vm = state.windows_vm;
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != target_vm || target_vm == 0UL) {
            result.protocol_fault = 1U;
        } else {
            gsw_display_commit_post(
                &result,
                event,
                GSW_DISPLAY_TO_WINDOWS_DESKTOP,
                GSW_DISPLAY_WINDOWS_DESKTOP,
                target_vm
            );
        }
        break;

    case GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != state.windows_vm || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE &&
                   state.transition_vm == state.windows_vm) {
            gsw_display_commit_authority(
                &result,
                GSW_DISPLAY_WINDOWS_DESKTOP,
                state.windows_vm
            );
        } else if (state.transition == GSW_DISPLAY_TO_WINDOWS_DESKTOP &&
                   state.transition_vm == state.windows_vm) {
            break;
        } else if (state.transition != GSW_DISPLAY_TRANSITION_NONE ||
                   state.authority != GSW_DISPLAY_WINDOWS_DESKTOP ||
                   state.authority_vm != state.windows_vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != state.windows_vm || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition == GSW_DISPLAY_TRANSITION_NONE) {
            break;
        } else if ((state.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE ||
                    state.transition == GSW_DISPLAY_TO_WINDOWS_DESKTOP) &&
                   state.transition_vm == state.windows_vm) {
            result.next.transition = GSW_DISPLAY_TRANSITION_NONE;
            result.next.transition_vm = 0UL;
        } else {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN:
        if (state.lifecycle == GSW_DISPLAY_DISABLING ||
            state.lifecycle == GSW_DISPLAY_EXITED) {
            break;
        }
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != state.windows_vm || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition != GSW_DISPLAY_TRANSITION_NONE) {
            if (state.transition_vm != state.windows_vm) {
                result.protocol_fault = 1U;
            }
        } else if (state.authority == GSW_DISPLAY_WINDOWS_DESKTOP &&
                   state.authority_vm == state.windows_vm) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_DESKTOP_RECONFIGURE,
                state.windows_vm
            );
        } else if (state.authority == GSW_DISPLAY_FOREGROUND_VGA &&
                   state.authority_vm == state.windows_vm) {
            break;
        } else {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END:
        if (state.lifecycle == GSW_DISPLAY_DISABLING ||
            state.lifecycle == GSW_DISPLAY_EXITED) {
            break;
        }
        if (state.lifecycle != GSW_DISPLAY_REGISTERED ||
            event.vm != state.windows_vm || event.vm == 0UL) {
            result.protocol_fault = 1U;
        } else if (state.transition != GSW_DISPLAY_TRANSITION_NONE) {
            if (state.transition_vm != state.windows_vm) {
                result.protocol_fault = 1U;
            } else if (state.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE) {
                if (state.authority == GSW_DISPLAY_WINDOWS_DESKTOP &&
                    state.authority_vm == state.windows_vm) {
                    result.next.transition = GSW_DISPLAY_TRANSITION_NONE;
                    result.next.transition_vm = 0UL;
                } else if (state.authority != GSW_DISPLAY_FOREGROUND_VGA) {
                    result.protocol_fault = 1U;
                }
            }
        } else if (state.authority == GSW_DISPLAY_FOREGROUND_VGA &&
                   state.authority_vm == state.windows_vm) {
            gsw_display_set_transition(
                &result,
                GSW_DISPLAY_DESKTOP_RECONFIGURE,
                state.windows_vm
            );
        } else if (state.authority != GSW_DISPLAY_WINDOWS_DESKTOP ||
                   state.authority_vm != state.windows_vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DRIVER_DISABLING:
        if (state.lifecycle == GSW_DISPLAY_EXITED) {
            break;
        } else if (state.lifecycle == GSW_DISPLAY_REGISTERED &&
                   event.vm != 0UL && event.vm == state.windows_vm) {
            result.next.lifecycle = GSW_DISPLAY_DISABLING;
            result.next.transition = GSW_DISPLAY_TRANSITION_NONE;
            result.next.transition_vm = 0UL;
        } else if (state.lifecycle != GSW_DISPLAY_DISABLING ||
                   event.vm == 0UL || event.vm != state.windows_vm) {
            result.protocol_fault = 1U;
        }
        break;

    case GSW_DISPLAY_EVENT_DEVICE_EXIT:
    case GSW_DISPLAY_EVENT_SYSTEM_EXIT:
        if (state.lifecycle != GSW_DISPLAY_EXITED) {
            result.next.lifecycle = GSW_DISPLAY_EXITED;
            gsw_display_commit_authority(
                &result,
                GSW_DISPLAY_FIRMWARE,
                0UL
            );
            result.next.windows_vm = 0UL;
        }
        break;

    case GSW_DISPLAY_EVENT_BIOS_MODE_SET:
    case GSW_DISPLAY_EVENT_VBE_MODE_SET:
    case GSW_DISPLAY_EVENT_DISPI_ACCESS:
        gsw_display_handle_request(&result, event);
        break;

    case GSW_DISPLAY_EVENT_PHYSICAL_OWNER:
        if (state.lifecycle != GSW_DISPLAY_REGISTERED) {
            result.protocol_fault = 1U;
        } else if (!gsw_display_event_has_fresh_owner(event)) {
            break;
        } else if (event.vm == 0UL ||
                   event.vm != event.observed_physical_owner) {
            result.protocol_fault = 1U;
        } else if (state.transition != GSW_DISPLAY_TRANSITION_NONE &&
                   event.vm != state.transition_vm) {
            break;
        } else if (event.vm != state.windows_vm) {
            gsw_display_commit_authority(
                &result,
                GSW_DISPLAY_FOREGROUND_VGA,
                event.vm
            );
        }
        break;

    default:
        result.protocol_fault = 1U;
        break;
    }

    result.dispi_trap = gsw_display_trap_for(result.next);
    return result;
}
