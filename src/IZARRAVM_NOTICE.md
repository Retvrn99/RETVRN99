# IzarraVM algorithm notice

Selected PC timing, device, media, audio, and guest-test algorithms are adapted
from IzarraVM commit `d930de57acccbc6a70cda8cc5a603173bf23cd1c`.
IzarraVM is copyright its contributors and licensed GPL-3.0-only. RETVRN99 and
each adapted Odin source file remain GPL-3.0-only.

The relevant upstream areas are:

- `izarravm-core/src/clock.rs`
- `izarravm-machine/src/timeline.rs`, `unittester.rs`, and PC device modules
- `izarravm-machine/src/cdimage.rs`, `atapi.rs`, and `bmide.rs`
- `izarravm-audio/src/` and `izarravm-input/src/`

IzarraVM source is not vendored into RETVRN99. Its software CPU, HLE BIOS,
Margo/Distira devices, and host backend are not used.
