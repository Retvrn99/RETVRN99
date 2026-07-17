# IzarraVM algorithm notice

Selected PC timing, device, media, audio, video, and guest-test algorithms are
adapted from IzarraVM commits `d930de57acccbc6a70cda8cc5a603173bf23cd1c`
and `b88a9fe68a8109f26632ff2802262cc38a6a5ad9`.
IzarraVM is copyright its contributors and licensed GPL-3.0-only. RETVRN99 and
each adapted Odin source file remain GPL-3.0-only.

The relevant upstream areas are:

- `izarravm-core/src/clock.rs`
- `izarravm-machine/src/timeline.rs`, `unittester.rs`, and PC device modules
- `izarravm-machine/src/cdimage.rs`, `atapi.rs`, and `bmide.rs`
- `izarravm-audio/src/` and `izarravm-input/src/`
- `izarravm-video/src/vga/{datapath,scanout,legacy,timing}.rs`
- `izarravm/src/crt.rs`

IzarraVM source is not vendored into RETVRN99. Its software CPU, HLE BIOS,
Margo/Distira devices, and host backend are not used.
