// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"

Aspect_Policy :: enum u8 {
	Auto,
	Square_Pixels,
	Force_4_3,
}

aspect_policy_name :: proc(policy: Aspect_Policy) -> cstring {
	switch policy {
	case .Auto:
		return "Auto"
	case .Square_Pixels:
		return "Square Pixels"
	case .Force_4_3:
		return "Force 4:3"
	}
	return "Auto"
}

host_resolve_display_aspect :: proc(
	header: contract.Header,
	policy: Aspect_Policy,
) -> contract.Aspect_Ratio {
	switch policy {
	case .Square_Pixels:
		return contract.aspect_ratio_make(header.canvas_extent.width, header.canvas_extent.height)
	case .Force_4_3:
		return {4, 3}
	case .Auto:
		return header.display_aspect
	}
	return header.display_aspect
}

@(private = "file")
host_active_presentation_header :: proc(h: ^Host) -> (contract.Header, bool) {
	if h == nil || !h.has_frame {return {}, false}
	state := host_presentation_state(h)
	switch state.selector.active.kind {
	case .Legacy:
		return state.legacy.header, state.legacy.header.sequence != 0
	case .Gsw:
		return state.gsw.header, state.gsw.header.sequence != 0
	case .None:
	}
	if h.gpu_present.surface_id != 0 {
		width := h.gpu_present.canvas_width
		height := h.gpu_present.canvas_height
		return {
				display_aspect = contract.aspect_ratio_make(width, height),
				canvas_extent = {width, height},
			},
			width != 0 && height != 0
	}
	return {}, false
}

host_apply_display_aspect :: proc(h: ^Host, header: contract.Header) {
	if h == nil {return}
	aspect := host_resolve_display_aspect(header, h.aspect_policy)
	h.aspect_width = int(aspect.width)
	h.aspect_height = int(aspect.height)
	h.canvas_width = int(header.canvas_extent.width)
	h.canvas_height = int(header.canvas_extent.height)
}

host_apply_square_pixel_canvas_aspect :: proc(h: ^Host, width, height: u32) {
	if h == nil {return}
	host_apply_display_aspect(
		h,
		{
			display_aspect = contract.aspect_ratio_make(width, height),
			canvas_extent = {width, height},
		},
	)
}

host_set_aspect_policy :: proc(h: ^Host, policy: Aspect_Policy) -> bool {
	if h == nil {return false}
	switch policy {
	case .Auto, .Square_Pixels, .Force_4_3:
	case:
		return false
	}
	h.aspect_policy = policy
	header, available := host_active_presentation_header(h)
	if available {host_apply_display_aspect(h, header)}
	return true
}
