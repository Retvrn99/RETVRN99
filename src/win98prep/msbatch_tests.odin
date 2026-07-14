// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:testing"

@(test)
test_normalize_msbatch_suppresses_component_dialog :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nExpress=1\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nNetwork=1\r\n\r\n[OptionalComponents]\r\nJuegos=0\r\n\r\n[Network]\r\nDisplay=0\r\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "OptionalComponents=0\r\n"))
	testing.expect(t, !contains(normalized, "OptionalComponents=1"))
	testing.expect(t, contains(normalized, "Express=1\r\n"))
	testing.expect(t, contains(normalized, `ProductKey="RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, "ShowEula=0\r\n"))
	testing.expect(t, contains(normalized, "EBD=0\r\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\r\n"))
	testing.expect(t, contains(normalized, "PenWinWarning=0\r\n"))
	testing.expect(t, contains(normalized, "ValidateNetCardResources=0\r\n"))
	testing.expect(t, contains(normalized, "[Install]\r\nAddReg=OPKInstall\r\n"))
	testing.expect(t, contains(normalized, "[OPKInstall]\r\n"))
	testing.expect(t, contains(normalized, `"ProductId",,"12345-OEM-1234567-12345"`))
	testing.expect(t, contains(normalized, `"ProductKey",,"RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, `"RegisteredOwner",,"RETVRN99 User"`))
	testing.expect(t, contains(normalized, `"RegisteredOrganization",,"RETVRN99"`))
	testing.expect(t, contains(normalized, "[OptionalComponents]\r\nJuegos=0\r\n"))
	delete(normalized)
}

@(test)
test_normalize_msbatch_adds_missing_component_setting :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[setup]\nExpress=1\n\n[NameAndOrg]\nName=User\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "ShowEula=0\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\n"))
	testing.expect(t, contains(normalized, "PenWinWarning=0\n"))
	testing.expect(t, contains(normalized, "[NameAndOrg]\n"))
	testing.expect(t, contains(normalized, "[Network]\nComputerName=\"RETVRN99\"\n"))
	testing.expect(t, contains(normalized, "ValidateNetCardResources=0\n"))
	testing.expect(t, contains(normalized, "[Install]\nAddReg=OPKInstall\n"))
	testing.expect(t, contains(normalized, "[OPKInstall]\n"))
	delete(normalized)
}

@(test)
test_normalize_msbatch_preserves_install_actions_and_replaces_opk_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nExpress=1\r\n\r\n[Install]\r\nAddReg=RegistrySettings\r\n\r\n[OPKInstall]\r\nHKLM,Old,Value,,Wrong\r\n\r\n[RegistrySettings]\r\nHKLM,Keep,Value,,Right\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "AddReg=RegistrySettings,OPKInstall\r\n"))
	testing.expect(t, contains(normalized, "[RegistrySettings]\r\nHKLM,Keep,Value,,Right\r\n"))
	testing.expect(t, !contains(normalized, "HKLM,Old,Value,,Wrong"))
	testing.expect(t, contains(normalized, `"ProductId",,"12345-OEM-1234567-12345"`))
}

@(test)
test_normalize_msbatch_replaces_oem_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nPenWinWarning=1\r\n\r\n[NameAndOrg]\r\nName=\"System Recovery\"\r\nOrg=\"Preferred Customer\"\r\n\r\n[Network]\r\nComputerName=RECOVERY\r\nWorkgroup=OEM\r\nDescription=\"System Recovery\"\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, !contains(normalized, "System Recovery"))
	testing.expect(t, !contains(normalized, "Preferred Customer"))
	testing.expect(t, !contains(normalized, "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"))
	testing.expect(t, contains(normalized, `ProductKey="RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, `Name="RETVRN99 User"`))
	testing.expect(t, contains(normalized, `Org="RETVRN99"`))
	testing.expect(t, contains(normalized, `ComputerName="RETVRN99"`))
	testing.expect(t, contains(normalized, `Workgroup="WORKGROUP"`))
	testing.expect(t, contains(normalized, `Description="RETVRN99"`))
}

@(test)
test_normalize_msbatch_inserts_before_dos_eof :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	suffix := "\x1aOEM TRAILER \x80"
	template := "[Setup]\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nPenWinWarning=1\r\n\x1aOEM TRAILER \x80"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	eof := -1
	for index in 0 ..< len(normalized) {
		if normalized[index] == '\x1a' {
			eof = index
			break
		}
	}
	testing.expect(t, eof >= 0)
	if eof >= 0 {
		testing.expect(t, contains(normalized[:eof], "[NameAndOrg]"))
		testing.expect(t, contains(normalized[:eof], "[Network]"))
		testing.expect(t, contains(normalized[:eof], "[OPKInstall]"))
		testing.expect_value(t, normalized[eof:], suffix)
	}
}

@(test)
test_normalize_msbatch_rejects_missing_setup_section :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	normalized, ok := normalize_msbatch("[NameAndOrg]\r\nName=User\r\n")
	testing.expect(t, !ok)
	testing.expect_value(t, normalized, "")
}

@(test)
test_msbatch_time_zone_uses_windows_98_names :: proc(t: ^testing.T) {
	zone, ok := msbatch_time_zone_from_host("Europe/Madrid")
	testing.expect(t, ok)
	testing.expect_value(t, zone, "Romance")
	zone, ok = msbatch_time_zone_from_host("Romance Standard Time")
	testing.expect(t, ok)
	testing.expect_value(t, zone, "Romance")
	_, ok = msbatch_time_zone_from_host("Antarctica/Troll")
	testing.expect(t, !ok)
}
