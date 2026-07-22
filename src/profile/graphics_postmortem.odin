// SPDX-License-Identifier: GPL-3.0-only
package profile

GRAPHICS_POSTMORTEM_MAX_BYTES :: 96 * 1024

Graphics_Postmortem_Save_Diagnostic :: enum u8 {
	None,
	Invalid_Path,
	Empty_Payload,
	Payload_Too_Large,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

graphics_postmortem_save :: proc(
	path: string,
	payload: []u8,
) -> Graphics_Postmortem_Save_Diagnostic {
	if path == "" {return .Invalid_Path}
	if len(payload) == 0 {return .Empty_Payload}
	if len(payload) > GRAPHICS_POSTMORTEM_MAX_BYTES {return .Payload_Too_Large}
	switch atomic_replace(path, payload, "graphics-postmortem") {
	case .None:
		return .None
	case .Create_Directory_Failed:
		return .Create_Directory_Failed
	case .Temporary_Path_Failed:
		return .Temporary_Path_Failed
	case .Write_Failed:
		return .Write_Failed
	case .Replace_Failed:
		return .Replace_Failed
	}
	return .Write_Failed
}
