<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Generated-output review locks

Schema v2 records a generated-source review. It is not a component-closure,
build, staging, installation, or capability-activation approval. Those
authorizations are separate immutable `false` fields, including when a lock
reaches `reviewed-generated-source`.

The Mesa 23.1.9 manifest is `reviewed-generated-source`. It binds the two
normalized 67-file roots and exact file-level license evidence for every
output. Generator-input, component, header, depfile, object, and build claims
remain owned by separate artifacts. Review status never grants build, staging,
guest-installation, or capability-advertisement authority.

## Mesa review boundary

The v2 Mesa record binds:

- commit `29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f`;
- the generated-source plan, `GENERATE_FILES` recipe and source seed;
- the 1,363,950-byte Mesa schema-v2 component manifest with SHA-256
  `11020fe9315d80f3ebb14f50266bd50e9f2f2e982c9464c8b0d3d42556fd4f2a`;
- the 4,418-byte proven LF/CRLF reproducibility artifact with SHA-256
  `d37322e969730fb71d2663c19752728802631cb9bd55b3d294824e3ac4ca2f0b`;
- 67 regular output files, 20 directories, 87 total entries and 34,876,554
  aggregate bytes;
- normalized tree SHA-256
  `dd0ae888829eabf2a0043f27100aa64c57b43ad12054270bee62f50ccc451d84`;
- 62 `MIT` outputs, three
  `MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)` outputs, one
  `MIT AND BSD-3-Clause` output and one `MIT AND Apache-2.0` output; and
- 77 exact evidence rows: 58 generated-output locators and 19 canonical
  component-source locators; and
- the four validation-only Bison headers and `tr_util.h` as excluded paths.

The four accepted output expressions are canonical strings. A reviewed lock
uses ordered `license_evidence_ids`. The verifier resolves those identifiers
in declaration order and derives the canonical expression from the evidence;
alternate ordering, spelling, grouping or an unused evidence record fails.
A generated-output evidence row binds the output descriptor and hashes its
whole-file or byte-range locator from the generated root. Component-source
rows bind the source subject, its component-manifest evidence row, and both Git
blob descriptors. The verifier requires `SourceRoot` at the pinned commit and
reads canonical bytes from the exact Git blob IDs, so checkout CRLF conversion
cannot change the evidence. All locator bytes are independently hashed and all
generated files and source blobs are read again at the final stability seam.

The verifier parses the reproducibility artifact after hash-checking it. It
requires two ordered, independently pinned runs with distinct LF and CRLF
identities, distinct non-nested output roots, the exact normalized tree digest,
zero published validation-only side outputs, and false values for every
execution, build, staging, installation, activation, and capability
authorization. The artifact is hash-checked again at the final stability seam.

A blocked lock may leave those arrays empty only while
`file_license_evidence_complete` is false and its non-empty reason identifies
the missing proof.

Schema v1 remains a verifier-only compatibility path for existing fixtures.
It still requires a ready component closure and a clean pinned checkout. It
cannot be used to bypass the v2 status and authorization Interface.

The v2 test Interface accepts `-GeneratedRootLf`, `-GeneratedRootCrlf`, and
`-V2SourceRoot`. Supplied generated roots must be distinct and non-nested, and
the source root must be the pinned Mesa checkout used for canonical Git-blob
evidence. Tests that require external roots report `SKIP` when those arguments
are omitted.

## Canonical tree digest

`retvrn99-file-tree-sha256-v1` is SHA-256 over this byte stream:

```text
UTF8("RETVRN99-WIN98-TREE-SHA256-V1") || 0x00
U64BE(file_count)
U64BE(aggregate_file_bytes)
for each file in ordinal relative-path order:
    U32BE(relative_path_utf8_byte_count)
    UTF8(relative_path)
    U64BE(file_byte_count)
    RAW_SHA256(file_bytes)
```

All integers are unsigned and big-endian. Paths use `/`, are strict UTF-8 and
are ordered with ordinal comparison. `RAW_SHA256` contributes 32 digest bytes.
The verifier independently checks directory and descriptor fields. Its Windows
9x portability check allocates short-name suffixes per directory in ordinal
child order, matching the Generated Source Module.

The fixed two-file vector contains an empty `include/generated.h` and the three
bytes `abc` in `src/generated.c`. Its digest is
`0b2691b4a30d1e1eaa421b9ad14eeb40752cf28b82cf9f613f7cbc9baca196fe`.
