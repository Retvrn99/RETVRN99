# SPDX-License-Identifier: GPL-3.0-only

param(
    [ValidateRange(1, 64)]
    [int]$ThreadCount = [Environment]::ProcessorCount
)

$output = Join-Path $PSScriptRoot '..\dev\fat32-process-test'
New-Item -ItemType Directory -Force $output | Out-Null

odin build (Join-Path $PSScriptRoot '..\src\fat32_helper') `
    -out:(Join-Path $output 'retvrn99-fat32.exe') `
    -debug `
    -thread-count:$ThreadCount
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Process timing, lock, and memory assertions share host resources and are
# deliberately measured one at a time. Compiler work remains parallel.
odin test (Join-Path $PSScriptRoot '..\src\fat32session') `
    -out:(Join-Path $output 'fat32session-tests.exe') `
    -debug `
    -define:ODIN_TEST_THREADS=1 `
    -thread-count:$ThreadCount
exit $LASTEXITCODE
