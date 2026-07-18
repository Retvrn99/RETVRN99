<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Optional sampled drive sounds

RETVRN99 can use the Quantum Bigfoot 2110AT and Alps DF354H148F recordings
from the 86Box assets repository. That adapted pack is not included with
RETVRN99: the 86Box assets license identifies its files as property of their
respective owners and does not grant redistribution rights. You must obtain
the assets yourself.

The loader was validated against 86Box assets commit
`f06840ba5cb7cd3d42f1faa7fe418871a3b3be52`. The Bigfoot recordings are by
Toni Riikonen (`Domppari`); the profile entered upstream through
[86Box assets PR #7](https://github.com/86Box/assets/pull/7) and commit
`0fc557406cb37d8b2ea6a628d532c2ee8d219796`.

The Alps source recordings were submitted by Andres del Campo
(`andresdelcampo`) and are licensed CC BY 4.0 in
[RetroDriveSounds](https://github.com/andresdelcampo/RetroDriveSounds).
[The 86Box FDD credits](https://github.com/86Box/assets/blob/main/sounds/fdd/readme.txt)
say Agetian and Domppari edited them and added seek/step-down support. That
adapted set originated in commit `c722e53fcc08b4700f630db6dc7c03fab499a879`;
its missing/corrected samples are in
`ce33831a0ddb35a7e369810140ba466a02647c08`, with additional POST recordings in
`584b06fb54d68b2ee54d85523e5330a989becb73` (POST-only files are not used by
RETVRN99). The exact adapted 86Box files do not carry a clear redistribution
grant for the editors' contributions, so RETVRN99 keeps the entire pack
external.

## Install the external files

Either place the two upstream directories beside the executable:

```text
retvrn99.exe
sounds/
  86box/
    hdd/
      1997 Quantum Bigfoot 2110AT/
        1997_Quantum Bigfoot 2110AT_3600RPM_SPINDLE_SPINUP.wav
        1997_Quantum Bigfoot 2110AT_3600RPM_SPINDLE_RUNNING.wav
        1997_Quantum Bigfoot 2110AT_3600RPM_SPINDLE_SPINDOWN.wav
        1997_Quantum Bigfoot 2110AT_3600RPM_SEEK_1TRACK.wav
    fdd/
      3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks/
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_motor_start.wav
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_motor_loop.wav
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_motor_stop.wav
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_1up.wav
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_1down.wav
        ...the matching up/down pair for every distance through 79...
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_79up.wav
        3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_79down.wav
```

Or set `RETVRN99_86BOX_ASSETS` before starting RETVRN99. It accepts any of:

- The root of a checkout of `86Box/assets` (contains `sounds`).
- The checkout's `sounds` directory directly.
- An 86Box installation root (contains `assets/sounds`).
- A parent containing `sounds/86box` in the executable-adjacent layout above.

For example:

```powershell
$env:RETVRN99_86BOX_ASSETS = 'D:\Emulators\86Box-assets'
.\retvrn99.exe
```

Each profile is all-or-nothing. The HDD profile needs all four Bigfoot files;
the floppy profile needs its three motor recordings and all 158 direction and
distance seek recordings. RETVRN99 reports loaded, incomplete, or missing
status at startup. The Device Sounds test buttons also report the pack as
unavailable when its required files are absent. No procedural clicking is
substituted for missing recordings.

SDL converts valid WAV input to RETVRN99's 48 kHz, signed 16-bit stereo output
before the audio callback starts. Upstream currently supplies 48 kHz signed
16-bit mono PCM, so conversion mainly duplicates the mono channel.

## Playback behavior

The mixer follows the drive-audio state model in 86Box commit
`82c0e7a3ca74da1f52682544d533b58f6665e9bd`:

- Starting the VM plays the Bigfoot spin-up recording, then loops its running
  spindle recording. HDD accesses layer seek recordings only after the spindle
  reaches the running state. Stopping the VM plays spin-down.
- The floppy motor plays start, loop, and stop recordings. Stop crossfades from
  the loop for 75 ms. A seek chooses the Alps recording matching both movement
  direction and track distance, from 1 through 79 tracks.
- Up to eight seek recordings can overlap per drive, matching 86Box's bounded
  voice policy.

The source implementation is GPL-3.0-only. Its state-machine behavior was
adapted from 86Box's GPL-2.0-or-later `hdd_audio.c` and `fdd_audio.c`; no 86Box
source file or recording is vendored.
