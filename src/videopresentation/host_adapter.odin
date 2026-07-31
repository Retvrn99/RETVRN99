// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import host "../host"
import presentation "../presentation"
import vga "../vga"

Video_Presentation_Host_Start_Proc :: proc(ctx: rawptr, lifecycle_generation: u64) -> bool
Video_Presentation_Host_Stop_Proc :: proc(ctx: rawptr)
Video_Presentation_Host_Clear_Proc :: proc(ctx: rawptr)
Video_Presentation_Host_Stage_Proc :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> host.Host_Presentation_Staged_Texture
Video_Presentation_Host_Legacy_Stage_Proc :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan,
) -> host.Host_Presentation_Staged_Texture
Video_Presentation_Host_Activate_Proc :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	staged: host.Host_Presentation_Staged_Texture,
) -> bool
Video_Presentation_Host_Retire_Proc :: proc(
	ctx: rawptr,
	staged: host.Host_Presentation_Staged_Texture,
) -> bool
Video_Presentation_Host_Invalidate_Proc :: proc(
	ctx: rawptr,
	invalidation: presentation.Gsw_Invalidation,
) -> presentation.Selector_Action

Video_Presentation_Host_Adapter :: struct {
	ctx:             rawptr,
	target:          ^host.Host,
	start:           Video_Presentation_Host_Start_Proc,
	stop:            Video_Presentation_Host_Stop_Proc,
	clear:           Video_Presentation_Host_Clear_Proc,
	stage_legacy:    Video_Presentation_Host_Legacy_Stage_Proc,
	stage_gsw:       Video_Presentation_Host_Stage_Proc,
	activate_legacy: Video_Presentation_Host_Activate_Proc,
	activate_gsw:    Video_Presentation_Host_Activate_Proc,
	retire:          Video_Presentation_Host_Retire_Proc,
	invalidate:      Video_Presentation_Host_Invalidate_Proc,
}

@(private = "package")
video_presentation_host_start :: proc(ctx: rawptr, lifecycle_generation: u64) -> bool {
	return host.host_presentation_start((^host.Host)(ctx), lifecycle_generation)
}

@(private = "package")
video_presentation_host_stop :: proc(ctx: rawptr) {
	host.host_presentation_stop((^host.Host)(ctx))
}

@(private = "package")
video_presentation_host_clear :: proc(ctx: rawptr) {
	host.host_clear_frame((^host.Host)(ctx))
}

@(private = "package")
video_presentation_host_stage_legacy :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan,
) -> host.Host_Presentation_Staged_Texture {
	return host.host_presentation_stage_legacy((^host.Host)(ctx), admission, frame, capture_plan)
}

@(private = "package")
video_presentation_host_stage_gsw :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> host.Host_Presentation_Staged_Texture {
	return host.host_presentation_stage_gsw_snapshot((^host.Host)(ctx), admission, frame)
}

@(private = "package")
video_presentation_host_activate_legacy :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	staged: host.Host_Presentation_Staged_Texture,
) -> bool {
	return host.host_presentation_commit_legacy_staged((^host.Host)(ctx), admission, staged)
}

@(private = "package")
video_presentation_host_activate_gsw :: proc(
	ctx: rawptr,
	admission: ^host.Host_Presentation_Admission,
	staged: host.Host_Presentation_Staged_Texture,
) -> bool {
	return host.host_presentation_commit_gsw_snapshot_staged((^host.Host)(ctx), admission, staged)
}

@(private = "package")
video_presentation_host_retire :: proc(
	ctx: rawptr,
	staged: host.Host_Presentation_Staged_Texture,
) -> bool {
	return host.host_presentation_retire_mutated((^host.Host)(ctx), staged)
}

@(private = "package")
video_presentation_host_invalidate :: proc(
	ctx: rawptr,
	invalidation: presentation.Gsw_Invalidation,
) -> presentation.Selector_Action {
	return host.host_presentation_apply_invalidation((^host.Host)(ctx), invalidation)
}

video_presentation_host_adapter :: proc(target: ^host.Host) -> Video_Presentation_Host_Adapter {
	return {
		ctx             = target,
		target          = target,
		start           = video_presentation_host_start,
		stop            = video_presentation_host_stop,
		clear           = video_presentation_host_clear,
		stage_legacy    = video_presentation_host_stage_legacy,
		stage_gsw       = video_presentation_host_stage_gsw,
		activate_legacy = video_presentation_host_activate_legacy,
		activate_gsw    = video_presentation_host_activate_gsw,
		retire          = video_presentation_host_retire,
		invalidate      = video_presentation_host_invalidate,
	}
}
