<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Test input control

RETVRN99 can build a GUI-only input pump for repeatable guest input tests. The
normal build does not activate this interface. The pump uses the same bounded
host queue as SDL keyboard and mouse input, so VM scheduling, i8042 and PS/2
behavior, queue telemetry, and presentation timing remain in the test path.
This first scaffold loads one fixed script at startup; it is not a live control
pipe and does not watch or reload the file. Keyboard actions are complete taps
or chords rather than separately timed key-down and key-up events.

Build the test host and its FAT32 sidecar into a disposable directory. Existing
products with matching names, including debug PDBs, may be overwritten:

```powershell
.\scripts\build-test-control.ps1 -OutputDirectory "$env:TEMP\retvrn99-control"
```

Create an input file before launching the host. Commands are scheduled from the
moment the VM first reaches the running state, not from application readiness.
This desktop smoke check waits for Windows, moves and clicks the guest mouse,
then opens Start without host keyboard focus:

```text
wait 60000
mouse 120 80 0
buttons 1
wait 80
buttons 0
wait 1000
key ctrl-escape
```

For a Profile that auto-launches Quake and has its game window ready within 60
seconds, a game-oriented script can continue with:

```text
# Open the Quake console and enter a command without host keyboard focus.
wait 60000
key grave
wait 100
type timedemo
key space
type demo1
key enter
wait 30000
key escape

# Relative PS/2 mouse input and a balanced left-button click.
mouse 20 -8 0
buttons 1
wait 80
buttons 0
wheel -1 0
```

Launch with a separate Profile and the explicit test-control build:

```powershell
& "$env:TEMP\retvrn99-control\retvrn99-control.exe" `
    --start `
    --graphics-trace `
    "--profile-root:$env:TEMP\retvrn99-control-profile" `
    "--control-script:D:\path\to\quake.input"
```

`--control-script` is rejected by an ordinary build and requires an explicit
`--profile-root`. When the option is supplied, physical keyboard and mouse
events do not reach the guest until that host process exits. Emulator hotkeys,
menus, and window controls remain available. This prevents physical and
synthetic held-state from being merged.

The control subset accepts `wait`, `key`, `type`, `mouse`, `buttons`, and
`wheel`. It rejects reset-relative actions, snapshots, state dumps, guest-memory
barriers, resets, and setup automation. A script is also rejected if it exceeds
64 KiB, 4,096 actions, 15 minutes, the mouse bounds, or finishes with a mouse
button held.

Key names include `escape`, `backspace`, `tab`, `enter`, `space`, `grave`,
`slash`, `backslash`, `minus`, `equals`, `comma`, `period`, `semicolon`,
`apostrophe`, `f1` through `f12`, the navigation keys, `ctrl-escape`, and
`ctrl-alt-delete`. Spanish Win9x text controls can use `key underscore-es`.
Applications that interpret physical scan codes through a US key table, such
as the WinQuake console, must use `type _`. `type` emits paced set-1 key taps
for its supported compact US-layout text: letters, digits, `-`, and `_`, with
no spaces. Use `key space` between words.

Mouse buttons are a mask: left is `1`, right is `2`, middle is `4`, and released
is `0`. Any nonzero state must be followed by `buttons 0` in the same script.

The pump retries a due action if the host queue is full and advances only after
the complete action is accepted. Pausing the VM pauses script time. Stop,
restart, reset, freeze, or input-generation exhaustion cancels the remaining
script, and stale queued control actions are discarded by the VM thread.

Completion means every action was accepted into `Shared.input`; it is not by
itself a fence proving that the VM or guest consumed every byte. Keep keyboard
commands paced, especially around BIOS or application state changes. At exit,
the process fails if the script did not complete or any accepted event was
stale, cancelled, pending, or otherwise unreconciled.

At process exit, a control build prints one `control input:` summary. `queued`
counts accepted generation-tagged events, and each queued event must resolve as
`applied`, `stale_dropped`, or `reset_cancelled`; `unresolved` and `pending`
must both be zero for a complete script. `correlated_events` reports applied
events that reached a presented frame and must equal `applied`, while
`correlated_presentations` and the latency fields report the corresponding
presentation samples. With
`--graphics-trace`, the control build retains up to 4,096 cumulative correlation
samples independently of the frame-trace ring and reports exact nearest-rank
p50, p95, and p99 values. Missing correlation or retention overflow makes that
control run fail.
