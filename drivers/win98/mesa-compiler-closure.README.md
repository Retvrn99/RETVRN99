<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mesa compiler closure

The Compiler Closure Module records the preparation Seam between reviewed
source selection and a future direct pruned Mesa compile recipe. Schema 1 is
deliberately blocked. It binds the stable source, generated output, original
GSW source, CPU, and toolchain inputs, but it cannot contain compiler commands,
depfiles, headers, or a twin-run descriptor.

A later schema may become a proof only after an original direct recipe binds
every compilation command. Initial discovery against the pinned clean checkout
is non-authoritative. Every referenced project header must first be reviewed
and added to the component closure. The proof then runs the pinned compiler in
dependency-only mode twice against an exact materialized component-closure
root plus the reviewed generated and original GSW roots and the locked
toolchain. It includes toolchain headers, rejects missing headers, normalizes
paths to named logical roots, and requires identical closure descriptors.
Production builds consume the reviewed normalized generated root and never run
the generator toolchain.

All upstream production recipe inputs may remain reference or generator
provenance material, but cannot be direct build inputs. Schema 1 also freezes
the prohibited upstream implementations, backend include paths, and
preprocessor definitions that were present in the upstream multi-backend
recipe. Removing the Module would force those invariants into every future
build and audit caller; keeping them at this Seam provides locality and a small
fail-closed Interface.

Verification is metadata-only. It runs no compiler, generator, linker,
installer, guest, or host mutation and grants no build or delivery authority.
