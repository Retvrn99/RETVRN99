// SPDX-License-Identifier: GPL-3.0-only
package vga

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

GSW3D_PACKET_SVGA9 :: u32(1)
GSW3D_COMMAND_VERSION :: u16(1)
GSW3D_RING_MIN_SIZE :: u32(256)
GSW3D_RING_MAX_SIZE :: u32(1024 * 1024)
GSW3D_MAX_BATCH_BYTES :: u32(4 * 1024 * 1024)
GSW3D_MAX_COMMAND_BYTES :: u32(1024 * 1024)
GSW3D_MAX_REGIONS :: 256
GSW3D_MAX_CONTEXTS :: 128
GSW3D_MAX_QUEUED_WORK :: 64
GSW3D_MAX_QUEUED_PRESENTS :: 2
GSW3D_MAX_QUEUED_BATCH_BYTES :: u64(16 * 1024 * 1024)
GSW3D_MAX_SHADER_BYTES :: 64 * 1024

GSW3D_REG_PACKET_FORMAT :: u32(0x100)
GSW3D_REG_CAPABILITIES :: u32(0x104)
GSW3D_REG_RING_GPA_LOW :: u32(0x108)
GSW3D_REG_RING_GPA_HIGH :: u32(0x10C)
GSW3D_REG_RING_SIZE :: u32(0x110)
GSW3D_REG_RING_HEAD :: u32(0x114)
GSW3D_REG_RING_TAIL :: u32(0x118)
GSW3D_REG_DOORBELL :: u32(0x11C)
GSW3D_REG_STATUS :: u32(0x120)
GSW3D_REG_FENCE_LOW :: u32(0x124)
GSW3D_REG_FENCE_HIGH :: u32(0x128)
GSW3D_REG_ERROR :: u32(0x12C)
GSW3D_REG_FIRST :: GSW3D_REG_PACKET_FORMAT
GSW3D_REG_END :: u32(0x180)

GSW3D_BACKEND_SVGA9 :: u32(1 << 0)
GSW3D_BACKEND_DIRECT_PRESENT :: u32(1 << 1)

GSW3D_STATUS_READY :: u32(1 << 0)
GSW3D_STATUS_BUSY :: u32(1 << 1)
GSW3D_STATUS_ERROR :: u32(1 << 2)
GSW3D_STATUS_QUEUE_FULL :: u32(1 << 3)
GSW3D_STATUS_RESET :: u32(1 << 31)

Gsw3d_Error :: enum u32 {
	None,
	Invalid_Ring,
	Malformed_Descriptor,
	Invalid_Region,
	Invalid_Context,
	Invalid_Batch,
	Unsupported_Packet,
	Queue_Full,
	Backend_Unavailable,
	Backend_Failure,
}

Gsw3d_Opcode :: enum u16 {
	Register_Region   = 1,
	Unregister_Region = 2,
	Create_Context    = 3,
	Destroy_Context   = 4,
	Submit            = 5,
	Direct_Present    = 6,
}

Gsw3d_Work_Kind :: enum u8 {
	Transport_Barrier,
	Reset,
	Create_Context,
	Destroy_Context,
	Submit_Svga9,
	Direct_Present,
}

Gsw3d_Rect :: struct {
	x, y, width, height: u32,
}

Gsw3d_Work :: struct {
	kind:        Gsw3d_Work_Kind,
	generation:  u64,
	fence:       u64,
	context_id:  u32,
	surface_id:  u32,
	source:      Gsw3d_Rect,
	destination: Gsw3d_Rect,
	interval:    u32,
	batch:       []u8,
}

Gsw3d_Execute_Proc :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool
Gsw3d_Reset_Proc :: proc(ctx: rawptr) -> bool
Gsw3d_Validate_Svga9_Proc :: proc(ctx: rawptr, batch: []u8) -> bool

Gsw3d_Backend :: struct {
	ctx:            rawptr,
	capabilities:   u32,
	validate_svga9: Gsw3d_Validate_Svga9_Proc,
	execute:        Gsw3d_Execute_Proc,
	reset:          Gsw3d_Reset_Proc,
}

Gsw3d_Region :: struct {
	live: bool,
	id:   u32,
	gpa:  u64,
	size: u64,
}

Gsw3d_Context :: struct {
	live: bool,
	id:   u32,
}

Gsw3d_Metrics :: struct {
	descriptors:        u64,
	malformed:          u64,
	batches:            u64,
	batch_bytes:        u64,
	contexts_created:   u64,
	regions_registered: u64,
	presents:           u64,
	backend_failures:   u64,
	resets:             u64,
}

Gsw3d :: struct {
	allocator:          runtime.Allocator,
	ring_gpa:           u64,
	ring_size:          u32,
	ring_head:          u32,
	ring_tail:          u32,
	status:             u32,
	error:              Gsw3d_Error,
	completed_fence:    u64,
	regions:            [GSW3D_MAX_REGIONS]Gsw3d_Region,
	contexts:           [GSW3D_MAX_CONTEXTS]Gsw3d_Context,
	backend:            Gsw3d_Backend,
	metrics:            Gsw3d_Metrics,
	mu:                 sync.Mutex,
	work_ready:         sync.Cond,
	idle:               sync.Cond,
	worker:             ^thread.Thread,
	queue:              [GSW3D_MAX_QUEUED_WORK]^Gsw3d_Work,
	queue_head:         int,
	queue_tail:         int,
	queue_count:        int,
	queued_presents:    int,
	owned_batch_bytes:  u64,
	active:             bool,
	stopping:           bool,
	generation:         u64,
	reset_pending:      bool,
	reset_completed:    bool,
	pending_fence:      u64,
	pending_completion: bool,
	pending_error:      Gsw3d_Error,
}

@(private = "file")
Gsw3d_Execute_Result :: enum {
	Success,
	Retry,
	Invalid,
}

gsw3d_init :: proc(d: ^Gsw3d) {
	if d == nil {return}
	d^ = {
		allocator  = runtime.heap_allocator(),
		generation = 1,
	}
}

@(private = "file")
gsw3d_work_free :: proc(d: ^Gsw3d, work: ^Gsw3d_Work) {
	if work == nil {return}
	if work.batch != nil {delete(work.batch, d.allocator)}
	free(work, d.allocator)
}

@(private = "file")
gsw3d_worker_proc :: proc(d: ^Gsw3d) {
	for {
		sync.lock(&d.mu)
		for d.queue_count == 0 && !d.stopping {sync.cond_wait(&d.work_ready, &d.mu)}
		if d.stopping {
			sync.unlock(&d.mu)
			return
		}
		work := d.queue[d.queue_head]
		d.queue[d.queue_head] = nil
		d.queue_head = (d.queue_head + 1) % GSW3D_MAX_QUEUED_WORK
		d.queue_count -= 1
		d.active = true
		sync.unlock(&d.mu)

		ok := false
		switch work.kind {
		case .Transport_Barrier:
			ok = true
		case .Reset:
			ok = d.backend.reset != nil && d.backend.reset(d.backend.ctx)
		case .Create_Context, .Destroy_Context, .Submit_Svga9, .Direct_Present:
			// A synchronous backend returns only after host effects complete.
			// A future token API will advertise asynchronous fences.
			ok = d.backend.execute != nil && d.backend.execute(d.backend.ctx, work)
		}

		sync.lock(&d.mu)
		if work.kind == .Direct_Present {d.queued_presents -= 1}
		if work.batch != nil {d.owned_batch_bytes -= u64(len(work.batch))}
		if work.generation == d.generation {
			d.pending_completion = true
			if work.kind == .Reset {d.reset_completed = true}
			if work.fence != 0 {d.pending_fence = work.fence}
			if !ok {
				d.pending_error = .Backend_Failure
				d.metrics.backend_failures += 1
			}
		}
		d.active = false
		sync.unlock(&d.mu)
		gsw3d_work_free(d, work)
		sync.cond_broadcast(&d.idle)
	}
}

gsw3d_attach_backend :: proc(d: ^Gsw3d, backend: Gsw3d_Backend) -> bool {
	known_caps := GSW3D_BACKEND_SVGA9 | GSW3D_BACKEND_DIRECT_PRESENT
	if d == nil ||
	   backend.execute == nil ||
	   backend.reset == nil ||
	   backend.validate_svga9 == nil ||
	   backend.capabilities & GSW3D_BACKEND_SVGA9 == 0 ||
	   backend.capabilities &~ known_caps != 0 ||
	   d.worker != nil {
		return false
	}
	d.backend = backend
	d.worker = thread.create_and_start_with_poly_data(d, gsw3d_worker_proc)
	if d.worker == nil {
		d.backend = {}
		return false
	}
	d.status = GSW3D_STATUS_READY
	return true
}

gsw_vga_set_3d_backend :: proc(g: ^Gsw_Vga, backend: Gsw3d_Backend) -> bool {
	if g == nil || !gsw3d_attach_backend(&g.three_d, backend) {return false}
	g.capabilities |= GSW_CAP_3D_SVGA9
	if backend.capabilities & GSW3D_BACKEND_DIRECT_PRESENT != 0 {
		g.capabilities |= GSW_CAP_DIRECT_PRESENT
	}
	return true
}

@(private = "file")
gsw3d_cancel_queued :: proc(d: ^Gsw3d) {
	for d.queue_count > 0 {
		work := d.queue[d.queue_head]
		d.queue[d.queue_head] = nil
		d.queue_head = (d.queue_head + 1) % GSW3D_MAX_QUEUED_WORK
		d.queue_count -= 1
		if work.kind == .Direct_Present {d.queued_presents -= 1}
		if work.batch != nil {d.owned_batch_bytes -= u64(len(work.batch))}
		gsw3d_work_free(d, work)
	}
	d.queue_head, d.queue_tail = 0, 0
}

gsw3d_reset :: proc(d: ^Gsw3d) {
	if d == nil {return}
	reset_work: ^Gsw3d_Work
	if d.worker != nil {reset_work = gsw3d_work_new(d, .Reset, 0, 0)}
	sync.lock(&d.mu)
	d.generation += 1
	if d.generation == 0 {d.generation = 1}
	gsw3d_cancel_queued(d)
	d.pending_completion = false
	d.pending_error = .None
	d.pending_fence = 0
	d.reset_completed = false
	d.reset_pending = reset_work != nil
	if reset_work != nil {
		reset_work.generation = d.generation
		d.queue[d.queue_tail] = reset_work
		d.queue_tail = (d.queue_tail + 1) % GSW3D_MAX_QUEUED_WORK
		d.queue_count += 1
	}
	sync.unlock(&d.mu)
	if reset_work != nil {sync.cond_signal(&d.work_ready)}
	for &region in d.regions {region = {}}
	for &entry in d.contexts {entry = {}}
	d.ring_head = d.ring_tail
	d.error = .None
	d.completed_fence = 0
	d.status = d.worker != nil ? GSW3D_STATUS_RESET | GSW3D_STATUS_BUSY : 0
	d.metrics.resets += 1
}

gsw3d_destroy :: proc(d: ^Gsw3d) {
	if d == nil {return}
	if d.worker != nil {
		sync.lock(&d.mu)
		d.stopping = true
		gsw3d_cancel_queued(d)
		sync.unlock(&d.mu)
		sync.cond_broadcast(&d.work_ready)
		thread.destroy(d.worker)
	}
	d^ = {}
}

gsw3d_wait_idle :: proc(d: ^Gsw3d, timeout: time.Duration) -> bool {
	if d == nil {return false}
	sync.lock(&d.mu)
	defer sync.unlock(&d.mu)
	for d.queue_count != 0 || d.active {
		if !sync.cond_wait_with_timeout(&d.idle, &d.mu, timeout) {return false}
	}
	return true
}

@(private = "file")
gsw3d_ring_valid :: proc(d: ^Gsw3d, ram: []u8) -> bool {
	return(
		d.worker != nil &&
		d.ring_size >= GSW3D_RING_MIN_SIZE &&
		d.ring_size <= GSW3D_RING_MAX_SIZE &&
		d.ring_size & (d.ring_size - 1) == 0 &&
		d.ring_head < d.ring_size &&
		d.ring_tail < d.ring_size &&
		d.ring_gpa <= u64(len(ram)) &&
		u64(d.ring_size) <= u64(len(ram)) - d.ring_gpa \
	)
}

@(private = "file")
gsw3d_ring_available :: proc(d: ^Gsw3d) -> u32 {
	return(
		d.ring_tail >= d.ring_head ? d.ring_tail - d.ring_head : d.ring_size - d.ring_head + d.ring_tail \
	)
}

@(private = "file")
gsw3d_ring_read :: proc(d: ^Gsw3d, ram: []u8, offset: u32, out: []u8) {
	first := min(len(out), int(d.ring_size - offset))
	start := int(d.ring_gpa + u64(offset))
	copy(out[:first], ram[start:start + first])
	if first < len(out) {
		base := int(d.ring_gpa)
		copy(out[first:], ram[base:base + len(out) - first])
	}
}

@(private = "file")
gsw3d_find_region :: proc(d: ^Gsw3d, id: u32) -> ^Gsw3d_Region {
	for &region in d.regions {if region.live && region.id == id {return &region}}
	return nil
}

@(private = "file")
gsw3d_free_region :: proc(d: ^Gsw3d) -> ^Gsw3d_Region {
	for &region in d.regions {if !region.live {return &region}}
	return nil
}

@(private = "package")
gsw3d_find_context :: proc(d: ^Gsw3d, id: u32) -> ^Gsw3d_Context {
	for &entry in d.contexts {if entry.live && entry.id == id {return &entry}}
	return nil
}

@(private = "file")
gsw3d_free_context :: proc(d: ^Gsw3d) -> ^Gsw3d_Context {
	for &entry in d.contexts {if !entry.live {return &entry}}
	return nil
}

@(private = "file")
gsw3d_svga9_opcode_allowed :: proc(opcode: u32) -> bool {
	switch opcode {
	case 1041,
	     1042,
	     1043,
	     1047,
	     1048,
	     1049,
	     1050,
	     1051,
	     1052,
	     1053,
	     1054,
	     1055,
	     1056,
	     1057,
	     1059,
	     1060,
	     1061,
	     1062,
	     1063,
	     1064,
	     1070,
	     1071:
		return true
	}
	return false
}

@(private = "file")
gsw3d_svga9_context_opcode :: proc(opcode: u32) -> bool {
	return opcode >= 1047 && opcode <= 1064 && opcode != 1058
}

@(private = "file")
gsw3d_svga9_command_shape_valid :: proc(opcode: u32, body: []u8) -> bool {
	size := len(body)
	switch opcode {
	case 1041:
		return size == 4 && gsw_rd32(body, 0) != 0
	case 1042:
		return size >= 60 && (size - 24) % 36 == 0
	case 1043:
		return size == 76
	case 1047:
		return size == 72
	case 1048:
		return size == 12
	case 1049:
		return size >= 12 && (size - 4) % 8 == 0 && (size - 4) / 8 <= 256
	case 1050:
		return size == 20
	case 1051:
		return size >= 16 && (size - 4) % 12 == 0 && (size - 4) / 12 <= 256
	case 1052:
		return size == 76
	case 1053:
		return size == 124
	case 1054:
		return size == 12
	case 1055:
		return size == 20
	case 1056:
		return size == 24
	case 1057:
		return size >= 36 && (size - 20) % 16 == 0 && (size - 20) / 16 <= 4096
	case 1059:
		return size >= 16 && size <= GSW3D_MAX_SHADER_BYTES
	case 1060, 1061:
		return size == 12
	case 1062:
		return size == 32
	case 1063:
		if size < 12 {return false}
		declarations := gsw_rd32(body, 4)
		ranges := gsw_rd32(body, 8)
		if declarations == 0 || declarations > 32 || ranges == 0 || ranges > 32 {return false}
		base := 12 + int(declarations) * 36 + int(ranges) * 28
		return size == base || size == base + int(declarations) * 4
	case 1064:
		return size == 20
	case 1070:
		if size < 56 || gsw_rd32(body, 0) == 0 {return false}
		mip_levels: u32
		for face in 0 ..< 6 {
			levels := gsw_rd32(body, 12 + face * 4)
			if levels > 16 {return false}
			mip_levels += levels
		}
		return mip_levels > 0 && size == 44 + int(mip_levels) * 12
	case 1071:
		return size == 8
	}
	return false
}

gsw3d_validate_svga9_batch :: proc(batch: []u8, context_id: u32 = 0) -> bool {
	if len(batch) < 8 || len(batch) > int(GSW3D_MAX_BATCH_BYTES) || len(batch) & 3 != 0 {
		return false
	}
	offset := 0
	for offset < len(batch) {
		if len(batch) - offset < 8 {return false}
		opcode := gsw_rd32(batch, offset)
		body_size := gsw_rd32(batch, offset + 4)
		if !gsw3d_svga9_opcode_allowed(opcode) ||
		   body_size == 0 ||
		   body_size & 3 != 0 ||
		   body_size > GSW3D_MAX_COMMAND_BYTES ||
		   u64(body_size) > u64(len(batch) - offset - 8) {
			return false
		}
		body := batch[offset + 8:offset + 8 + int(body_size)]
		if !gsw3d_svga9_command_shape_valid(opcode, body) ||
		   context_id != 0 &&
			   gsw3d_svga9_context_opcode(opcode) &&
			   gsw_rd32(body, 0) != context_id {
			return false
		}
		offset += 8 + int(body_size)
	}
	return offset == len(batch)
}

@(private = "file")
gsw3d_queue_owned :: proc(d: ^Gsw3d, work: ^Gsw3d_Work) -> bool {
	sync.lock(&d.mu)
	batch_bytes := work.batch == nil ? u64(0) : u64(len(work.batch))
	full :=
		d.queue_count == GSW3D_MAX_QUEUED_WORK ||
		work.kind == .Direct_Present && d.queued_presents >= GSW3D_MAX_QUEUED_PRESENTS ||
		batch_bytes > GSW3D_MAX_QUEUED_BATCH_BYTES - d.owned_batch_bytes
	if full {
		sync.unlock(&d.mu)
		return false
	}
	work.generation = d.generation
	d.queue[d.queue_tail] = work
	d.queue_tail = (d.queue_tail + 1) % GSW3D_MAX_QUEUED_WORK
	d.queue_count += 1
	if work.kind == .Direct_Present {d.queued_presents += 1}
	d.owned_batch_bytes += batch_bytes
	sync.unlock(&d.mu)
	sync.cond_signal(&d.work_ready)
	return true
}

@(private = "file")
gsw3d_queue_transport_barrier :: proc(d: ^Gsw3d, fence: u64) -> bool {
	if fence == 0 {return true}
	work := gsw3d_work_new(d, .Transport_Barrier, fence, 0)
	if gsw3d_queue_owned(d, work) {return true}
	gsw3d_work_free(d, work)
	return false
}

@(private = "file")
gsw3d_fail :: proc(d: ^Gsw3d, error: Gsw3d_Error, malformed: bool = true) {
	d.error = error
	d.status |= GSW3D_STATUS_ERROR
	if malformed {d.metrics.malformed += 1}
}

@(private = "file")
gsw3d_work_new :: proc(
	d: ^Gsw3d,
	kind: Gsw3d_Work_Kind,
	fence: u64,
	context_id: u32,
) -> ^Gsw3d_Work {
	work := new(Gsw3d_Work, d.allocator)
	work.kind = kind
	work.fence = fence
	work.context_id = context_id
	return work
}

@(private = "file")
gsw3d_execute_descriptor :: proc(d: ^Gsw3d, descriptor, ram: []u8) -> Gsw3d_Execute_Result {
	opcode := Gsw3d_Opcode(gsw_rd16(descriptor, 0))
	fence := gsw_rd64(descriptor, 8)
	switch opcode {
	case .Register_Region:
		if len(descriptor) != 40 || gsw_rd32(descriptor, 20) != 0 {return .Invalid}
		id := gsw_rd32(descriptor, 16)
		gpa := gsw_rd64(descriptor, 24)
		size := gsw_rd64(descriptor, 32)
		if id == 0 ||
		   size == 0 ||
		   gpa > u64(len(ram)) ||
		   size > u64(len(ram)) - gpa ||
		   gsw3d_find_region(d, id) != nil {
			d.error = .Invalid_Region
			return .Invalid
		}
		region := gsw3d_free_region(d)
		if region == nil {d.error = .Invalid_Region; return .Invalid}
		if !gsw3d_queue_transport_barrier(d, fence) {return .Retry}
		region^ = {
			live = true,
			id   = id,
			gpa  = gpa,
			size = size,
		}
		d.metrics.regions_registered += 1
	case .Unregister_Region:
		if len(descriptor) != 24 || gsw_rd32(descriptor, 20) != 0 {return .Invalid}
		region := gsw3d_find_region(d, gsw_rd32(descriptor, 16))
		if region == nil {d.error = .Invalid_Region; return .Invalid}
		if !gsw3d_queue_transport_barrier(d, fence) {return .Retry}
		region^ = {}
	case .Create_Context:
		if len(descriptor) != 24 || gsw_rd32(descriptor, 20) != 0 {return .Invalid}
		id := gsw_rd32(descriptor, 16)
		entry := gsw3d_free_context(d)
		if id == 0 || entry == nil || gsw3d_find_context(d, id) != nil {
			d.error = .Invalid_Context
			return .Invalid
		}
		work := gsw3d_work_new(d, .Create_Context, fence, id)
		if !gsw3d_queue_owned(d, work) {gsw3d_work_free(d, work); return .Retry}
		entry^ = {
			live = true,
			id   = id,
		}
		d.metrics.contexts_created += 1
	case .Destroy_Context:
		if len(descriptor) != 24 || gsw_rd32(descriptor, 20) != 0 {return .Invalid}
		id := gsw_rd32(descriptor, 16)
		entry := gsw3d_find_context(d, id)
		if entry == nil {d.error = .Invalid_Context; return .Invalid}
		work := gsw3d_work_new(d, .Destroy_Context, fence, id)
		if !gsw3d_queue_owned(d, work) {gsw3d_work_free(d, work); return .Retry}
		entry^ = {}
	case .Submit:
		if len(descriptor) != 40 {return .Invalid}
		context_id := gsw_rd32(descriptor, 16)
		region_id := gsw_rd32(descriptor, 20)
		offset := gsw_rd64(descriptor, 24)
		length := gsw_rd32(descriptor, 32)
		packet_format := gsw_rd32(descriptor, 36)
		region := gsw3d_find_region(d, region_id)
		if gsw3d_find_context(d, context_id) == nil {d.error = .Invalid_Context; return .Invalid}
		if region == nil ||
		   length == 0 ||
		   length > GSW3D_MAX_BATCH_BYTES ||
		   offset > region.size ||
		   u64(length) > region.size - offset {
			d.error = .Invalid_Region
			return .Invalid
		}
		if packet_format != GSW3D_PACKET_SVGA9 {
			d.error = .Unsupported_Packet
			return .Invalid
		}
		start := region.gpa + offset
		batch := make([]u8, int(length), d.allocator)
		copy(batch, ram[int(start):int(start + u64(length))])
		if !gsw3d_validate_svga9_batch(batch, context_id) ||
		   !d.backend.validate_svga9(d.backend.ctx, batch) {
			delete(batch, d.allocator)
			d.error = .Invalid_Batch
			return .Invalid
		}
		work := gsw3d_work_new(d, .Submit_Svga9, fence, context_id)
		work.batch = batch
		if !gsw3d_queue_owned(d, work) {gsw3d_work_free(d, work); return .Retry}
		d.metrics.batches += 1
		d.metrics.batch_bytes += u64(length)
	case .Direct_Present:
		if len(descriptor) != 64 ||
		   d.backend.capabilities & GSW3D_BACKEND_DIRECT_PRESENT == 0 ||
		   gsw_rd32(descriptor, 60) != 0 {
			return .Invalid
		}
		context_id := gsw_rd32(descriptor, 16)
		if gsw3d_find_context(d, context_id) == nil {d.error = .Invalid_Context; return .Invalid}
		work := gsw3d_work_new(d, .Direct_Present, fence, context_id)
		work.surface_id = gsw_rd32(descriptor, 20)
		work.source = {
			x      = gsw_rd32(descriptor, 24),
			y      = gsw_rd32(descriptor, 28),
			width  = gsw_rd32(descriptor, 32),
			height = gsw_rd32(descriptor, 36),
		}
		work.destination = {
			x      = gsw_rd32(descriptor, 40),
			y      = gsw_rd32(descriptor, 44),
			width  = gsw_rd32(descriptor, 48),
			height = gsw_rd32(descriptor, 52),
		}
		work.interval = gsw_rd32(descriptor, 56)
		if work.surface_id == 0 ||
		   work.source.width == 0 ||
		   work.source.height == 0 ||
		   work.destination.width == 0 ||
		   work.destination.height == 0 ||
		   work.interval > 4 {
			gsw3d_work_free(d, work)
			return .Invalid
		}
		if !gsw3d_queue_owned(d, work) {gsw3d_work_free(d, work); return .Retry}
		d.metrics.presents += 1
	case:
		return .Invalid
	}
	return .Success
}

@(private = "file")
gsw3d_process :: proc(d: ^Gsw3d, ram: []u8) {
	sync.lock(&d.mu)
	reset_pending := d.reset_pending
	sync.unlock(&d.mu)
	if reset_pending {
		d.status |= GSW3D_STATUS_RESET | GSW3D_STATUS_BUSY
		return
	}
	if !gsw3d_ring_valid(d, ram) {gsw3d_fail(d, .Invalid_Ring); return}
	d.status &~= GSW3D_STATUS_QUEUE_FULL
	for gsw3d_ring_available(d) > 0 {
		available := gsw3d_ring_available(d)
		if available < 16 {gsw3d_fail(d, .Malformed_Descriptor); return}
		header: [16]u8
		gsw3d_ring_read(d, ram, d.ring_head, header[:])
		version := gsw_rd16(header[:], 2)
		length := gsw_rd32(header[:], 4)
		if version != GSW3D_COMMAND_VERSION ||
		   length < 16 ||
		   length & 3 != 0 ||
		   length > available ||
		   length > d.ring_size {
			gsw3d_fail(d, .Malformed_Descriptor)
			return
		}
		descriptor := make([]u8, int(length))
		gsw3d_ring_read(d, ram, d.ring_head, descriptor)
		result := gsw3d_execute_descriptor(d, descriptor, ram)
		delete(descriptor)
		switch result {
		case .Invalid:
			if d.error == .None {d.error = .Malformed_Descriptor}
			gsw3d_fail(d, d.error)
			return
		case .Retry:
			d.error = .Queue_Full
			d.status |= GSW3D_STATUS_QUEUE_FULL
			return
		case .Success:
		}
		d.metrics.descriptors += 1
		d.ring_head = (d.ring_head + length) & (d.ring_size - 1)
	}
}

gsw3d_poll :: proc(d: ^Gsw3d) -> bool {
	if d == nil {return false}
	sync.lock(&d.mu)
	completion := d.pending_completion
	notify := false
	if completion {
		notify = d.pending_fence != 0 || d.pending_error != .None
		if d.pending_fence != 0 {d.completed_fence = d.pending_fence}
		if d.pending_error != .None {
			d.error = d.pending_error
			d.status |= GSW3D_STATUS_ERROR
		}
		d.pending_completion = false
		d.pending_fence = 0
		d.pending_error = .None
	}
	if d.reset_completed {
		d.reset_completed = false
		d.reset_pending = false
		d.status &~= GSW3D_STATUS_RESET
		d.status |= GSW3D_STATUS_READY
	}
	busy := d.queue_count != 0 || d.active || d.reset_pending
	if busy {d.status |= GSW3D_STATUS_BUSY} else {d.status &~= GSW3D_STATUS_BUSY | GSW3D_STATUS_QUEUE_FULL}
	sync.unlock(&d.mu)
	return notify
}

gsw3d_register_read :: proc(d: ^Gsw3d, offset: u32) -> (u32, bool) {
	if d == nil || offset < GSW3D_REG_FIRST || offset >= GSW3D_REG_END {return 0, false}
	switch offset {
	case GSW3D_REG_PACKET_FORMAT:
		return d.backend.capabilities & GSW3D_BACKEND_SVGA9 != 0 ? GSW3D_PACKET_SVGA9 : 0, true
	case GSW3D_REG_CAPABILITIES:
		return d.backend.capabilities, true
	case GSW3D_REG_RING_GPA_LOW:
		return u32(d.ring_gpa), true
	case GSW3D_REG_RING_GPA_HIGH:
		return u32(d.ring_gpa >> 32), true
	case GSW3D_REG_RING_SIZE:
		return d.ring_size, true
	case GSW3D_REG_RING_HEAD:
		return d.ring_head, true
	case GSW3D_REG_RING_TAIL:
		return d.ring_tail, true
	case GSW3D_REG_STATUS:
		return d.status, true
	case GSW3D_REG_FENCE_LOW:
		return u32(d.completed_fence), true
	case GSW3D_REG_FENCE_HIGH:
		return u32(d.completed_fence >> 32), true
	case GSW3D_REG_ERROR:
		return u32(d.error), true
	}
	return 0, true
}

gsw3d_register_write :: proc(d: ^Gsw3d, offset, value: u32, ram: []u8) -> bool {
	if d == nil || offset < GSW3D_REG_FIRST || offset >= GSW3D_REG_END {return false}
	switch offset {
	case GSW3D_REG_RING_GPA_LOW:
		d.ring_gpa = d.ring_gpa & 0xFFFF_FFFF_0000_0000 | u64(value)
	case GSW3D_REG_RING_GPA_HIGH:
		d.ring_gpa = d.ring_gpa & 0x0000_0000_FFFF_FFFF | u64(value) << 32
	case GSW3D_REG_RING_SIZE:
		d.ring_size = value
	case GSW3D_REG_RING_HEAD:
		d.ring_head = value
	case GSW3D_REG_RING_TAIL:
		d.ring_tail = value
	case GSW3D_REG_DOORBELL:
		gsw3d_process(d, ram)
	case GSW3D_REG_STATUS:
		if value & GSW3D_STATUS_RESET != 0 {gsw3d_reset(d)}
		if value & GSW3D_STATUS_ERROR != 0 {
			d.error = .None
			d.status &~= GSW3D_STATUS_ERROR
		}
	}
	return true
}
