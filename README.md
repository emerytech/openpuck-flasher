# OpenPuck Flasher

A small personal macOS app to flash the **Couchside OpenPuck fork** onto nRF52840
UF2-bootloader boards (nice!nano etc.) when fulfilling Etsy puck orders — no phone,
no Couchside box needed. It does exactly what the box does: copy a verified `.uf2`
onto the board's bootloader volume.

## Build

```bash
./build.sh
open "build/OpenPuck Flasher.app"
```

Requires Xcode command-line tools (`xcrun swiftc`). Targets macOS 13+.

## Use

1. Launch the app.
2. Put a board in DFU: **double-tap reset** (or short **RST–GND** twice, within ~0.5s).
   A `NICENANO` drive mounts and the app shows **Board ready**.
3. Click **Flash** — or flip **Auto-flash (batch)** on and just keep plugging boards;
   each one flashes on its own, and the session counter ticks up.

The board reboots itself as a **Steam Controller Puck** and the drive disappears —
that's success. Unplug, insert the next.

## Firmware

- **Pinned 0.9.40** (default) — `OpenPuck-0.9.40-standard.uf2`, sha256-verified before
  every write. Downloaded once from the fork release and cached in
  `~/Library/Application Support/OpenPuck Flasher/`.
- **Latest fork** — the newest `*-standard.uf2` from `emerytech/openpuck` releases
  (size + UF2 magic checked).
- **Local file** — pick your own `.uf2` (handy when testing a new fork build before
  pinning it).

Every path verifies the file is a real UF2 of sane size before a single byte is written.

## First-run notes

- First flash, macOS may ask to allow access to a **removable volume** — click Allow.
- Because it's ad-hoc signed, the first launch may need **right-click → Open**.

## Source of the firmware

OpenPuck is a separate AGPL-3.0 project (safijari, forked by EmeryTech). This app only
downloads a released build and copies it to the board; it embeds no OpenPuck source.
Fork + releases: https://github.com/emerytech/openpuck
