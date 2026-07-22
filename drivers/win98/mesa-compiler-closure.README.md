<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mesa compiler closure

Schema 3 binds the exact 874-unit direct inventory, 869 compile dispositions,
five support-only generated sources, 1,070 dependency files, and 869 twin
normalized i386 COFF objects. The ready Mesa component closure must contain all
652 upstream dependencies with the `compiler-dependency` role and matching
canonical Git bytes.

The source materializer consumes two distinct clean checkouts of the pinned
Mesa commit. One is configured for LF and the other for CRLF, and at least one
selected LF Git blob must produce distinct LF/CRLF observations. Raw CRLF Git
blobs may remain CRLF in both clean checkouts; at least one raw observation must
match each exact component descriptor before both observations normalize to the
same bytes. The output contains exactly 1,489 canonical-LF upstream files.

Every reviewed generated include root precedes every canonical source include
root. This is required because Mesa9x carries a zero-byte
`src/compiler/nir_builder_opcodes.h` placeholder while the reviewed generator
produces the usable header under `src/compiler/nir/`. The materialized root
still contains all 652 dependency-role files, but compiler evidence observes
651 upstream dependencies plus 29 generated dependencies; the one unobserved
role is that exact generated-shadowed placeholder. The total dependency count
remains 1,070.

The compiler-running collector is explicit. It runs each dependency command
and each compile-only command twice with the pinned i686 compilers, the complete
GSW-886 CPU flags, a stable per-unit `-frandom-seed`, and logical prefix maps.
Each child has a 30-second bound and a pinned-toolchain-only `PATH`. It invokes
no linker. Objects must be bounded IMAGE_FILE_MACHINE_I386 COFF files without
optional headers or bound private roots in ASCII, UTF-8, or UTF-16LE form. Only
`TimeDateStamp` bytes 4 through 7 are zeroed in the hash input.

Compiler children are strictly sequential. After each 25 completed units the
collector releases pending managed process resources and waits one second
before starting the next batch. This is a declared process bound, not a retry:
any failed dependency command, compile, or object parse still aborts the gate
and withholds evidence.

Three selected dispositions require exact compile-context exceptions.
Dependency and object command `cmd-0002` adds `HAVE_PTHREAD` so
`c11/threads.h` exposes the POSIX types used by `threads_posix.c`. Command
`cmd-0792` adds the same definition so `rwlock.c` selects its pthread path
instead of Windows SRW APIs that are unavailable at the locked Windows 98
target level. Command `cmd-0852` adds `USE_X86_ASM` and
`GLX_X86_READONLY_TEXT` so the selected generated `glapi_x86.S` uses the pinned
recipe's PE/COFF-compatible read-only-text path. These definitions are not
global, the vendored winpthreads source and include tree remain excluded, and no
pthread library is linked. This proves only that the selected files compile
against the pinned compiler context. It does not reproduce the complete
upstream Makefile recipe or prove pthread ABI, linking, or runtime compatibility.

Before the first compiler child, exact-source mode rebinds every materialized
file to the ready component descriptor through a distinct clean Git checkout.
This preserves the raw-blob anchor for both LF and CRLF Git blobs while
requiring the materialized bytes themselves to remain canonical LF.

The collector records raw hashes and timestamps, twin normalized hashes,
per-unit sizes, and one ordered aggregate SHA-256. Every object is deleted
immediately after inspection. The two object trees are deleted on success or
failure, and the evidence file is not written until cleanup succeeds.

Ordinary verification is metadata-only. It rebinds all nine inputs, the ready
component dependency roles, exact commands and object identities, normalized
twin hashes, and aggregate digest. Optional external-root verification only
rehashes dependencies. Production build, link, staging, guest installation,
DLL activation, renderer selection, and capability advertisement remain false.
