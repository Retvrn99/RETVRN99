// SPDX-License-Identifier: GPL-3.0-only
package machine

Scheduled_Device :: enum u8 {
	Pit,
	Uart1,
	Uart2,
	Lpt1,
	Lpt2,
	Dma,
	Fdc,
	Ide,
	Atapi,
	Bmide,
	I8042,
	Cmos,
	Audio,
	Vga,
	Governor,
	Count,
}

SCHEDULED_DEVICE_COUNT :: int(Scheduled_Device.Count)

Scheduled_Event :: struct {
	device:   Scheduled_Device,
	deadline: u64,
}

Event_Scheduler :: struct {
	heap:              [SCHEDULED_DEVICE_COUNT]Scheduled_Event,
	positions:         [SCHEDULED_DEVICE_COUNT]int,
	count:             int,
	initialized:       bool,
	updates:           u64,
	dispatches:        u64,
	device_dispatches: [SCHEDULED_DEVICE_COUNT]u64,
}

event_scheduler_init :: proc(s: ^Event_Scheduler) {
	s^ = {}
	for &position in s.positions {position = -1}
	s.initialized = true
}

@(private = "file")
event_scheduler_less :: proc(left, right: Scheduled_Event) -> bool {
	if left.deadline != right.deadline {return left.deadline < right.deadline}
	return left.device < right.device
}

@(private = "file")
event_scheduler_swap :: proc(s: ^Event_Scheduler, left, right: int) {
	temporary := s.heap[left]
	s.heap[left] = s.heap[right]
	s.heap[right] = temporary
	s.positions[int(s.heap[left].device)] = left
	s.positions[int(s.heap[right].device)] = right
}

@(private = "file")
event_scheduler_sift_up :: proc(s: ^Event_Scheduler, start: int) {
	index := start
	for index > 0 {
		parent := (index - 1) / 2
		if !event_scheduler_less(s.heap[index], s.heap[parent]) {break}
		event_scheduler_swap(s, index, parent)
		index = parent
	}
}

@(private = "file")
event_scheduler_sift_down :: proc(s: ^Event_Scheduler, start: int) {
	index := start
	for {
		left := index * 2 + 1
		if left >= s.count {break}
		right := left + 1
		child := left
		if right < s.count && event_scheduler_less(s.heap[right], s.heap[left]) {child = right}
		if !event_scheduler_less(s.heap[child], s.heap[index]) {break}
		event_scheduler_swap(s, index, child)
		index = child
	}
}

event_scheduler_set :: proc(s: ^Event_Scheduler, device: Scheduled_Device, deadline: u64) {
	if !s.initialized {event_scheduler_init(s)}
	index := s.positions[int(device)]
	if index < 0 {
		s.updates += 1
		index = s.count
		s.count += 1
		s.heap[index] = {
			device   = device,
			deadline = deadline,
		}
		s.positions[int(device)] = index
		event_scheduler_sift_up(s, index)
		return
	}
	old := s.heap[index].deadline
	if old == deadline {return}
	s.updates += 1
	s.heap[index].deadline = deadline
	if deadline <
	   old {event_scheduler_sift_up(s, index)} else if deadline > old {event_scheduler_sift_down(s, index)}
}

event_scheduler_clear :: proc(s: ^Event_Scheduler, device: Scheduled_Device) {
	if !s.initialized {event_scheduler_init(s); return}
	index := s.positions[int(device)]
	if index < 0 {return}
	s.updates += 1
	s.positions[int(device)] = -1
	s.count -= 1
	if index == s.count {return}
	s.heap[index] = s.heap[s.count]
	replacement := s.heap[index].device
	s.positions[int(replacement)] = index
	event_scheduler_sift_up(s, index)
	index = s.positions[int(replacement)]
	event_scheduler_sift_down(s, index)
}

event_scheduler_next :: proc(s: ^Event_Scheduler) -> (Scheduled_Event, bool) {
	if s == nil || !s.initialized || s.count == 0 {return {}, false}
	return s.heap[0], true
}

event_scheduler_take_due :: proc(s: ^Event_Scheduler, now: u64) -> (Scheduled_Event, bool) {
	event, pending := event_scheduler_next(s)
	if !pending || event.deadline > now {return {}, false}
	event_scheduler_clear(s, event.device)
	s.dispatches += 1
	s.device_dispatches[int(event.device)] += 1
	return event, true
}
