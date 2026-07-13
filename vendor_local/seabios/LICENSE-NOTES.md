# Vendored SeaBIOS source

- Upstream: https://github.com/coreboot/seabios
- Release: `rel-1.16.3`
- Commit: `a6ed6b701f0a57db0569ab98b0661c12a6ec3ff8`
- License: LGPL-3.0-only; see `COPYING.LESSER` and `COPYING`.
- RETVRN99 raises the INT 05h entry diagnostic to debug level 2 so a repeated
  bounds exception cannot saturate the firmware debug port in production.
- RETVRN99 configuration and build wrappers live in `tools/seabios/`.
