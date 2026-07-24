<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Synthetic 60 Hz host-presentation proof

`tools/presentation-60hz-proof` is a test-only producer for the host graphics
presentation path. It creates a synthetic GSW2D snapshot surface at the requested
extent, performs one full warmup upload, and then updates a moving 64 by 64 dirty
region at a fixed 60 Hz cadence.

The tool calls the same host functions as the application:

1. `host_presentation_admit_gsw`
2. `host_presentation_stage_gsw_snapshot`
3. `host_presentation_commit_gsw_snapshot_staged`
4. `host_render_guest`
5. `SDL_RenderPresent`

This is not an SDL texture microbenchmark. The measured interval traverses the
production admission, persistent streaming-texture upload, composition, and
present operations. Missed cadence slots are skipped. They are never recovered
with burst presents.

`pipeline_ns` is the reference-host cost metric. It begins immediately before
host admission and ends after `SDL_RenderPresent` returns, so it includes
admission, staging, commit, composition, and present. `present_ns` retains the
`SDL_RenderPresent` portion separately but is not substituted for the roadmap
gate.

The fixed gate requires all of the following:

- the renderer output exactly matches the requested extent;
- renderer vsync is active;
- at least 55.000 presented frames per second over the bounded stable interval;
- nearest-rank `pipeline_ns` p95 strictly below 4,000,000 ns at 1024x768 or
  strictly below 8,000,000 ns at 1920x1080;
- every stable frame uses a partial GSW snapshot update and persistent texture
  reuse;
- no stable resource recreation, full-upload fallback, readback, descriptor copy,
  pixel conversion, rejection, or stale finalization occurs;
- every present has a retained schedule, start, completion, pipeline-duration,
  and `SDL_RenderPresent`-duration sample;
- presented plus skipped cadence slots exactly equals `stable_seconds * 60`,
  including any trailing slots lost to a long final present;
- the fixed 4096-sample buffer does not overflow.

Only the two named reference extents are accepted. Neither the target rate,
minimum rate, cost metric, nor p95 limit is configurable. Warmup is bounded to
1 through 10 seconds, and the measured interval is bounded to 5 through 60
seconds. The longest interval retains at most 3600 cadence slots.

## Reference command

Run the reviewed wrapper from PowerShell with an existing ordinary run root
outside the repository and a new direct evidence child:

```powershell
& .\scripts\run-presentation-60hz-proof.ps1 `
    -Width 1024 `
    -Height 768 `
    -WarmupSeconds 2 `
    -StableSeconds 10 `
    -RunRoot C:\tmp\retvrn99-phase2-runtime-019f8c7e8243\final-acceptance-1 `
    -EvidenceRoot C:\tmp\retvrn99-phase2-runtime-019f8c7e8243\final-acceptance-1\reference-1024x768
```

Repeat with `-Width 1920`, `-Height 1080`, and a distinct absent evidence child
for the second reference-host gate.

The wrapper rejects UNC, alternate-data-stream, reparse-point, relative,
existing, nested, and repository-overlapping evidence paths. Before building,
it records Git and toolchain identity plus hashes for every file under `src`,
the compiled assets, the complete proof tool, its wrapper, support, tests,
documentation, the Odin SDL3 bindings, and `SDL3.dll`. It rechecks that identity
before launch and after the run.

The wrapper builds an optimized standalone executable, copies the bound
`SDL3.dll`, captures stdout and stderr, strictly parses the marked JSON result,
and independently recomputes cadence, frame rate, every sample duration,
nearest-rank summaries, stable host metrics, and the p95 gate. It writes a
success manifest only after all checks pass. Build failure, process failure,
timeout, malformed output, source drift, or a failed gate exits nonzero with
captured logs and a failure manifest retained in the owned evidence child.
Process output is drained through independent 64 MiB stdout and stderr bounds;
an overflow retains only the bounded prefix and fails the run.

## Scope boundary

This proof does not boot a guest, attach media, access a profile, exercise the
frame mailbox or guest scanout producer, validate a Win98 driver, or authorize a
graphics capability. It does not change fullscreen state or a host display mode.
It proves only the synthetic host presentation/upload/render/present slice named
in the evidence. Guest and workload acceptance remain separate gates.
