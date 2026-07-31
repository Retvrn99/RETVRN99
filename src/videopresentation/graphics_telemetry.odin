// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import host "../host"
import hv "../hv"
import vga "../vga"

GRAPHICS_TELEMETRY_WINDOW :: time.Second
GRAPHICS_TELEMETRY_AGGREGATE_LOG_CAPACITY :: 3600
GRAPHICS_FRAME_TRACE_CAPACITY :: 256
GRAPHICS_FRAME_TRACE_LINE_BYTES :: 2048
GRAPHICS_INPUT_CORRELATION_CAPACITY :: 4096

Graphics_Frame_Result :: enum u8 {
	Incomplete,
	Presented,
	Superseded,
	Coalesced,
	Capture_Failed,
	Render_Failed,
	Upload_Failed,
	Compose_Failed,
	Present_Failed,
	Gpu_Work,
	Reset,
}

Graphics_Frame_Source :: enum u8 {
	Legacy_Scanout,
	Gsw2d,
	Gsw3d,
}

Graphics_Frame_Epoch :: struct {
	sequence:               u64,
	lifecycle_generation:   u64,
	scanout_generation:     u64,
	source:                 Graphics_Frame_Source,
	result:                 Graphics_Frame_Result,
	kind:                   vga.Display_Kind,
	width:                  int,
	height:                 int,
	bytes_copied:           u64,
	descriptor_copy_ns:     u64,
	bytes_uploaded:         u64,
	rendered_pixels:        u64,
	texture_recreated:      bool,
	issued_at:              time.Tick,
	capture_started:        time.Tick,
	capture_ended:          time.Tick,
	first_render_started:   time.Tick,
	render_started:         time.Tick,
	render_ended:           time.Tick,
	render_work_ns:         u64,
	render_work_samples:    u64,
	upload_started:         time.Tick,
	upload_ended:           time.Tick,
	upload_work_ns:         u64,
	upload_work_samples:    u64,
	gpu_drain_started:      time.Tick,
	gpu_drain_ended:        time.Tick,
	gpu_requests:           u64,
	gpu_failures:           u64,
	gpu_budget:             u64,
	input_events:           u64,
	input_residence_ns:     u64,
	max_input_residence_ns: u64,
	input_oldest_queued_at: time.Tick,
	input_to_present_ns:    u64,
	producer:               Graphics_Producer_Interval,
	host_gpu:               Graphics_Host_Gpu_Interval,
	compose_started:        time.Tick,
	compose_ended:          time.Tick,
	present_started:        time.Tick,
	completed:              time.Tick,
}

Graphics_Telemetry_Window :: struct {
	sequence:                       u64,
	started:                        time.Tick,
	ended:                          time.Tick,
	publish_attempts:               u64,
	unchanged_attempts:             u64,
	blocked_attempts:               u64,
	epochs:                         u64,
	presented:                      u64,
	superseded:                     u64,
	coalesced:                      u64,
	capture_failures:               u64,
	render_failures:                u64,
	upload_failures:                u64,
	compose_failures:               u64,
	present_failures:               u64,
	gpu_work_epochs:                u64,
	reset_frames:                   u64,
	bytes_copied:                   u64,
	descriptor_copy_ns:             u64,
	descriptor_copy_samples:        u64,
	bytes_uploaded:                 u64,
	rendered_pixels:                u64,
	texture_recreates:              u64,
	gpu_requests:                   u64,
	gpu_failures:                   u64,
	gpu_budget:                     u64,
	input_events:                   u64,
	input_residence_ns:             u64,
	max_input_residence_ns:         u64,
	input_to_present_ns:            u64,
	max_input_to_present_ns:        u64,
	input_to_present_samples:       u64,
	producer:                       Graphics_Producer_Interval,
	host_gpu:                       Graphics_Host_Gpu_Interval,
	capture_ns:                     u64,
	queue_ns:                       u64,
	render_ns:                      u64,
	upload_ns:                      u64,
	gpu_drain_ns:                   u64,
	compose_ns:                     u64,
	present_ns:                     u64,
	end_to_end_ns:                  u64,
	max_end_to_end_ns:              u64,
	capture_samples:                u64,
	queue_samples:                  u64,
	render_samples:                 u64,
	upload_samples:                 u64,
	gpu_drain_samples:              u64,
	compose_samples:                u64,
	present_samples:                u64,
	end_to_end_samples:             u64,
	first_epoch:                    u64,
	latest_epoch:                   u64,
	latest_generation:              u64,
	latest_source:                  Graphics_Frame_Source,
	latest_guest_device_generation: u64,
	latest_host_device_generation:  u64,
	latest_kind:                    vga.Display_Kind,
	latest_width:                   int,
	latest_height:                  int,
}

Graphics_Telemetry :: struct {
	trace_enabled:        bool,
	window_active:        bool,
	current:              Graphics_Telemetry_Window,
	latest:               Graphics_Telemetry_Window,
	latest_sequence:      u64,
	reported_sequence:    u64,
	trace:                ^[GRAPHICS_FRAME_TRACE_CAPACITY]Graphics_Frame_Epoch,
	trace_count:          u64,
	trace_cursor:         int,
	pending_input_events: u64,
	pending_input_ns:     u64,
	pending_input_max_ns: u64,
	pending_input_oldest: time.Tick,
	input_correlation_events:   u64,
	input_correlation_samples:  u64,
	input_correlation_total_ns: u64,
	input_correlation_max_ns:   u64,
	input_correlation_latencies: ^[GRAPHICS_INPUT_CORRELATION_CAPACITY]u64,
	input_correlation_retained:  u64,
	input_correlation_dropped:   u64,
	producer_sampled:     bool,
	last_producer:        Graphics_Producer_Sample,
	pending_producer:     Graphics_Producer_Interval,
	host_gpu_sampled:     bool,
	last_host_gpu:        host.Host_Gsw3d_Observability_Snapshot,
	pending_host_gpu:     Graphics_Host_Gpu_Interval,
}

Graphics_Input_Correlation :: struct {
	events:               u64,
	samples:              u64,
	total_ns:             u64,
	max_ns:               u64,
	p50_ns:               u64,
	p95_ns:               u64,
	p99_ns:               u64,
	retained_samples:     u64,
	retention_capacity:   u64,
	retention_dropped:    u64,
	retention_enabled:    bool,
	retention_overflowed: bool,
	percentiles_valid:    bool,
}

Graphics_Telemetry_Snapshot :: struct {
	current:        Graphics_Telemetry_Window,
	latest:         Graphics_Telemetry_Window,
	trace_observed: u64,
	trace_retained: u64,
	trace_enabled:  bool,
}

@(private = "package")
graphics_telemetry_aggregate_log_admit :: proc(emitted: ^u64) -> bool {
	if emitted == nil || emitted^ >= GRAPHICS_TELEMETRY_AGGREGATE_LOG_CAPACITY {return false}
	emitted^ += 1
	return true
}

@(private = "package")
graphics_telemetry_init :: proc(telemetry: ^Graphics_Telemetry, trace_enabled: bool) {
	if telemetry == nil {return}
	if telemetry.trace != nil {free(telemetry.trace)}
	if telemetry.input_correlation_latencies != nil {free(telemetry.input_correlation_latencies)}
	telemetry^ = {}
	if trace_enabled {
		telemetry.trace = new([GRAPHICS_FRAME_TRACE_CAPACITY]Graphics_Frame_Epoch)
		telemetry.input_correlation_latencies = new([GRAPHICS_INPUT_CORRELATION_CAPACITY]u64)
		telemetry.trace_enabled = true
	}
}

@(private = "package")
graphics_telemetry_destroy :: proc(telemetry: ^Graphics_Telemetry) {
	if telemetry == nil {return}
	if telemetry.trace != nil {free(telemetry.trace)}
	if telemetry.input_correlation_latencies != nil {free(telemetry.input_correlation_latencies)}
	telemetry^ = {}
}

@(private = "package")
graphics_telemetry_reset_attribution :: proc(telemetry: ^Graphics_Telemetry) {
	if telemetry == nil {return}
	telemetry.pending_input_events = 0
	telemetry.pending_input_ns = 0
	telemetry.pending_input_max_ns = 0
	telemetry.pending_input_oldest = {}
	telemetry.producer_sampled = false
	telemetry.last_producer = {}
	telemetry.pending_producer = {}
	telemetry.pending_host_gpu = {}
}

@(private = "file")
graphics_telemetry_window_touch :: proc(telemetry: ^Graphics_Telemetry, now: time.Tick) {
	if telemetry == nil {return}
	if !telemetry.window_active {
		telemetry.window_active = true
		telemetry.current.started = now
		return
	}
	if time.tick_diff(telemetry.current.started, now) < GRAPHICS_TELEMETRY_WINDOW {return}
	telemetry.latest_sequence += 1
	if telemetry.latest_sequence == 0 {telemetry.latest_sequence = 1}
	telemetry.current.sequence = telemetry.latest_sequence
	telemetry.current.ended = now
	telemetry.latest = telemetry.current
	telemetry.current = {
		started = now,
	}
}

@(private = "package")
graphics_telemetry_note_publish_attempt :: proc(telemetry: ^Graphics_Telemetry, now: time.Tick) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, now)
	telemetry.current.publish_attempts = graphics_counter_add(
		telemetry.current.publish_attempts,
		1,
	)
}

@(private = "package")
graphics_telemetry_note_unchanged :: proc(telemetry: ^Graphics_Telemetry, now: time.Tick) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, now)
	telemetry.current.unchanged_attempts = graphics_counter_add(
		telemetry.current.unchanged_attempts,
		1,
	)
}

@(private = "package")
graphics_telemetry_note_blocked :: proc(telemetry: ^Graphics_Telemetry, now: time.Tick) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, now)
	telemetry.current.blocked_attempts = graphics_counter_add(
		telemetry.current.blocked_attempts,
		1,
	)
}

@(private = "package")
graphics_telemetry_note_input :: proc(
	telemetry: ^Graphics_Telemetry,
	events, residence_ns, max_residence_ns: u64,
	now: time.Tick,
	oldest_queued_at: time.Tick = {},
) {
	if telemetry == nil || events == 0 {return}
	graphics_telemetry_window_touch(telemetry, now)
	telemetry.current.input_events = graphics_counter_add(telemetry.current.input_events, events)
	telemetry.current.input_residence_ns = graphics_counter_add(
		telemetry.current.input_residence_ns,
		residence_ns,
	)
	telemetry.current.max_input_residence_ns = max(
		telemetry.current.max_input_residence_ns,
		max_residence_ns,
	)
	telemetry.pending_input_events = graphics_counter_add(telemetry.pending_input_events, events)
	telemetry.pending_input_ns = graphics_counter_add(telemetry.pending_input_ns, residence_ns)
	telemetry.pending_input_max_ns = max(telemetry.pending_input_max_ns, max_residence_ns)
	if oldest_queued_at != (time.Tick{}) &&
	   (telemetry.pending_input_oldest == (time.Tick{}) ||
			   time.tick_diff(oldest_queued_at, telemetry.pending_input_oldest) > 0) {
		telemetry.pending_input_oldest = oldest_queued_at
	}
}

@(private = "package")
graphics_telemetry_note_producer :: proc(
	telemetry: ^Graphics_Telemetry,
	sample: Graphics_Producer_Sample,
	now: time.Tick,
) {
	if telemetry == nil || !sample.valid {return}
	graphics_telemetry_window_touch(telemetry, now)
	previous := Graphics_Producer_Sample{}
	if telemetry.producer_sampled {previous = telemetry.last_producer}
	interval := graphics_producer_interval(sample, previous)
	telemetry.producer_sampled = true
	telemetry.last_producer = sample
	graphics_producer_interval_add(&telemetry.current.producer, interval)
	graphics_producer_interval_add(&telemetry.pending_producer, interval)
}

@(private = "package")
graphics_telemetry_note_host_gpu :: proc(
	telemetry: ^Graphics_Telemetry,
	sample: host.Host_Gsw3d_Observability_Snapshot,
	now: time.Tick,
) -> Graphics_Host_Gpu_Interval {
	if telemetry == nil {return {}}
	graphics_telemetry_window_touch(telemetry, now)
	interval := graphics_host_gpu_interval(
		sample,
		telemetry.last_host_gpu,
		telemetry.host_gpu_sampled,
	)
	telemetry.host_gpu_sampled = true
	telemetry.last_host_gpu = sample
	graphics_host_gpu_interval_add(&telemetry.current.host_gpu, interval)
	graphics_host_gpu_interval_add(&telemetry.pending_host_gpu, interval)
	return interval
}

@(private = "package")
graphics_telemetry_note_gpu_drain :: proc(
	telemetry: ^Graphics_Telemetry,
	started, ended: time.Tick,
	executed, failed: int,
	budget: u64,
) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, ended)
	if executed > 0 {
		telemetry.current.gpu_requests = graphics_counter_add(
			telemetry.current.gpu_requests,
			u64(executed),
		)
	}
	if failed > 0 {
		telemetry.current.gpu_failures = graphics_counter_add(
			telemetry.current.gpu_failures,
			u64(failed),
		)
	}
	telemetry.current.gpu_budget = graphics_counter_add(telemetry.current.gpu_budget, budget)
	graphics_telemetry_add_span(
		&telemetry.current.gpu_drain_ns,
		&telemetry.current.gpu_drain_samples,
		started,
		ended,
	)
}

@(private = "package")
graphics_telemetry_attach_pending_host_gpu :: proc(
	telemetry: ^Graphics_Telemetry,
	epoch: ^Graphics_Frame_Epoch,
) {
	if telemetry == nil || epoch == nil {return}
	graphics_host_gpu_interval_add(&epoch.host_gpu, telemetry.pending_host_gpu)
	telemetry.pending_host_gpu = {}
}

@(private = "package")
graphics_frame_epoch_begin :: proc(
	sequence: u64,
	scanout_generation: u64,
	now: time.Tick,
) -> Graphics_Frame_Epoch {
	return {
		sequence = sequence,
		scanout_generation = scanout_generation,
		source = .Legacy_Scanout,
		issued_at = now,
	}
}

@(private = "package")
graphics_telemetry_begin_epoch :: proc(
	telemetry: ^Graphics_Telemetry,
	sequence: u64,
	scanout_generation: u64,
	now: time.Tick,
) -> Graphics_Frame_Epoch {
	epoch := graphics_frame_epoch_begin(sequence, scanout_generation, now)
	if telemetry == nil {return epoch}
	epoch.input_events = telemetry.pending_input_events
	epoch.input_residence_ns = telemetry.pending_input_ns
	epoch.max_input_residence_ns = telemetry.pending_input_max_ns
	epoch.input_oldest_queued_at = telemetry.pending_input_oldest
	epoch.producer = telemetry.pending_producer
	graphics_telemetry_attach_pending_host_gpu(telemetry, &epoch)
	telemetry.pending_input_events = 0
	telemetry.pending_input_ns = 0
	telemetry.pending_input_max_ns = 0
	telemetry.pending_input_oldest = {}
	telemetry.pending_producer = {}
	return epoch
}

@(private = "package")
graphics_frame_epoch_transfer_correlation :: proc(destination, source: ^Graphics_Frame_Epoch) {
	if destination == nil || source == nil {return}
	graphics_frame_epoch_transfer_input_producer_correlation(destination, source)
	host_gpu := source.host_gpu
	graphics_host_gpu_interval_add(&host_gpu, destination.host_gpu)
	destination.host_gpu = host_gpu
	source.host_gpu = {}
}

@(private = "package")
graphics_frame_epoch_transfer_input_producer_correlation :: proc(
	destination, source: ^Graphics_Frame_Epoch,
) {
	if destination == nil || source == nil {return}
	destination.input_events = graphics_counter_add(destination.input_events, source.input_events)
	destination.input_residence_ns = graphics_counter_add(
		destination.input_residence_ns,
		source.input_residence_ns,
	)
	destination.max_input_residence_ns = max(
		destination.max_input_residence_ns,
		source.max_input_residence_ns,
	)
	if source.input_oldest_queued_at != (time.Tick{}) &&
	   (destination.input_oldest_queued_at == (time.Tick{}) ||
			   time.tick_diff(source.input_oldest_queued_at, destination.input_oldest_queued_at) >
				   0) {
		destination.input_oldest_queued_at = source.input_oldest_queued_at
	}
	producer := source.producer
	graphics_producer_interval_add(&producer, destination.producer)
	destination.producer = producer
	source.input_events = 0
	source.input_residence_ns = 0
	source.max_input_residence_ns = 0
	source.input_oldest_queued_at = {}
	source.producer = {}
}

@(private = "package")
graphics_frame_epoch_capture_begin :: proc(epoch: ^Graphics_Frame_Epoch, now: time.Tick) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.capture_started = now
}

@(private = "package")
graphics_frame_epoch_capture_complete :: proc(
	epoch: ^Graphics_Frame_Epoch,
	bytes_copied: int,
	now: time.Tick,
) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.capture_ended = now
	if bytes_copied > 0 {epoch.bytes_copied = u64(bytes_copied)}
}

@(private = "package")
graphics_frame_epoch_descriptor_copy :: proc(epoch: ^Graphics_Frame_Epoch, duration_ns: u64) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.descriptor_copy_ns = duration_ns
}

@(private = "package")
graphics_frame_epoch_render_begin :: proc(
	epoch: ^Graphics_Frame_Epoch,
	source: Graphics_Frame_Source,
	now: time.Tick,
) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.source = source
	epoch.kind = .Invalid
	epoch.width = 0
	epoch.height = 0
	if epoch.first_render_started == (time.Tick{}) {epoch.first_render_started = now}
	epoch.render_started = now
	epoch.render_ended = {}
	epoch.upload_started = {}
	epoch.upload_ended = {}
}

@(private = "file")
graphics_frame_pixel_count :: proc(width, height: int) -> u64 {
	if width <= 0 || height <= 0 {return 0}
	w := u64(width)
	h := u64(height)
	if w > max(u64) / h {return max(u64)}
	return w * h
}

@(private = "package")
graphics_frame_epoch_render_complete :: proc(
	epoch: ^Graphics_Frame_Epoch,
	frame: ^vga.Display_Frame,
	now: time.Tick,
) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.render_ended = now
	graphics_telemetry_add_span(
		&epoch.render_work_ns,
		&epoch.render_work_samples,
		epoch.render_started,
		now,
	)
	if frame == nil {return}
	epoch.kind = frame.kind
	epoch.width = frame.width
	epoch.height = frame.height
	pixels := frame.updated_pixels
	epoch.rendered_pixels = graphics_counter_add(epoch.rendered_pixels, pixels)
}

@(private = "package")
graphics_frame_epoch_upload_begin :: proc(epoch: ^Graphics_Frame_Epoch, now: time.Tick) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.upload_started = now
}

@(private = "package")
graphics_frame_epoch_upload_complete :: proc(
	epoch: ^Graphics_Frame_Epoch,
	bytes_uploaded: u64,
	texture_recreated: bool,
	now: time.Tick,
) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.upload_ended = now
	graphics_telemetry_add_span(
		&epoch.upload_work_ns,
		&epoch.upload_work_samples,
		epoch.upload_started,
		now,
	)
	epoch.texture_recreated = epoch.texture_recreated || texture_recreated
	epoch.bytes_uploaded = graphics_counter_add(epoch.bytes_uploaded, bytes_uploaded)
}

@(private = "package")
graphics_frame_epoch_gpu_drain :: proc(
	epoch: ^Graphics_Frame_Epoch,
	started, ended: time.Tick,
	executed, failed: int,
	budget: u64,
) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.gpu_drain_started = started
	epoch.gpu_drain_ended = ended
	if executed > 0 {epoch.gpu_requests = u64(executed)}
	if failed > 0 {epoch.gpu_failures = u64(failed)}
	epoch.gpu_budget = budget
}

@(private = "package")
graphics_frame_epoch_compose :: proc(epoch: ^Graphics_Frame_Epoch, started, ended: time.Tick) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.compose_started = started
	epoch.compose_ended = ended
}

@(private = "package")
graphics_frame_epoch_present_begin :: proc(epoch: ^Graphics_Frame_Epoch, now: time.Tick) {
	if epoch == nil || epoch.result != .Incomplete {return}
	epoch.present_started = now
}

@(private = "package")
graphics_frame_epoch_complete :: proc(
	epoch: ^Graphics_Frame_Epoch,
	result: Graphics_Frame_Result,
	now: time.Tick,
) {
	if epoch == nil || epoch.result != .Incomplete || result == .Incomplete {return}
	epoch.result = result
	epoch.completed = now
	if result == .Presented &&
	   epoch.input_events > 0 &&
	   epoch.input_oldest_queued_at != (time.Tick{}) {
		epoch.input_to_present_ns = u64(
			max(time.Duration(0), time.tick_diff(epoch.input_oldest_queued_at, now)),
		)
	}
}

@(private = "file")
graphics_frame_span_ns :: proc(started, ended: time.Tick) -> u64 {
	if started == (time.Tick{}) || ended == (time.Tick{}) {return 0}
	return u64(max(time.Duration(0), time.tick_diff(started, ended)))
}

@(private = "file")
graphics_telemetry_add_span :: proc(total, samples: ^u64, started, ended: time.Tick) -> u64 {
	if started == (time.Tick{}) || ended == (time.Tick{}) {return 0}
	span := graphics_frame_span_ns(started, ended)
	total^ = graphics_counter_add(total^, span)
	samples^ = graphics_counter_add(samples^, 1)
	return span
}

@(private = "package")
graphics_telemetry_note_compose :: proc(
	telemetry: ^Graphics_Telemetry,
	started, ended: time.Tick,
) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, ended)
	graphics_telemetry_add_span(
		&telemetry.current.compose_ns,
		&telemetry.current.compose_samples,
		started,
		ended,
	)
}

@(private = "package")
graphics_telemetry_note_present :: proc(
	telemetry: ^Graphics_Telemetry,
	started, ended: time.Tick,
) {
	if telemetry == nil {return}
	graphics_telemetry_window_touch(telemetry, ended)
	graphics_telemetry_add_span(
		&telemetry.current.present_ns,
		&telemetry.current.present_samples,
		started,
		ended,
	)
}

@(private = "package")
graphics_telemetry_record :: proc(telemetry: ^Graphics_Telemetry, epoch: Graphics_Frame_Epoch) {
	if telemetry == nil || epoch.sequence == 0 || epoch.result == .Incomplete {return}
	graphics_telemetry_window_touch(telemetry, epoch.completed)
	w := &telemetry.current
	if w.first_epoch == 0 {w.first_epoch = epoch.sequence}
	w.epochs = graphics_counter_add(w.epochs, 1)
	#partial switch epoch.result {
	case .Presented:
		w.presented = graphics_counter_add(w.presented, 1)
	case .Superseded:
		w.superseded = graphics_counter_add(w.superseded, 1)
	case .Coalesced:
		w.coalesced = graphics_counter_add(w.coalesced, 1)
	case .Capture_Failed:
		w.capture_failures = graphics_counter_add(w.capture_failures, 1)
	case .Render_Failed:
		w.render_failures = graphics_counter_add(w.render_failures, 1)
	case .Upload_Failed:
		w.upload_failures = graphics_counter_add(w.upload_failures, 1)
	case .Compose_Failed:
		w.compose_failures = graphics_counter_add(w.compose_failures, 1)
	case .Present_Failed:
		w.present_failures = graphics_counter_add(w.present_failures, 1)
	case .Gpu_Work:
		w.gpu_work_epochs = graphics_counter_add(w.gpu_work_epochs, 1)
	case .Reset:
		w.reset_frames = graphics_counter_add(w.reset_frames, 1)
	}
	w.bytes_copied = graphics_counter_add(w.bytes_copied, epoch.bytes_copied)
	if epoch.descriptor_copy_ns > 0 {
		w.descriptor_copy_ns = graphics_counter_add(w.descriptor_copy_ns, epoch.descriptor_copy_ns)
		w.descriptor_copy_samples = graphics_counter_add(w.descriptor_copy_samples, 1)
	}
	w.bytes_uploaded = graphics_counter_add(w.bytes_uploaded, epoch.bytes_uploaded)
	w.rendered_pixels = graphics_counter_add(w.rendered_pixels, epoch.rendered_pixels)
	if epoch.texture_recreated {
		w.texture_recreates = graphics_counter_add(w.texture_recreates, 1)
	}
	if epoch.input_to_present_ns > 0 {
		w.input_to_present_ns = graphics_counter_add(
			w.input_to_present_ns,
			epoch.input_to_present_ns,
		)
		w.max_input_to_present_ns = max(w.max_input_to_present_ns, epoch.input_to_present_ns)
		w.input_to_present_samples = graphics_counter_add(w.input_to_present_samples, 1)
		telemetry.input_correlation_events = graphics_counter_add(
			telemetry.input_correlation_events,
			epoch.input_events,
		)
		telemetry.input_correlation_samples = graphics_counter_add(
			telemetry.input_correlation_samples,
			1,
		)
		telemetry.input_correlation_total_ns = graphics_counter_add(
			telemetry.input_correlation_total_ns,
			epoch.input_to_present_ns,
		)
		telemetry.input_correlation_max_ns = max(
			telemetry.input_correlation_max_ns,
			epoch.input_to_present_ns,
		)
		if telemetry.trace_enabled {
			if telemetry.input_correlation_latencies != nil &&
			   telemetry.input_correlation_retained < GRAPHICS_INPUT_CORRELATION_CAPACITY {
				telemetry.input_correlation_latencies[telemetry.input_correlation_retained] =
					epoch.input_to_present_ns
				telemetry.input_correlation_retained = graphics_counter_add(
					telemetry.input_correlation_retained,
					1,
				)
			} else {
				telemetry.input_correlation_dropped = graphics_counter_add(
					telemetry.input_correlation_dropped,
					1,
				)
			}
		}
	}
	graphics_telemetry_add_span(
		&w.capture_ns,
		&w.capture_samples,
		epoch.capture_started,
		epoch.capture_ended,
	)
	graphics_telemetry_add_span(
		&w.queue_ns,
		&w.queue_samples,
		epoch.capture_ended,
		epoch.first_render_started,
	)
	w.render_ns = graphics_counter_add(w.render_ns, epoch.render_work_ns)
	w.render_samples = graphics_counter_add(w.render_samples, epoch.render_work_samples)
	w.upload_ns = graphics_counter_add(w.upload_ns, epoch.upload_work_ns)
	w.upload_samples = graphics_counter_add(w.upload_samples, epoch.upload_work_samples)
	end_to_end := graphics_telemetry_add_span(
		&w.end_to_end_ns,
		&w.end_to_end_samples,
		epoch.issued_at,
		epoch.completed,
	)
	if w.end_to_end_samples > 0 {
		w.max_end_to_end_ns = max(w.max_end_to_end_ns, end_to_end)
	}
	w.latest_epoch = epoch.sequence
	w.latest_generation = epoch.scanout_generation
	w.latest_source = epoch.source
	w.latest_guest_device_generation = epoch.producer.device_generation
	w.latest_host_device_generation = epoch.host_gpu.device_generation
	w.latest_kind = epoch.kind
	w.latest_width = epoch.width
	w.latest_height = epoch.height
	if telemetry.trace_enabled {
		telemetry.trace[telemetry.trace_cursor] = epoch
		telemetry.trace_cursor = (telemetry.trace_cursor + 1) % GRAPHICS_FRAME_TRACE_CAPACITY
		telemetry.trace_count = graphics_counter_add(telemetry.trace_count, 1)
	}
}

@(private = "file")
graphics_input_correlation_percentile :: proc(sorted: []u64, percentile: u64) -> u64 {
	if len(sorted) == 0 || percentile == 0 || percentile > 100 {return 0}
	rank := (u64(len(sorted)) * percentile + 99) / 100
	return sorted[int(rank - 1)]
}

@(private = "package")
graphics_telemetry_input_correlation :: proc(
	telemetry: ^Graphics_Telemetry,
) -> Graphics_Input_Correlation {
	if telemetry == nil {return {retention_capacity = GRAPHICS_INPUT_CORRELATION_CAPACITY}}
	result := Graphics_Input_Correlation {
		events = telemetry.input_correlation_events,
		samples = telemetry.input_correlation_samples,
		total_ns = telemetry.input_correlation_total_ns,
		max_ns = telemetry.input_correlation_max_ns,
		retained_samples = telemetry.input_correlation_retained,
		retention_capacity = GRAPHICS_INPUT_CORRELATION_CAPACITY,
		retention_dropped = telemetry.input_correlation_dropped,
		retention_enabled = telemetry.trace_enabled &&
			telemetry.input_correlation_latencies != nil,
	}
	result.retention_overflowed = result.retention_dropped != 0
	result.percentiles_valid =
		result.retention_enabled &&
		!result.retention_overflowed &&
		result.samples > 0 &&
		result.retained_samples == result.samples
	if !result.percentiles_valid {return result}

	values: [GRAPHICS_INPUT_CORRELATION_CAPACITY]u64
	count := int(result.retained_samples)
	copy(values[:count], telemetry.input_correlation_latencies[:count])
	slice.sort(values[:count])
	result.p50_ns = graphics_input_correlation_percentile(values[:count], 50)
	result.p95_ns = graphics_input_correlation_percentile(values[:count], 95)
	result.p99_ns = graphics_input_correlation_percentile(values[:count], 99)
	return result
}

@(private = "package")
graphics_telemetry_take_window :: proc(
	telemetry: ^Graphics_Telemetry,
	now: time.Tick,
) -> (
	Graphics_Telemetry_Window,
	bool,
) {
	if telemetry == nil {return {}, false}
	graphics_telemetry_window_touch(telemetry, now)
	if telemetry.latest.sequence == 0 || telemetry.latest.sequence == telemetry.reported_sequence {
		return {}, false
	}
	telemetry.reported_sequence = telemetry.latest.sequence
	return telemetry.latest, true
}

@(private = "package")
graphics_telemetry_trace_epoch :: proc(
	telemetry: ^Graphics_Telemetry,
	index: u64,
) -> (
	Graphics_Frame_Epoch,
	bool,
) {
	if telemetry == nil || !telemetry.trace_enabled || telemetry.trace == nil {return {}, false}
	count := min(telemetry.trace_count, u64(GRAPHICS_FRAME_TRACE_CAPACITY))
	if index >= count {return {}, false}
	start := telemetry.trace_cursor - int(count)
	if start < 0 {start += GRAPHICS_FRAME_TRACE_CAPACITY}
	return telemetry.trace[(start + int(index)) % GRAPHICS_FRAME_TRACE_CAPACITY], true
}

@(private = "package")
graphics_telemetry_snapshot :: proc(
	telemetry: ^Graphics_Telemetry,
	now: time.Tick,
) -> Graphics_Telemetry_Snapshot {
	if telemetry == nil {return {}}
	graphics_telemetry_window_touch(telemetry, now)
	return {
		current = telemetry.current,
		latest = telemetry.latest,
		trace_observed = telemetry.trace_count,
		trace_retained = min(telemetry.trace_count, u64(GRAPHICS_FRAME_TRACE_CAPACITY)),
		trace_enabled = telemetry.trace_enabled,
	}
}

@(private = "file")
graphics_display_kind_name :: proc(kind: vga.Display_Kind) -> string {
	switch kind {
	case .Invalid:
		return "invalid"
	case .Text:
		return "text"
	case .Planar_4:
		return "planar4"
	case .Cga_1:
		return "cga1"
	case .Cga_2:
		return "cga2"
	case .Indexed_8:
		return "indexed8"
	case .Rgb_555:
		return "rgb555"
	case .Rgb_565:
		return "rgb565"
	case .Rgb_888:
		return "rgb888"
	case .Xrgb_8888:
		return "xrgb8888"
	}
	return "unknown"
}

@(private = "file")
graphics_frame_result_name :: proc(result: Graphics_Frame_Result) -> string {
	switch result {
	case .Incomplete:
		return "incomplete"
	case .Presented:
		return "presented"
	case .Superseded:
		return "superseded"
	case .Coalesced:
		return "coalesced"
	case .Capture_Failed:
		return "capture-failed"
	case .Render_Failed:
		return "render-failed"
	case .Upload_Failed:
		return "upload-failed"
	case .Compose_Failed:
		return "compose-failed"
	case .Present_Failed:
		return "present-failed"
	case .Gpu_Work:
		return "gpu-work"
	case .Reset:
		return "reset"
	}
	return "unknown"
}

@(private = "file")
graphics_frame_source_name :: proc(source: Graphics_Frame_Source) -> string {
	switch source {
	case .Legacy_Scanout:
		return "legacy-scanout"
	case .Gsw2d:
		return "gsw2d"
	case .Gsw3d:
		return "gsw3d"
	}
	return "unknown"
}

@(private = "package")
graphics_telemetry_window_text :: proc(window: Graphics_Telemetry_Window) -> string {
	elapsed_ms := graphics_frame_span_ns(window.started, window.ended) / u64(time.Millisecond)
	builder := strings.builder_make(0, 4096, context.allocator)
	fmt.sbprintf(
		&builder,
		"graphics/s window=%dms window_sequence=%d first_epoch=%d latest_epoch=%d attempts=%d unchanged=%d blocked=%d epochs=%d presented=%d superseded=%d coalesced=%d gpu_work=%d failures=%d/%d/%d/%d/%d source=%s guest_device=%d host_device=%d mode=%dx%d/%s descriptor_copy=%d/%dus texture_upload_bytes=%d converted_pixels=%d texture_recreates=%d proof_gpu_requests=%d/%d/%d input_queue=%d/%dus/%dus input_to_present=%d/%dus/%dus",
		elapsed_ms,
		window.sequence,
		window.first_epoch,
		window.latest_epoch,
		window.publish_attempts,
		window.unchanged_attempts,
		window.blocked_attempts,
		window.epochs,
		window.presented,
		window.superseded,
		window.coalesced,
		window.gpu_work_epochs,
		window.capture_failures,
		window.render_failures,
		window.upload_failures,
		window.compose_failures,
		window.present_failures,
		graphics_frame_source_name(window.latest_source),
		window.latest_guest_device_generation,
		window.latest_host_device_generation,
		window.latest_width,
		window.latest_height,
		graphics_display_kind_name(window.latest_kind),
		window.bytes_copied,
		window.descriptor_copy_ns /
		max(window.descriptor_copy_samples, u64(1)) /
		u64(time.Microsecond),
		window.bytes_uploaded,
		window.rendered_pixels,
		window.texture_recreates,
		window.gpu_requests,
		window.gpu_failures,
		window.gpu_budget,
		window.input_events,
		window.input_residence_ns / max(window.input_events, u64(1)) / u64(time.Microsecond),
		window.max_input_residence_ns / u64(time.Microsecond),
		window.input_to_present_samples,
		window.input_to_present_ns /
		max(window.input_to_present_samples, u64(1)) /
		u64(time.Microsecond),
		window.max_input_to_present_ns / u64(time.Microsecond),
	)
	p := window.producer
	fmt.sbprintf(
		&builder,
		" producer_samples=%d resets=%d generation_changes=%d session=%d device=%d scanout=%d source_mode=%dx%d/%s bpp=%d/%d pitch_derived=%d bank=%d/%d bank_programs=%d bank_changes=%d vm_steps=%d vm_wall_us=%d vm_inactive_us=%d whpx=%d/%d mmio=%d/%d/%d winquake_mmio=%d/%d/%d aperture_bytes=%d/%d lfb_dirty=%d/%d_upper_bound bank_dirty=%d/%d_upper_bound gsw2d_fenced=%d gsw3d_present_retry_reject=%d/%d/%d gsw3d_reject_causes=%d/%d/%d/%d gsw3d_queue=current:%d sampled_peak:%d lifetime_high_water:%d present_queue=current:%d sampled_peak:%d lifetime_high_water:%d owned_bytes=current:%d sampled_peak:%d lifetime_high_water:%d completion_depth=%d completed_fence=%d audio_underrun_frames=%d audio_underrun_events=%d native_pcm_starvation_frames=%d",
		p.samples,
		p.counter_resets,
		p.generation_changes,
		p.session_generation,
		p.device_generation,
		p.mode.scanout_generation,
		p.mode.width,
		p.mode.height,
		graphics_display_kind_name(p.mode.kind),
		p.mode.vbe_bpp_raw,
		p.mode.vbe_bpp_effective,
		p.mode.vbe_pitch_bytes_derived,
		p.mode.bank_read,
		p.mode.bank_write,
		p.bank_programs,
		p.bank_changes,
		p.vm_step_calls,
		p.vm_step_wall_ns / u64(time.Microsecond),
		p.vm_inactive_wait_ns / u64(time.Microsecond),
		p.whpx_run_calls,
		p.whpx_physical_exits,
		p.mmio_fallback_attempts,
		p.mmio_fallback_successes,
		p.mmio_fallback_failures,
		p.winquake_fallback_attempts,
		p.winquake_fallback_successes,
		p.winquake_fallback_failures,
		p.legacy_aperture_read_bytes,
		p.legacy_aperture_write_bytes,
		p.lfb_dirty_pages,
		p.lfb_dirty_page_coverage_bytes_upper_bound,
		p.bank_alias_dirty_pages,
		p.bank_dirty_page_coverage_bytes_upper_bound,
		p.gsw2d_fenced_completions,
		p.gsw3d_submitted_presents,
		p.gsw3d_queue_retries,
		p.gsw3d_rejections,
		p.gsw3d_rejected_poisoned,
		p.gsw3d_rejected_queue_limit,
		p.gsw3d_rejected_present_limit,
		p.gsw3d_rejected_owned_bytes_limit,
		p.gsw3d_queue_depth_current,
		p.gsw3d_queue_depth_sampled_peak,
		p.gsw3d_queue_depth_high_water,
		p.gsw3d_queued_presents_current,
		p.gsw3d_queued_presents_sampled_peak,
		p.gsw3d_queued_presents_high_water,
		p.gsw3d_owned_bytes_current,
		p.gsw3d_owned_bytes_sampled_peak,
		p.gsw3d_owned_bytes_high_water,
		p.gsw3d_completion_depth_current,
		p.gsw3d_completed_fence,
		p.output_underrun_frames,
		p.output_underrun_events,
		p.native_pcm_starvation_frames,
	)
	fmt.sbprintf(
		&builder,
		" producer_mmio=%d/%d/%d/%d/%d vga_io_writes=%d/%d_bytes gsw_control_writes=%d/%d_bytes gsw2d=%d/%d/%d/%d/%d/%d/%d/%d fenced=%d fence=%d gsw3d=%d/%d/%d/%d/%d/%d presents=%d uploads=%d/%d backend_failures=%d resets=%d",
		p.mmio_fallbacks,
		p.mmio_scalar_fallbacks,
		p.mmio_string_fallbacks,
		p.mmio_string_chunks,
		p.mmio_string_elements,
		p.vga_io_writes,
		p.vga_io_write_bytes,
		p.gsw_control_writes,
		p.gsw_control_write_bytes,
		p.gsw2d_commands,
		p.gsw2d_malformed,
		p.gsw2d_presents,
		p.gsw2d_fills,
		p.gsw2d_copies,
		p.gsw2d_palette_updates,
		p.gsw2d_blits,
		p.gsw2d_software_pixels,
		p.gsw2d_fenced_completions,
		p.gsw2d_completed_fence,
		p.gsw3d_descriptors,
		p.gsw3d_malformed,
		p.gsw3d_batches,
		p.gsw3d_batch_bytes,
		p.gsw3d_contexts_created,
		p.gsw3d_regions_registered,
		p.gsw3d_submitted_presents,
		p.gsw3d_uploads,
		p.gsw3d_upload_bytes,
		p.gsw3d_backend_failures,
		p.gsw3d_resets,
	)
	for reason in hv.Whpx_Physical_Exit_Reason {
		fmt.sbprintf(
			&builder,
			" whpx_exit_%v=%d",
			reason,
			p.whpx_physical_exit_reasons[int(reason)],
		)
	}
	g := window.host_gpu
	fmt.sbprintf(
		&builder,
		" host_gpu_samples=%d resets=%d generation_changes=%d device=%d direct_sdl_gpu_submissions=%d/%d/%dns latest_submission_ns=%d direct_physical_fences=%d/%d completion_ns=%d capacity_waits=%d in_flight=current:%d sampled_peak:%d lifetime_high_water:%d direct_present_commands=%d coalesced=%d deactivations=%d active=%d surface=%d/%dx%d canvas=%dx%d interval=%d resident_gpu_bytes=current:%d sampled_peak:%d",
		g.samples,
		g.counter_resets,
		g.generation_changes,
		g.device_generation,
		g.sdl_gpu_submission_calls,
		g.sdl_gpu_submission_failures,
		g.sdl_gpu_submission_ns,
		g.sdl_gpu_latest_submission_ns,
		g.sdl_gpu_fence_submissions,
		g.sdl_gpu_fence_completions,
		g.sdl_gpu_fence_completion_ns,
		g.sdl_gpu_fence_capacity_waits,
		g.sdl_gpu_fence_in_flight_current,
		g.sdl_gpu_fence_in_flight_sampled_peak,
		g.sdl_gpu_fence_max_in_flight,
		g.direct_present_commands,
		g.direct_present_commands_coalesced,
		g.direct_present_deactivations,
		g.direct_present_active ? 1 : 0,
		g.direct_present_surface_id,
		g.direct_present_surface_width,
		g.direct_present_surface_height,
		g.direct_present_canvas_width,
		g.direct_present_canvas_height,
		g.direct_present_interval,
		g.resident_gpu_surface_bytes_current,
		g.resident_gpu_surface_bytes_peak,
	)
	pm := g.presentation
	fmt.sbprintf(
		&builder,
		" presentation_updates=legacy_full:%d legacy_partial:%d gsw_snapshot_full:%d gsw_snapshot_partial:%d copy_bytes:%d conversion_pixels:%d upload_bytes:%d upload_regions:%d stale_total:%d stale_finalize:%d reject_invalid:%d reject_closed:%d resident_presents:%d readbacks:%d/%d restorations:%d",
		pm.legacy_full_updates,
		pm.legacy_partial_updates,
		pm.gsw_snapshot_full_updates,
		pm.gsw_snapshot_partial_updates,
		pm.copy_bytes,
		pm.conversion_pixels,
		pm.upload_bytes,
		pm.upload_regions,
		pm.stale_generation_drops,
		pm.stale_finalization_drops,
		pm.invalid_rejections,
		pm.closed_rejections,
		pm.resident_presents,
		pm.readback_requests,
		pm.readback_bytes,
		pm.last_good_restorations,
	)
	fmt.sbprintf(
		&builder,
		" presentation_resources=reuse:%d recreate:%d retire:%d host_full_fallback:%d overlay:%d/%d source_full:%d/%d/%d/%d/%d",
		pm.resource_reuses,
		pm.resource_recreations,
		pm.resource_retirements,
		pm.full_fallback_uploads,
		pm.overlay_invalidated_regions,
		pm.overlay_full_invalidations,
		pm.source_full_initial,
		pm.source_full_mode,
		pm.source_full_ambiguous,
		pm.source_full_capacity,
		pm.source_full_external,
	)
	fmt.sbprintf(
		&builder,
		" capacity_wait_ns=%d latest_capacity_wait_ns=%d latest_submission=%d/%d latest_completion=%d/%d/%dns/discarded:%d direct_draw=%d/%d/valid:%d",
		g.sdl_gpu_fence_capacity_wait_ns,
		g.sdl_gpu_fence_latest_capacity_wait_ns,
		g.sdl_gpu_latest_submission_token,
		g.sdl_gpu_latest_submission_generation,
		g.sdl_gpu_latest_completion_token,
		g.sdl_gpu_latest_completion_generation,
		g.sdl_gpu_latest_completion_duration_ns,
		g.sdl_gpu_latest_completion_discarded ? 1 : 0,
		g.direct_present_latest_draw_token,
		g.direct_present_latest_draw_generation,
		g.direct_present_latest_draw_fence_valid ? 1 : 0,
	)
	for flight, index in g.sdl_gpu_flights {
		if !flight.valid {continue}
		fmt.sbprintf(
			&builder,
			" physical_flight_%d=%d/%d/discarded:%d",
			index,
			flight.token,
			flight.generation,
			flight.discarded ? 1 : 0,
		)
	}
	fmt.sbprintf(
		&builder,
		" stage_ns capture=%d queue=%d pixel_conversion=%d texture_upload=%d gpu_drain=%d compose=%d tracked_sdl_render_present=%d end_to_end=%d",
		window.capture_ns,
		window.queue_ns,
		window.render_ns,
		window.upload_ns,
		window.gpu_drain_ns,
		window.compose_ns,
		window.present_ns,
		window.end_to_end_ns,
	)
	fmt.sbprintf(
		&builder,
		" avg_us capture=%d queue=%d pixel_conversion=%d texture_upload=%d gpu_drain=%d compose=%d present=%d end_to_end=%d max_end_to_end=%d samples=%d/%d/%d/%d/%d/%d/%d/%d",
		window.capture_ns / max(window.capture_samples, u64(1)) / u64(time.Microsecond),
		window.queue_ns / max(window.queue_samples, u64(1)) / u64(time.Microsecond),
		window.render_ns / max(window.render_samples, u64(1)) / u64(time.Microsecond),
		window.upload_ns / max(window.upload_samples, u64(1)) / u64(time.Microsecond),
		window.gpu_drain_ns / max(window.gpu_drain_samples, u64(1)) / u64(time.Microsecond),
		window.compose_ns / max(window.compose_samples, u64(1)) / u64(time.Microsecond),
		window.present_ns / max(window.present_samples, u64(1)) / u64(time.Microsecond),
		window.end_to_end_ns / max(window.end_to_end_samples, u64(1)) / u64(time.Microsecond),
		window.max_end_to_end_ns / u64(time.Microsecond),
		window.capture_samples,
		window.queue_samples,
		window.render_samples,
		window.upload_samples,
		window.gpu_drain_samples,
		window.compose_samples,
		window.present_samples,
		window.end_to_end_samples,
	)
	return strings.to_string(builder)
}

@(private = "package")
graphics_telemetry_trace_text :: proc(telemetry: ^Graphics_Telemetry) -> string {
	if telemetry == nil || !telemetry.trace_enabled {return ""}
	count := min(telemetry.trace_count, u64(GRAPHICS_FRAME_TRACE_CAPACITY))
	builder := strings.builder_make(
		0,
		int(count) * GRAPHICS_FRAME_TRACE_LINE_BYTES,
		context.allocator,
	)
	for index in 0 ..< count {
		epoch, ok := graphics_telemetry_trace_epoch(telemetry, index)
		if !ok {continue}
		p := epoch.producer
		g := epoch.host_gpu
		fmt.sbprintf(
			&builder,
			"epoch=%d lifecycle=%d source=%s scanout_generation=%d result=%s mode=%dx%d/%s descriptor_copy=%d/%dns texture_upload_bytes=%d proof_gpu=%d/%d/%d input=%d/%dus/%dus/%dus producer_samples=%d session=%d device=%d vm_steps=%d vm_wall_us=%d whpx=%d/%d mmio=%d/%d/%d aperture=%d/%d dirty_pages=%d/%d gsw2d_fenced=%d gsw3d=%d/%d/%d queue=%d/%d/%d owned=%d/%d/%d fence=%d audio=%d/%d/%d",
			epoch.sequence,
			epoch.lifecycle_generation,
			graphics_frame_source_name(epoch.source),
			epoch.scanout_generation,
			graphics_frame_result_name(epoch.result),
			epoch.width,
			epoch.height,
			graphics_display_kind_name(epoch.kind),
			epoch.bytes_copied,
			epoch.descriptor_copy_ns,
			epoch.bytes_uploaded,
			epoch.gpu_requests,
			epoch.gpu_failures,
			epoch.gpu_budget,
			epoch.input_events,
			epoch.input_residence_ns / max(epoch.input_events, u64(1)) / u64(time.Microsecond),
			epoch.max_input_residence_ns / u64(time.Microsecond),
			epoch.input_to_present_ns / u64(time.Microsecond),
			p.samples,
			p.session_generation,
			p.device_generation,
			p.vm_step_calls,
			p.vm_step_wall_ns / u64(time.Microsecond),
			p.whpx_run_calls,
			p.whpx_physical_exits,
			p.mmio_fallback_attempts,
			p.mmio_fallback_successes,
			p.mmio_fallback_failures,
			p.legacy_aperture_read_bytes,
			p.legacy_aperture_write_bytes,
			p.lfb_dirty_pages,
			p.bank_alias_dirty_pages,
			p.gsw2d_fenced_completions,
			p.gsw3d_submitted_presents,
			p.gsw3d_queue_retries,
			p.gsw3d_rejections,
			p.gsw3d_queue_depth_current,
			p.gsw3d_queue_depth_sampled_peak,
			p.gsw3d_queue_depth_high_water,
			p.gsw3d_owned_bytes_current,
			p.gsw3d_owned_bytes_sampled_peak,
			p.gsw3d_owned_bytes_high_water,
			p.gsw3d_completed_fence,
			p.output_underrun_frames,
			p.output_underrun_events,
			p.native_pcm_starvation_frames,
		)
		fmt.sbprintf(
			&builder,
			" host_device=%d direct_sdl_gpu_submissions=%d/%d/%dns latest_submission_ns=%d direct_physical_fences=%d/%d completion_ns=%d capacity_waits=%d in_flight=%d/%d/%d direct_present=%d/%d deactivations=%d surface=%d/%dx%d canvas=%dx%d interval=%d resident_gpu_bytes=%d/%d recreate=%d us=%d/%d/%d/%d/%d/%d/%d total=%d",
			g.device_generation,
			g.sdl_gpu_submission_calls,
			g.sdl_gpu_submission_failures,
			g.sdl_gpu_submission_ns,
			g.sdl_gpu_latest_submission_ns,
			g.sdl_gpu_fence_submissions,
			g.sdl_gpu_fence_completions,
			g.sdl_gpu_fence_completion_ns,
			g.sdl_gpu_fence_capacity_waits,
			g.sdl_gpu_fence_in_flight_current,
			g.sdl_gpu_fence_in_flight_sampled_peak,
			g.sdl_gpu_fence_max_in_flight,
			g.direct_present_commands,
			g.direct_present_commands_coalesced,
			g.direct_present_deactivations,
			g.direct_present_surface_id,
			g.direct_present_surface_width,
			g.direct_present_surface_height,
			g.direct_present_canvas_width,
			g.direct_present_canvas_height,
			g.direct_present_interval,
			g.resident_gpu_surface_bytes_current,
			g.resident_gpu_surface_bytes_peak,
			epoch.texture_recreated ? 1 : 0,
			graphics_frame_span_ns(epoch.capture_started, epoch.capture_ended) /
			u64(time.Microsecond),
			graphics_frame_span_ns(epoch.capture_ended, epoch.first_render_started) /
			u64(time.Microsecond),
			epoch.render_work_ns / u64(time.Microsecond),
			epoch.upload_work_ns / u64(time.Microsecond),
			graphics_frame_span_ns(epoch.gpu_drain_started, epoch.gpu_drain_ended) /
			u64(time.Microsecond),
			graphics_frame_span_ns(epoch.compose_started, epoch.compose_ended) /
			u64(time.Microsecond),
			graphics_frame_span_ns(epoch.present_started, epoch.completed) / u64(time.Microsecond),
			graphics_frame_span_ns(epoch.issued_at, epoch.completed) / u64(time.Microsecond),
		)
		pm := g.presentation
		fmt.sbprintf(
			&builder,
			" presentation=legacy:%d/%d gsw_snapshot:%d/%d copy:%d conversion:%d upload:%d/%d stale:%d/%d reject:%d/%d resident:%d readback:%d/%d restore:%d",
			pm.legacy_full_updates,
			pm.legacy_partial_updates,
			pm.gsw_snapshot_full_updates,
			pm.gsw_snapshot_partial_updates,
			pm.copy_bytes,
			pm.conversion_pixels,
			pm.upload_bytes,
			pm.upload_regions,
			pm.stale_generation_drops,
			pm.stale_finalization_drops,
			pm.invalid_rejections,
			pm.closed_rejections,
			pm.resident_presents,
			pm.readback_requests,
			pm.readback_bytes,
			pm.last_good_restorations,
		)
		fmt.sbprintf(
			&builder,
			" presentation_resources=reuse:%d recreate:%d retire:%d host_full_fallback:%d overlay:%d/%d source_full:%d/%d/%d/%d/%d",
			pm.resource_reuses,
			pm.resource_recreations,
			pm.resource_retirements,
			pm.full_fallback_uploads,
			pm.overlay_invalidated_regions,
			pm.overlay_full_invalidations,
			pm.source_full_initial,
			pm.source_full_mode,
			pm.source_full_ambiguous,
			pm.source_full_capacity,
			pm.source_full_external,
		)
		fmt.sbprintf(
			&builder,
			" producer_mmio=%d/%d/%d/%d/%d vga_io_writes=%d/%d_bytes gsw_control_writes=%d/%d_bytes gsw2d=%d/%d/%d/%d/%d/%d/%d/%d/%d/%d gsw3d=%d/%d/%d/%d/%d/%d/%d/%d/%d/%d",
			p.mmio_fallbacks,
			p.mmio_scalar_fallbacks,
			p.mmio_string_fallbacks,
			p.mmio_string_chunks,
			p.mmio_string_elements,
			p.vga_io_writes,
			p.vga_io_write_bytes,
			p.gsw_control_writes,
			p.gsw_control_write_bytes,
			p.gsw2d_commands,
			p.gsw2d_malformed,
			p.gsw2d_presents,
			p.gsw2d_fills,
			p.gsw2d_copies,
			p.gsw2d_palette_updates,
			p.gsw2d_blits,
			p.gsw2d_software_pixels,
			p.gsw2d_fenced_completions,
			p.gsw2d_completed_fence,
			p.gsw3d_descriptors,
			p.gsw3d_malformed,
			p.gsw3d_batches,
			p.gsw3d_batch_bytes,
			p.gsw3d_contexts_created,
			p.gsw3d_regions_registered,
			p.gsw3d_uploads,
			p.gsw3d_upload_bytes,
			p.gsw3d_backend_failures,
			p.gsw3d_resets,
		)
		fmt.sbprintf(
			&builder,
			" capacity_wait_ns=%d latest_capacity_wait_ns=%d latest_submission=%d/%d latest_completion=%d/%d/%dns/discarded:%d direct_draw=%d/%d/valid:%d",
			g.sdl_gpu_fence_capacity_wait_ns,
			g.sdl_gpu_fence_latest_capacity_wait_ns,
			g.sdl_gpu_latest_submission_token,
			g.sdl_gpu_latest_submission_generation,
			g.sdl_gpu_latest_completion_token,
			g.sdl_gpu_latest_completion_generation,
			g.sdl_gpu_latest_completion_duration_ns,
			g.sdl_gpu_latest_completion_discarded ? 1 : 0,
			g.direct_present_latest_draw_token,
			g.direct_present_latest_draw_generation,
			g.direct_present_latest_draw_fence_valid ? 1 : 0,
		)
		for flight, flight_index in g.sdl_gpu_flights {
			if !flight.valid {continue}
			fmt.sbprintf(
				&builder,
				" physical_flight_%d=%d/%d/discarded:%d",
				flight_index,
				flight.token,
				flight.generation,
				flight.discarded ? 1 : 0,
			)
		}
		for reason in hv.Whpx_Physical_Exit_Reason {
			fmt.sbprintf(
				&builder,
				" whpx_exit_%v=%d",
				reason,
				p.whpx_physical_exit_reasons[int(reason)],
			)
		}
		fmt.sbprintln(&builder)
	}
	return strings.to_string(builder)
}
