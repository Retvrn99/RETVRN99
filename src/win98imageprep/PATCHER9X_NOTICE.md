# patcher9x attribution

The Windows 98 TLB compatibility transformation in this directory adapts the
masked patch signatures, replacement data, W3/W4 container handling, and
DoubleSpace decompression behavior from JHRobotics/patcher9x commit
`b6e30d4b5a396dcd453b6c8e6733fd5b5cbce59e`:

https://github.com/JHRobotics/patcher9x

Only the Windows 98 TLB patch is adapted. RETVRN99 does not incorporate or run
the patcher9x executable, CPU-speed patches, memory-limit patches, control-
register patches, or resource patches.

## Upstream license

Copyright (c) 2022 Jaroslav Hensl

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
