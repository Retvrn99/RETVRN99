// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"
import config "../vmconfig"

@(test)
event_scheduler_test_orders_deadlines_and_stable_device_ids :: proc(t: ^testing.T) {
	s: Event_Scheduler
	event_scheduler_init(&s)
	event_scheduler_set(&s, .Ide, 30)
	event_scheduler_set(&s, .Pit, 10)
	event_scheduler_set(&s, .Uart2, 10)

	event, ok := event_scheduler_take_due(&s, 9)
	testing.expect(t, !ok)
	event, ok = event_scheduler_take_due(&s, 10)
	testing.expect(t, ok)
	testing.expect_value(t, event.device, Scheduled_Device.Pit)
	event, ok = event_scheduler_take_due(&s, 10)
	testing.expect(t, ok)
	testing.expect_value(t, event.device, Scheduled_Device.Uart2)
	event, ok = event_scheduler_next(&s)
	testing.expect(t, ok)
	testing.expect_value(t, event.device, Scheduled_Device.Ide)
}

@(test)
event_scheduler_test_replaces_and_removes_deadline :: proc(t: ^testing.T) {
	s: Event_Scheduler
	event_scheduler_set(&s, .Fdc, 100)
	event_scheduler_set(&s, .Bmide, 50)
	event_scheduler_set(&s, .Fdc, 25)
	event, ok := event_scheduler_next(&s)
	testing.expect(t, ok)
	testing.expect_value(t, event.device, Scheduled_Device.Fdc)
	testing.expect_value(t, event.deadline, u64(25))
	event_scheduler_clear(&s, .Fdc)
	event, ok = event_scheduler_next(&s)
	testing.expect(t, ok)
	testing.expect_value(t, event.device, Scheduled_Device.Bmide)
	event_scheduler_clear(&s, .Bmide)
	_, ok = event_scheduler_next(&s)
	testing.expect(t, !ok)
}

@(test)
event_scheduler_test_turbo_has_no_governor_or_silent_audio_deadline :: proc(t: ^testing.T) {
	m: Machine
	m.cpu_mode = config.Cpu_Mode.Turbo
	machine_scheduler_refresh(&m)
	testing.expect_value(t, m.scheduler.positions[int(Scheduled_Device.Governor)], -1)
	testing.expect_value(t, m.scheduler.positions[int(Scheduled_Device.Audio)], -1)
}

@(test)
event_scheduler_test_gsw_governor_deadline_is_not_postponed_by_refresh :: proc(t: ^testing.T) {
	m: Machine
	m.cpu_mode = config.Cpu_Mode.GSW_886
	machine_scheduler_refresh(&m)
	first := m.governor_deadline
	machine_scheduler_refresh(&m)
	testing.expect_value(t, m.governor_deadline, first)
	testing.expect(t, first > 0)
}
