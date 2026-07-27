# 86Box VGA algorithm notice

The monochrome-attribute and text-underline behaviour of Attribute Controller
10h bit 1 and CRT Controller 14h in `scanout.odin` was derived from:

- 86Box `src/video/vid_ega_render.c`, `ega_render_text`
- 86Box `src/video/vid_ega.c`, the monochrome attribute colour table

Copyright (C) 2008-2025 the 86Box contributors.

Those upstream files are licensed under GPL-2.0-or-later. RETVRN99's Odin
implementation is distributed under GPL-3.0-only, a permitted later version, and
retains this attribution and source provenance.

RETVRN99 masks the underline location to the five bits IBM 2-72 documents.
86Box compares the whole 14h register, which never matches while the
count-by-4 or doubleword bits are set.
