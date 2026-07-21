<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mesa compiler closure

The Compiler Closure Module records the preparation Seam between reviewed
source selection and a future direct pruned Mesa build. Schema 2 is
evidence-only. It binds the exact 874-unit inventory, the 869 compile
dispositions, five support-only generated sources, exact dependency commands,
twin depfile hashes, and the complete observed dependency set.

The pinned compiler ran every compile disposition twice in dependency-only
mode against an exact 1,489-file materialized root, two byte-identical reviewed
generated roots, original GSW sources, and the locked toolchain. It includes
system headers, rejects missing headers without `-MG`, normalizes paths to four
named logical roots, and requires byte-identical twin depfiles. Production
builds must consume a reviewed normalized generated root and never run the
generator toolchain.

All upstream production recipe inputs may remain reference or generator
provenance material, but cannot be direct build inputs. Schema 2 also freezes
the prohibited upstream implementations, backend include paths, and
preprocessor definitions that were present in the upstream multi-backend
recipe. Removing the Module would force those invariants into every future
build and audit caller; keeping them at this Seam provides locality and a small
fail-closed Interface.

Ordinary verification is metadata-only; optional external-root verification
rehashes all 1,070 observed dependencies. The evidence collector is the only
compiler-running path and bounds every child to ten seconds. Neither path runs
a linker, installer, guest, or product binary. Project-header license review,
object compilation, build, link, staging, installation, activation, and
capability authority remain false.
