// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

GSW_VGA_PACKAGE_ID :: "gsw-vga"
GSW_SOUND_PACKAGE_ID :: "gsw-sound"
GSW_DIRECTX9_RUNTIME_PACKAGE_ID :: "directx9-runtime"
GSW_DX9_COMPAT_PACKAGE_ID :: "gsw-dx9-compat"
GSW_VGA_HARDWARE_ID :: "PCI\\VEN_FFFE&DEV_0002"
GSW_SOUND_HARDWARE_ID :: "PCI\\VEN_FFFE&DEV_0003"
GSW_DIRECTX9_RUNTIME_ORDER :: u16(100)
GSW_DX9_COMPAT_ORDER :: u16(200)

Driver_Delivery_Phase :: enum u8 {
	PnP,
	RunOnce_Component,
}

Driver_Delivery_Component :: struct {
	package_id:        string,
	phase:             Driver_Delivery_Phase,
	hardware_id:       string,
	run_once_order:    u16,
	payload_available: bool,
}

Driver_Delivery_Plan_Diagnostic :: enum u8 {
	None,
	Invalid_Plan,
	Package_Content_Unavailable,
}

@(rodata)
GSW_DRIVER_DELIVERY_COMPONENTS := [?]Driver_Delivery_Component {
	{package_id = GSW_VGA_PACKAGE_ID, phase = .PnP, hardware_id = GSW_VGA_HARDWARE_ID},
	{package_id = GSW_SOUND_PACKAGE_ID, phase = .PnP, hardware_id = GSW_SOUND_HARDWARE_ID},
	{
		package_id = GSW_DIRECTX9_RUNTIME_PACKAGE_ID,
		phase = .RunOnce_Component,
		run_once_order = GSW_DIRECTX9_RUNTIME_ORDER,
	},
	{
		package_id = GSW_DX9_COMPAT_PACKAGE_ID,
		phase = .RunOnce_Component,
		run_once_order = GSW_DX9_COMPAT_ORDER,
	},
}

gsw_driver_delivery_plan :: proc() -> []Driver_Delivery_Component {
	return GSW_DRIVER_DELIVERY_COMPONENTS[:]
}

driver_delivery_plan_validate :: proc(
	components: []Driver_Delivery_Component,
	require_payloads := true,
) -> Driver_Delivery_Plan_Diagnostic {
	if len(components) != len(GSW_DRIVER_DELIVERY_COMPONENTS) {return .Invalid_Plan}
	last_run_once_order: u16
	vga_found := false
	sound_found := false
	directx_found := false
	dx9_compat_found := false
	content_unavailable := false
	for component, index in components {
		if !driver_package_id_valid(component.package_id) {return .Invalid_Plan}
		for prior in 0 ..< index {
			if component.package_id == components[prior].package_id {return .Invalid_Plan}
			if component.hardware_id != "" &&
			   component.hardware_id == components[prior].hardware_id {
				return .Invalid_Plan
			}
		}
		switch component.phase {
		case .PnP:
			if !driver_hardware_id_valid(component.hardware_id) || component.run_once_order != 0 {
				return .Invalid_Plan
			}
		case .RunOnce_Component:
			if component.hardware_id != "" ||
			   component.run_once_order == 0 ||
			   component.run_once_order <= last_run_once_order {
				return .Invalid_Plan
			}
			last_run_once_order = component.run_once_order
		}
		if !component.payload_available {content_unavailable = true}
		switch component.package_id {
		case GSW_VGA_PACKAGE_ID:
			vga_found = component.phase == .PnP && component.hardware_id == GSW_VGA_HARDWARE_ID
		case GSW_SOUND_PACKAGE_ID:
			sound_found = component.phase == .PnP && component.hardware_id == GSW_SOUND_HARDWARE_ID
		case GSW_DIRECTX9_RUNTIME_PACKAGE_ID:
			directx_found =
				component.phase == .RunOnce_Component &&
				component.run_once_order == GSW_DIRECTX9_RUNTIME_ORDER
		case GSW_DX9_COMPAT_PACKAGE_ID:
			dx9_compat_found =
				component.phase == .RunOnce_Component &&
				component.run_once_order == GSW_DX9_COMPAT_ORDER
		}
	}
	if !vga_found || !sound_found || !directx_found || !dx9_compat_found {
		return .Invalid_Plan
	}
	if require_payloads && content_unavailable {return .Package_Content_Unavailable}
	return .None
}

driver_delivery_package_manifest :: proc(
	package_id: string,
) -> (
	Driver_Package_Manifest,
	Driver_Package_Diagnostic,
) {
	for component in GSW_DRIVER_DELIVERY_COMPONENTS {
		if component.package_id != package_id {continue}
		if component.phase != .PnP {return {}, .Unsupported_Mode}
		if !component.payload_available {return {}, .Package_Content_Unavailable}
		return {}, .Package_Content_Unavailable
	}
	return {}, .Invalid_Manifest
}
