// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:testing"

@(test)
test_driver_delivery_plan_binds_gsw_pci_ids_without_claiming_payloads :: proc(t: ^testing.T) {
	plan := gsw_driver_delivery_plan()
	testing.expect_value(t, len(plan), 4)
	testing.expect_value(
		t,
		driver_delivery_plan_validate(plan, false),
		Driver_Delivery_Plan_Diagnostic.None,
	)
	testing.expect_value(
		t,
		driver_delivery_plan_validate(plan),
		Driver_Delivery_Plan_Diagnostic.Package_Content_Unavailable,
	)
	vga_found := false
	sound_found := false
	for component in plan {
		if component.package_id == GSW_VGA_PACKAGE_ID {
			vga_found = true
			testing.expect_value(t, component.phase, Driver_Delivery_Phase.PnP)
			testing.expect_value(t, component.hardware_id, GSW_VGA_HARDWARE_ID)
			testing.expect(t, !component.payload_available)
		} else if component.package_id == GSW_SOUND_PACKAGE_ID {
			sound_found = true
			testing.expect_value(t, component.phase, Driver_Delivery_Phase.PnP)
			testing.expect_value(t, component.hardware_id, GSW_SOUND_HARDWARE_ID)
			testing.expect(t, !component.payload_available)
		}
	}
	testing.expect(t, vga_found && sound_found)

	_, vga_diagnostic := driver_delivery_package_manifest(GSW_VGA_PACKAGE_ID)
	_, sound_diagnostic := driver_delivery_package_manifest(GSW_SOUND_PACKAGE_ID)
	testing.expect_value(t, vga_diagnostic, Driver_Package_Diagnostic.Package_Content_Unavailable)
	testing.expect_value(
		t,
		sound_diagnostic,
		Driver_Package_Diagnostic.Package_Content_Unavailable,
	)
}

@(test)
test_driver_delivery_plan_orders_dx9_runtime_before_compat_component :: proc(t: ^testing.T) {
	plan := gsw_driver_delivery_plan()
	run_once_count := 0
	last_order: u16
	for component in plan {
		if component.phase != .RunOnce_Component {continue}
		run_once_count += 1
		testing.expect(t, component.run_once_order > last_order)
		last_order = component.run_once_order
		if run_once_count == 1 {
			testing.expect_value(t, component.package_id, GSW_DIRECTX9_RUNTIME_PACKAGE_ID)
			testing.expect_value(t, component.run_once_order, GSW_DIRECTX9_RUNTIME_ORDER)
		} else if run_once_count == 2 {
			testing.expect_value(t, component.package_id, GSW_DX9_COMPAT_PACKAGE_ID)
			testing.expect_value(t, component.run_once_order, GSW_DX9_COMPAT_ORDER)
		}
		testing.expect(t, !component.payload_available)
	}
	testing.expect_value(t, run_once_count, 2)
}

@(test)
test_driver_delivery_plan_rejects_ambiguous_runonce_order :: proc(t: ^testing.T) {
	plan := GSW_DRIVER_DELIVERY_COMPONENTS
	plan[3].run_once_order = plan[2].run_once_order
	testing.expect_value(
		t,
		driver_delivery_plan_validate(plan[:], false),
		Driver_Delivery_Plan_Diagnostic.Invalid_Plan,
	)
}
