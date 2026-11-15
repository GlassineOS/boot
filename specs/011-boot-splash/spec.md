# Feature Specification: Boot splash and resume preview

**Feature branch:** `boot-splash`
**Status:** spec, for review; nothing built
**Builds on:** [001-deployments](../001-deployments/spec.md) (the hibernation rules),
[010-uefi-deployments](../010-uefi-deployments/spec.md) (the loader on a PC) ·
**Interfaces:** [docs/boot.md](../../docs/boot.md) (the hibernation step, the hibernate
guard), [docs/deployments.md](../../docs/deployments.md) (the guard's format) ·
**Decision:** docs
[0006](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0006-data-encryption.md)
(the person's data is encrypted; the system and the boot partition are not)

## Summary

The running system places an image where the earliest stage of the boot chain can draw
it. That stage shows it as soon as it owns the display, and every later stage leaves it
on screen until the session draws. The person picks the image; a default ships.

Next to it there is a one-time override: one image for the next start only. The system
writes it right before it hibernates, as a picture of what the screen will show right
after the resume. The start that resumes shows it from the earliest stage, so the
person sees the resumed state long before the resume is done, and the session then
takes over without a visible change.

On a display that keeps its image without power, the display itself is the override:
the system draws the picture before it hibernates, and no stage clears it before the
session draws.

This spec is the same for every machine. A machine's own spec says which stage is its
earliest and where that stage reads the images (a PC: the loader and the boot partition,
010 FR-048).

## Terms

| Term | Meaning |
|---|---|
| earliest stage | The first stage of a machine's boot chain that owns the display and that GlassineOS provides or configures. |
| splash store | The place the earliest stage reads images from. Not encrypted on any machine today. |
| splash | The image shown at every start. Set by the system for the person, or the default. |
| override | One image for the next start only. |
| resume preview | An override that shows the screen as it will be right after a resume. |
| hibernation token | A value made new at every hibernate. It is in the hibernate guard and in the override, and ties the two together. |
| bistable display | A display that keeps its last image without power (e-ink). |

## User scenarios

### Scenario 1 – The person's picture from the first moment (P1)

**Given** a person who picked a boot picture in the settings,
**When** the machine starts,
**Then** the earliest stage draws that picture, and it stays, with no text over it and
no blank frame, until the login screen or the session draws.

### Scenario 2 – A resume shows its result at once (P1)

**Given** a machine that hibernated, with a resume preview written,
**When** it starts,
**Then** the earliest stage draws the preview in place of the splash. The resume runs
behind it. When the session draws its first frame, the screen doesn't change in a way
the person can see.

### Scenario 3 – A preview is never shown for another start (P1)

**Given** a resume preview in the store,
**When** the start is not a resume of the hibernation it was made for (a fresh boot, a
cancelled image, a kernel trial, the recovery, a deployment chosen at start-up),
**Then** the preview is not shown where the earliest stage can tell, and is replaced by
the splash at once by the first stage that can. Either way it is gone after that start.

### Scenario 4 – A paper display keeps the picture (P1)

**Given** a machine with a bistable display,
**When** it hibernates,
**Then** the system draws the preview on the display as its last step. While the machine
is off, the display shows it. At the next start no stage clears or redraws the display
before the resumed session does.

### Scenario 5 – Nothing private is left readable (P1)

**Given** a machine whose session locks when it hibernates,
**When** the store is read from outside (the disk in another computer),
**Then** it holds no picture of the person's unlocked session: not as a file, and not
as the remains of an erased one, as far as the medium allows.

### Scenario 6 – A bad image never costs a start (P1)

**Given** a splash or an override that is cut, damaged, too large or of another format,
**When** the machine starts,
**Then** the image is skipped: the default splash, or nothing, is shown, and the start
goes on without delay.

## Requirements

### The splash

- **FR-001** The earliest stage draws the splash as soon as it owns the display, before
  it starts the next stage and before any wait it makes.
- **FR-002** A default splash ships with the release, as part of what the earliest stage
  is installed with. It is used when no splash is set or the set one is skipped.
- **FR-003** The running system sets the splash through one command, which the settings
  use. It converts the picture the person picked into the store's format, for the
  display mode the earliest stage uses, and writes the result. The earliest stage never
  reads a file the person supplied directly.
- **FR-004** Setting the splash tells the person that the picture is stored where it can
  be read without their password. Removing it returns to the default.
- **FR-005** The store's format is one lossless raster format with a fixed, small
  decoder, plus a header: format version, width, height, the display mode it was made
  for, a background colour, a checksum. An image is at most as large as the display's
  native mode, and at most 32 MiB.
- **FR-006** The earliest stage draws an image only after its header, its length and its
  checksum check. An image that fails is skipped (Scenario 6). Reading and checking an
  image has a time limit; past it, the image is skipped.

### Drawing when the display mode differs

- **FR-007** An image made for the mode the earliest stage is in is drawn pixel for
  pixel.
- **FR-008** A splash made for another mode is scaled to fit with its aspect ratio kept,
  centred, and the rest of the screen is filled with its background colour. It is never
  stretched, cropped to nonsense or drawn with a wrong line length. A stage that can't
  scale centres it when it fits, and otherwise shows the default or nothing.
- **FR-009** An override made for another mode is not shown. The splash is shown
  instead.
- **FR-010** The system records the mode the earliest stage used at this start (size,
  pixel layout, rotation of the panel) and makes images for it. Images are stored as the
  panel scans them, already rotated and already scaled for the panel's density, so the
  earliest stage neither rotates nor scales a preview.
- **FR-011** With several displays, the earliest stage draws on every display it owns.
  The splash is drawn on each (FR-007, FR-008). A preview is shown only when the
  displays the stage owns are the ones it was made for; it holds one picture per
  display. Otherwise the splash is shown.

### The one-time override

- **FR-012** The store holds at most one override. It is used for one start and never
  again.
- **FR-013** The earliest stage marks the override used, durably and in one step, before
  it draws it. If it can't, it doesn't draw it and shows the splash.
- **FR-014** An override carries what it is for. A resume preview carries the hibernation
  token and where the hibernation image's signature is on storage.
- **FR-015** The earliest stage shows a resume preview only on an ordinary start: not on
  a kernel trial, not when the recovery starts, not when the person made a choice at
  start-up (another kernel, another deployment, the recovery key). On those starts it
  marks the override used and shows the splash.
- **FR-016** Where the earliest stage can read the storage that holds the hibernation
  image, it checks that an image is there (the signature, one block) before it shows
  the preview. No image: the override is marked used and the splash is shown.
- **FR-017** The initramfs learns from the earliest stage whether a preview is on screen
  and which token it carried. It keeps the preview only when the hibernation step
  resumes (001 Story 4) and the guard's token is the same. In every other case it draws
  the splash over the preview before it does anything else that takes time.
- **FR-018** The hibernate guard gains the token as a key. A guard without it resumes
  as before, with no preview kept.
- **FR-019** The running system removes an override whenever the hibernation it belongs
  to ends or is given up: after the resume, when the kernel returns from a refused
  hibernate, and in every command that cancels a hibernate image
  (`glassine-deploy hibernate-invalidate`, `--discard-hibernation`).
- **FR-020** Every start of the running system that finds an override, used or not,
  erases it (FR-029). A resumed session erases its own after its first frame.

### The resume preview

- **FR-021** The hibernate step writes the preview before it writes the guard and before
  it hibernates. The session supplies the picture: the frame it will draw first after
  the resume.
- **FR-022** The preview leaves out what will have changed by the resume (the clock, the
  battery level, the network state), or shows those places empty, so the first real
  frame only adds to it.
- **FR-023** A preview that can't be made or written (no room, a store that can't be
  written, no picture from the session in time) is left out. The hibernate goes on. The
  preview's work has a time limit, and it never fails or delays a hibernate past it.
- **FR-024** From the preview to the session's first frame, no stage shows another
  frame, clears the screen, writes text over it or shows a cursor: not the earliest
  stage after drawing, not the kernel when it takes the display over, not the
  initramfs. Where a display driver must set the mode again and the device can't avoid
  a blank, the blank is as short as the device allows and is the only change.
- **FR-025** The same holds for the splash on an ordinary start, up to the login screen
  or the session. Messages go to the kernel log. They come to the screen when a start
  fails, when the person asks with a key, and in developer mode.
- **FR-026** A resume that fails after the preview was shown (an image that doesn't load)
  goes on as the ordinary start 001 defines, with the splash drawn first (FR-017).

### Privacy

- **FR-027** The store is readable without the person's password. Nothing is written to
  it that the person's locked machine wouldn't show to anyone in front of it.
  [NEEDS CLARIFICATION: what a preview may show. Recommendation: the session locks when
  it hibernates, and the preview is the lock screen, which is what the person sees
  after the resume anyway. A preview of the unlocked desktop is made only on a machine
  whose session is set not to lock, and only after the person switched it on, with the
  same notice as FR-004. It is never the default.]
- **FR-028** A lock-screen preview carries no notification text, no name and no picture
  of another person's account beyond what the lock screen shows to anyone.
- **FR-029** Erasing an override means: its content is overwritten in place, synced,
  the file removed, and the freed space discarded where the storage supports it. The
  earliest stage only marks an override used (a rename); the erasing is the running
  system's (FR-019, FR-020), so the name is still there to overwrite.
- **FR-030** The documentation says what erasing reaches. On a FAT store the overwrite
  goes to the same clusters, so the file system keeps no copy. Flash storage may keep
  the old blocks inside the drive until it reuses them; discard asks it to drop them and
  doesn't prove it. So FR-027 is the protection, and FR-029 only shortens the time.

### Bistable displays

- **FR-031** On a bistable display the hibernate step has the session draw the preview
  on the display itself, completely, as the last screen update before the hibernate.
  No override is written to the store for it.
- **FR-032** On such a machine no stage drives the display on a start before the
  initramfs's hibernation step has decided. On a resume nothing drives it until the
  session does. Otherwise the initramfs draws the splash then. No stage clears the panel
  to white or runs a full refresh first.
- **FR-033** The session's first update after the resume starts from the picture that
  is on the panel: it knows the preview it drew and updates only what differs.
- **FR-034** FR-027 and FR-028 hold for the panel as for the store: a machine that is
  off shows only what its lock screen would.
  [NEEDS CLARIFICATION: a hibernated machine with a bistable display looks switched on.
  Should the picture say that it is off? Recommendation: yes, one small mark on the
  preview ("press the power key"), which the first update after the resume removes. It
  costs one small partial update and saves the person a wait for a touch that never
  answers.]
- **FR-035** A start that is no resume, on a bistable display, shows the splash from the
  first stage allowed to drive the display (FR-032); the splash rules above apply to
  that stage.

### Safety of the store

- **FR-036** An image is written under a temporary name, synced, checked by reading it
  back, and only then given its name in one step. A cut write leaves the old image or
  none, never a half one. FR-006 catches what is left.
- **FR-037** A write to the store follows the store's own rules on the machine (on a PC:
  010 FR-027 to FR-029). The store's size includes room for one splash and one override
  of the largest size. Images never take room from what a start needs: when the store
  is short, the override is left out first, then the splash is refused, with a message.
- **FR-038** No image, missing, damaged or hostile, changes what the boot chain starts
  or how long it waits, beyond the time limit of FR-006.
- **FR-039** The recovery (008) draws its own screen and takes no splash and no
  override. It leaves a used override for the next running system to erase.

## Key entities

- **The splash store**: the machine's place for these images, with its format version.
- **An image**: header and picture (FR-005).
- **The override**: an image plus its purpose, the hibernation token, where the
  hibernation image's signature is, one picture per display, and its state (new or
  used).
- **The hibernation token**: in the override and in the hibernate guard.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The store's image format and names | owned (new); read by each machine's earliest stage | `format=1` | to be added to `docs/boot.md` |
| The command that sets and removes the splash | owned (new); used by the settings | exit codes as `glassine-hibernate` | to be added to `docs/boot.md` |
| What the earliest stage hands to the initramfs (preview shown, token) | owned (new); device-neutral | a command-line key | `docs/boot.md` |
| The token key in the hibernate guard | owned (added key) | guard unchanged otherwise | `docs/deployments.md` |
| The session's part: the frame for the preview, drawing it on a bistable display, the first update after the resume | consumed; the session and the display engine provide it | — | their repositories |
| The earliest stage on a PC | owned | — | 010 FR-048 |

## Device scope and risk

- **Writes:** the splash store only. On a PC that is the boot partition, under 010's
  rules. On a bistable display, the panel.
- **Never:** a start that depends on an image. A boot chain stage that GlassineOS
  doesn't provide or configure is not changed for this; a machine whose earliest
  drawing stage is closed starts its splash at the first stage GlassineOS owns.
- **Escape:** removing the images from the store returns the machine to the default
  splash or none.

## Edge cases

- **Power cut while the override is written:** FR-036. No override; the next start shows
  the splash.
- **Power cut after the override and before the hibernation image is complete:** the
  next start is a fresh boot. Where FR-016 applies the preview isn't shown. Elsewhere it
  is on screen until the initramfs's hibernation step, then replaced (FR-017). It is a
  lock screen (FR-027).
- **The hibernation image is cancelled at the start** (the data partition was mounted in
  between, another kernel build, another deployment): the signature is still there, so
  the preview is shown, and the initramfs replaces it with the splash when it cancels.
- **Store full:** FR-023 and FR-037. The machine hibernates without a preview.
- **The earliest stage can't write the store:** no override is ever shown (FR-013). The
  splash works.
- **Display mode changed since the image was made** (another monitor, a docked laptop):
  FR-008 for the splash, FR-009 for a preview.
- **Several displays, some not owned by the earliest stage:** they stay as the firmware
  left them until the session draws.
- **A rotated panel or session:** FR-010. The picture is stored as the panel scans it.
- **A high-density display:** FR-010. The earliest stage draws pixels; it knows no scale.
- **A lid closed, or no display:** nothing is drawn; nothing else changes.
- **A bistable display whose picture was disturbed while off** (pressure marks, a
  partial fade): the session's first update after the resume may be a full one when the
  device's engine asks for it.
- **A bistable display and a start that isn't the expected resume:** FR-032; the lock
  picture stays until the initramfs draws the splash.
- **Two people, one machine:** the splash is the machine's, not an account's. The
  preview is the lock screen of the session that hibernated.

## Success criteria

SC-001 to SC-009 are tests in QEMU with OVMF. The frame is captured from the machine's
display at the earliest stage and at fixed points after it.

- **SC-001** With a splash set, the first captured frame after the firmware's own is the
  splash, pixel for pixel, and every frame up to the login screen is the splash: no text,
  no blank frame, no cursor.
- **SC-002** Hibernate with a preview, then start: the first captured frame is the
  preview, every frame up to the session's first is the preview, and the session's
  first frame differs from it only in the places FR-022 names.
- **SC-003** After that resume the store holds no override, and a search of the raw
  store for the preview's bytes finds none.
- **SC-004** A preview in the store and then, each in turn: a fresh boot with the
  hibernation image removed, a kernel trial, the recovery key, a deployment chosen at
  start-up. The preview is in no captured frame. With an image that the initramfs
  cancels (guard mismatch), the preview is in no frame after the hibernation step.
- **SC-005** The disk is snapshotted after every write of setting a splash and of
  writing an override. Every snapshot starts, and shows the old image, the new one, the
  default or nothing; never a part of one.
- **SC-006** A splash and an override that are cut short, carry a wrong checksum, claim
  a size beyond the limits or are of another format: each start shows the default
  splash and takes no longer than the limit of FR-006 more than a start without them.
- **SC-007** A splash made for another mode is centred with its aspect ratio kept on a
  background of its colour. A preview made for another mode is not shown.
- **SC-008** With the store full, the machine hibernates and resumes, without a preview.
- **SC-009** With the session set to lock, the picture in the store at hibernate equals
  the lock screen and holds nothing of the unlocked session (compared against a
  session with a known pattern on screen).
- **SC-010** On a device with a bistable display, with the person's go: after a
  hibernate the panel shows the preview while off; at the resume, a camera sees no
  white flash and no full refresh before the session's first update.
- **SC-011** On a real PC, with the person's go: SC-001 and SC-002 by camera, with at
  most the one mode-set blank of FR-024.

## Assumptions

- The session locks at hibernate where it is set to, before the preview is taken.
- The session and the display engine can supply a frame without showing it, and can
  draw one on a bistable display as the last update.
- The hibernation image is not encrypted today. When it is, FR-016's check needs a
  signature the earliest stage can still read; until then such a machine relies on
  FR-017.
- A machine's earliest stage and its store are named by that machine's own spec.

## Out of scope

- Animations, progress bars and text on the splash.
- A picture for shutdown or for a machine that is switched off without hibernating.
- Suspend to RAM: the display is the session's the whole time.
- The firmware's own logo before the earliest stage.
- The settings page that picks the picture (the settings' repository).
