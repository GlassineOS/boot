# Feature Specification: Boot splash and its one-time override

**Feature branch:** `boot-splash`
**Status:** spec; partly built: the loader reads and draws the store and the override
(GlassineOS/loader), `glassine-boot-raw` writes the raw form's regions, and
`glassine-splash-store` writes and removes the override; setting the splash from a
picture is not built
**Builds on:** [010-uefi-deployments](../010-uefi-deployments/spec.md) (the loader on a
PC) · **Interfaces:** [docs/boot.md](../../docs/boot.md)

## Summary

The running system places an image where the earliest stage of the boot chain can draw
it. That stage shows it as soon as it owns the display, and every later stage leaves it
on screen until the system draws. A default ships; the system can set another.

Next to it there is a one-time override: one image that is shown at the next start in
place of the splash, and is gone after it was shown once.

What the images show is the system's choice. One use of the override: before it
hibernates, the system may put a picture of its screen there, so the next start shows
that picture long before the resume is done. Another: a shutdown screen on a bistable
display that must stay through the next start (GlassineOS/shell 009): the cold shutdown
writes the instruction to leave the screen as the override where the shell left
`/run/glassine/screen-keep`.

This spec is the same for every machine. A machine's own spec says which stage is its
earliest and where that stage reads the images (a PC: the loader and the boot partition,
010 FR-048).

## Terms

| Term | Meaning |
|---|---|
| earliest stage | The first stage of a machine's boot chain that owns the display and that GlassineOS provides or configures. |
| splash store | The place the earliest stage reads images from. |
| splash | The image shown at every start: the one the system set, or the default. |
| override | One image, or the instruction to leave the screen as it is, for the next start only. |
| bistable display | A display that keeps its last image without power (e-ink). |

## User scenarios

### Scenario 1 – The splash from the first moment (P1)

**Given** a splash the system set,
**When** the machine starts,
**Then** the earliest stage draws it, and it stays, with no blank frame, until the system
draws. The only text over it is the earliest stage's own line naming the recovery key
(FR-016a), and the picture under that line comes back when the line goes.

### Scenario 2 – An override is shown once (P1)

**Given** an override in the store,
**When** the machine starts,
**Then** the earliest stage shows it in place of the splash, and it stays until the
system draws. At the start after that, the splash is shown again and the store holds no
override.

### Scenario 3 – A bad image never costs a start (P1)

**Given** a splash or an override that is cut, damaged, too large or of another format,
**When** the machine starts,
**Then** the image is skipped: the default splash, or nothing, is shown, and the start
goes on without delay.

### Scenario 4 – A paper display keeps its picture (P2)

**Given** a bistable display that shows a picture the system drew before it went off,
and an override that says to leave the screen,
**When** the machine starts,
**Then** no stage clears or redraws the display before the system does.

## Requirements

### The splash

- **FR-001** The earliest stage draws the splash as soon as it owns the display, before
  it starts the next stage and before any wait it makes.
- **FR-002** A default splash ships with the release, as part of what the earliest stage
  is installed with. It is used when no splash is set or the set one is skipped.
- **FR-003** The running system sets and removes the splash, and writes and removes an
  override, through one command (`glassine-splash-store`). The command converts a
  picture into the store's format, for the display mode the earliest stage uses, and
  writes the result. The earliest stage never reads a file in any other format.
- **FR-004** The store's format is one lossless raster format with fixed, small
  decoders, plus a header: format version, width, height, the display mode it was made
  for, a pixel layout, a compression, a filter, a background colour, a checksum. The
  layouts are grey (one byte a pixel), RGB (three) and BGRx (four); the compressions are
  none, run-length and LZ4; the filter is none or each row less the row above. An image
  is at most as large as the display's native mode, at most 8,388,608 pixels, and at
  most 32 MiB.
- **FR-004a** The earliest stage reads every layout with every compression and filter,
  and the store's earlier format 1. Writers choose per picture: the layout for the
  display (grey for a grey panel), and the smallest payload, or, where the write must be
  fast (the hibernate step's picture of the screen), LZ4 without the filter.
- **FR-005** The earliest stage draws an image only after its header, its length and its
  checksum check. An image that fails is skipped (Scenario 3). Reading and checking an
  image has a time limit; past it, the image is skipped.

### Drawing when the display mode differs

- **FR-006** An image made for the mode the earliest stage is in is drawn pixel for
  pixel.
- **FR-007** A splash made for another mode is scaled to fit with its aspect ratio kept,
  centred, and the rest of the screen is filled with its background colour. It is never
  stretched and never drawn with a wrong line length. A stage that can't scale centres
  it when it fits, and otherwise shows the default or nothing.
- **FR-008** An override made for another mode is not shown; the splash is shown
  instead. The override is still used up (FR-012).
- **FR-009** The system can read the mode the earliest stage used at this start (size,
  pixel layout, rotation of the panel) and makes images for it. Images are stored as the
  panel scans them, already rotated and already scaled for the panel's density; the
  earliest stage draws pixels and knows neither rotation nor scale.
- **FR-010** With several displays, the earliest stage draws on every display it owns.
  The splash is drawn on each (FR-006, FR-007). An override holds one picture per
  display and is shown only when the displays the stage owns are the ones it was made
  for.

### The one-time override

- **FR-011** The store holds at most one override. Writing a new one replaces it.
- **FR-012** The earliest stage reads the override, removes it from the store, durably,
  and only then draws it. So an override is shown at one start at most. If the stage
  can't remove it, it doesn't draw it and shows the splash.
- **FR-013** The override is used up by the next start whatever that start leads to (the
  system, a kernel on trial, the recovery, a choice the person makes at start-up). The
  earliest stage doesn't judge whether the picture fits the start; when and what to
  write is the system's.
- **FR-014** An override is either an image or the instruction to leave the screen as it
  is. With that instruction, the earliest stage draws nothing at that start, and
  FR-016 applies to what the display already shows.
- **FR-015** The running system removes an override it finds at its start that the
  earliest stage didn't use up (a stage that can't write the store).

### The hibernate picture

- **FR-024** Before it hibernates, the hibernate step makes a picture of the screen as it
  is the override: the running session's picture of its first display, upright and in the
  display's pixels (GlassineOS/shell 010), written as an image for the display mode of
  the picture's size, grey or RGB as the picture is, compressed for speed (FR-004a). The
  step knows nothing of what the screen shows; it is the same on every machine and
  every display.
- **FR-025** The picture is taken and written before the machine's own hibernate steps
  run, so it shows the session and nothing those steps draw.
- **FR-026** Taking and writing the picture each have a time limit. A picture that
  can't be taken (no session, no copy of the screen) or written (no store, a full store,
  a failed write) changes nothing else: the hibernate goes on, without an override.
- **FR-027** Once the kernel returns, resumed or refusing, or the hibernate is cancelled,
  the step removes the override again: the start of a resume has already used it up
  where the earliest stage draws, and no later start may show an old screen. The
  earliest stage shows a picture made for another mode as FR-008 says: not at all.
- **FR-028** A setting of the system turns the picture off; then the hibernate writes
  no override.

### Keeping the picture on screen

- **FR-016** From the earliest stage's drawing to the system's first frame, no stage
  shows another frame, clears the screen, writes text over it or shows a cursor: not the
  earliest stage after drawing (apart from FR-016a), not the kernel when it takes the
  display over, not the initramfs. Where a display driver must set the mode again and
  the machine can't avoid a blank, the blank is as short as the machine allows and is
  the only change.
- **FR-016a** The earliest stage may show one line naming its recovery key over the
  splash or the override, for its wait only (about two seconds). When the wait ends, it
  restores the picture under the line pixel for pixel. A key press opens that stage's
  own list over the picture; from then on, that start keeps no picture on screen.
- **FR-017** Messages go to the kernel log. They come to the screen when a start fails,
  when the person asks with a key, and in developer mode.
- **FR-018** On a bistable display, no stage GlassineOS provides or configures clears the
  panel or runs a full refresh except to draw the splash or an override image. A machine
  whose closed earlier stage draws on the panel says so in its description.

### Safety of the store

- **FR-019** An image is written under a temporary name, synced, checked by reading it
  back, and only then given its name. Where the store can't replace a file in one step,
  the old image is removed first. A cut write leaves the old image, the new one or
  none, never a half one. FR-005 catches what is left.
- **FR-020** A write to the store follows the store's own rules on the machine (on a PC:
  010 FR-026 to FR-029). The store's size includes room for one splash and one override
  of the largest size. Images never take room from what a start needs: when the store
  is short, the write is refused with a message, and nothing else is removed for it.
- **FR-021** The store is not mounted while the machine hibernates or is off: the
  earliest stage writes it at the next start (FR-012), and a system that resumes must
  hold no older view of it.
- **FR-022** No image, missing, damaged or hostile, changes what the boot chain starts
  or how long it waits, beyond the time limit of FR-005. A failed write of an image
  never fails or delays the shutdown, restart or hibernate it was made for.
- **FR-023** The recovery (008) draws its own screen. It writes no image to the store.

## Key entities

- **The splash store**: the machine's place for these images, with its format version.
- **An image**: header and picture (FR-004). One image holds one picture.
- **The override**: an image for each display it was made for, or the instruction to
  leave the screen. The store's format holds one image a file, so an override is made
  for one display.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The store's image format | owned (new); read by each machine's earliest stage | `format=2` (readers also read `format=1`) | `docs/boot-partition.md`, "The image format" |
| The store's names on a PC | owned (new) | part of the boot partition's layout | `docs/boot-partition.md`, "The splash store" |
| The store on a device without FAT | owned (new); the regions `splash-default`, `splash`, `override` of the boot partition's raw form | region table `format=1` | `docs/boot-partition.md`, "The raw form" |
| The command that sets and removes the splash and the override | owned (new); used by the settings, the session, the cold shutdown and the hibernate step | — | `docs/boot.md`, "The splash store" |
| The earliest stage's display mode, readable by the running system | owned (new) | — | to be added to `docs/boot.md` |
| The earliest stage on a PC | owned | — | 010 FR-048 |

## Device scope and risk

- **Writes:** the splash store only. On every machine that is the boot partition
  (`glassine-boot`): on a PC its FAT form under 010's rules; on a machine whose firmware
  has no FAT driver, three regions of its raw form, each image no larger than its region
  (FR-020), replaced by the region write of `docs/boot-partition.md`, which keeps FR-012's
  order: the override's header is cleared and flushed before it is drawn.
- **Never:** a start that depends on an image. A boot chain stage that GlassineOS
  doesn't provide or configure is not changed for this; on such a machine the splash
  starts at the first stage GlassineOS owns.
- **Escape:** removing the images from the store returns the machine to the default
  splash or none.

## Edge cases

- **Power cut while an image is written:** FR-019. The old image, or none.
- **Power cut after the override was removed and before it was drawn:** the override is
  gone and was never shown. The next start shows the splash.
- **Store full:** FR-020. The write is refused; starts are unchanged.
- **The earliest stage can't write the store:** no override is ever shown (FR-012); the
  system removes it (FR-015). The splash works.
- **Display mode changed since the image was made** (another monitor, a docked laptop):
  FR-007 for the splash, FR-008 for an override.
- **Several displays, some not owned by the earliest stage:** they stay as the firmware
  left them until the system draws.
- **A rotated panel, a high-density display:** FR-009.
- **A lid closed, or no display:** nothing is drawn; nothing else changes.
- **An override written before a hibernate, and the start doesn't resume:** the picture
  is shown at that start all the same (FR-013), and the system's first frame replaces
  it.

## Success criteria

SC-001 to SC-007 are tests in QEMU with OVMF. The frame is captured from the machine's
display at the earliest stage and at fixed points after it.

- **SC-001** With a splash set, the first captured frame after the firmware's own is the
  splash, pixel for pixel, apart from the key line of FR-016a during the wait; every
  frame after the wait up to the system's first is the splash, pixel for pixel: no
  text, no blank frame, no cursor.
- **SC-002** With an override written: at the next start every captured frame up to the
  system's first is the override (apart from the key line of FR-016a during the wait). After that start the store holds no override, and
  the start after it shows the splash.
- **SC-003** With an override written and the power cut at each point of the start that
  shows it: the override is shown at one start at most.
- **SC-004** The disk is snapshotted after every write of setting a splash and of
  writing an override. Every snapshot starts, and shows the old image, the new one, the
  default or nothing; never a part of one.
- **SC-005** A splash and an override that are cut short, carry a wrong checksum, claim
  a size beyond the limits or are of another format: each start shows the default
  splash and takes no longer than the limit of FR-005 more than a start without them.
- **SC-006** A splash made for another mode is centred with its aspect ratio kept on a
  background of its colour. An override made for another mode is not shown and is gone
  after the start.
- **SC-007** With the store full, writing an override is refused, the hibernate or
  shutdown it was written for goes on, and the next start shows the splash.
- **SC-008** On a device with a bistable display whose earlier stages leave the panel
  alone, with the person's go: with the instruction to leave the screen, a camera sees
  no white flash and no refresh between power-on and the system's first update.
- **SC-009** On a real PC, with the person's go: SC-001 and SC-002 by camera, with at
  most the one mode-set blank of FR-016.
- **SC-010** In QEMU with OVMF, an override as the hibernate step writes it (a whole
  screen of the display mode, RGB, compressed for speed) is drawn at the next start
  pixel for pixel, and the start after it shows the splash.
- **SC-011** On the host: the hibernate step writes the override before the machine's
  own steps and removes it once the kernel returns or the hibernate is cancelled; a
  picture tool or store that fails or hangs past its time limit leaves the hibernate
  going on with no override.

## Assumptions

- A machine's earliest stage and its store are named by that machine's own spec.
- The store is not encrypted on any machine today.

## Out of scope

- What the splash and the override show, and when the system writes an override apart
  from the hibernate picture (FR-024 to FR-028): a shutdown screen kept through the next
  start is the session's and the shutdown's own work.
- Animations, progress bars and text on the splash.
- The firmware's own logo before the earliest stage.
- The settings page that picks the picture.
