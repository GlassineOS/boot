# Feature Specification: The first start of an installed system

**Feature branch:** `first-start`
**Created:** 2026-11-15 · **Status:** built, host-tested, not yet run on hardware
**Builds on:** [001-deployments](../001-deployments/spec.md),
[006-device-data-storage-access](../006-device-data-storage-access/spec.md) ·
**Interfaces:** [docs/deployments.md](../../docs/deployments.md) (`init`, `state/install`,
"The first start"; owning reference, not repeated here)

## Summary

An installer writes the system partition as one prepared image and leaves userdata as
it found it. The image holds one base, the kernel's modules and an install marker, and
no deployment. The first boot of the installed device is a bare boot. In that boot, and
only when the marker is there, the system completes itself: the system partition takes
its whole partition, userdata is formatted for GlassineOS, the base becomes the first
deployment, and the device restarts into it. From then on it is an ordinary system: the
first deployment is a candidate and is accepted like any other.

The image builder prepares the system partition through `boot`'s own layout step, so the
on-disk format has one owner.

## User scenarios and testing

### Story 1: a fresh install comes up by itself (P1)

**Acceptance:**

1. **Given** a system partition laid out with the marker, one base and its kernel's
   modules, and a userdata holding another system's files (or no file system), **when**
   the device boots, **then** it boots bare, grows the system partition to its
   partition, formats userdata, makes the base the first deployment as the candidate,
   removes the marker and restarts.
2. **Given** that restart, **then** the first deployment boots, and after a healthy boot
   it is accepted and becomes current.
3. **Given** the first start, **then** userdata afterwards has no file of the other
   system, and the person's storage (home, Flatpak's data, the developer folder) is
   made on first use as on any other boot.

### Story 2: a power cut never breaks an install (P1)

**Acceptance:**

1. **Given** a power cut at any point of the first start, **when** the device boots
   again, **then** the first start runs again and ends in the same state as an
   uninterrupted one.
2. **Given** a cut after userdata was formatted, **then** userdata is not formatted a
   second time.
3. **Given** a cut after the first deployment was selected and before the marker was
   removed, **when** the device boots the deployment, **then** the first start only
   removes the marker: userdata, now the deployment's, is never formatted again.

### Story 3: userdata is formatted only when an install asked for it (P1)

**Acceptance:**

1. **Given** a system partition without the marker, **when** any boot happens, **then**
   the first start writes nothing to either partition.
2. **Given** the marker while a deployment is booted and none is selected, **then** the
   first start refuses and writes nothing.

### Story 4: an image builder lays out the system partition (P1)

**Acceptance:**

1. **Given** an empty, mounted btrfs, **when** the image builder asks `boot` to lay it
   out (with or without the marker), **then** it holds the directories and state files
   of the current state format, selecting nothing.
2. **Given** a path that is not a mounted btrfs, a subvolume rather than the top level,
   or a btrfs that is not empty, **then** the layout step refuses and writes nothing.

### Edge cases

- More than one base, or none, with the marker: refused, the marker kept.
- A userdata that stays mounted: not formatted, the marker kept, the next boot tries
  again.
- A first deployment that never becomes healthy: after its tries the device boots bare,
  the marker already gone; the recovery takes over.
- A device whose other system keeps metadata at the end of userdata: the board's
  configuration leaves that room free.

## Requirements

- **FR-001** `boot` lays out an empty, mounted btrfs as a system partition in the state
  format it supports, optionally with the install marker. The step needs no device
  configuration and no btrfs tools, refuses anything but an empty top-level btrfs mount,
  and writes the format version last, so a cut layout reads as not laid out.
- **FR-002** The first start runs in the booted system, after a bare boot; never in the
  initramfs (001 FR-011).
- **FR-003** Without the marker the first start writes nothing. Userdata is never
  formatted without it.
- **FR-004** The first start, in order: records the running kernel's release when the
  state names none and its modules are there; grows the system partition's file system
  to its partition; formats userdata; makes the only base the first deployment, bare
  (no package replay, nothing carried), as the candidate with two tries; removes the
  marker; restarts the device in an orderly way.
- **FR-005** The marker is removed only after the state names that candidate.
- **FR-006** Every step can run again. A cut at any point is completed by the next
  boot's first start, which repeats nothing destructive: a userdata whose identity the
  marker records as formatted by it is not formatted again, and once a deployment is
  selected, userdata belongs to it and is never formatted.
- **FR-007** Userdata is formatted only when no file system of it is mounted; it gets
  the file system and block size the rest of `boot` expects (001: ext4; the hibernate
  step: 4096-byte blocks), readable by the older ext4 tools a second system on the
  machine may check it with, and leaves the board's configured room free at its end.
- **FR-008** With no current deployment, staging a base makes a first deployment: only
  without a package replay (refused with one), with nothing carried.
- **FR-009** The first start's messages go to the kernel log, where the initramfs logs.
- **FR-010** Only receiving, removing a base and the first start need btrfs tools; the
  first start also needs the ext4 formatter (001 FR-015). A base meant for installs ships
  them.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The layout step (`glassine-deploy init POOL_MOUNT [--install-marker]`) | owned; called by the image builder (GlassineOS/images) | porcelain/exit codes of `glassine-deploy` 1 | `docs/deployments.md` |
| The install marker `state/install` | owned | `format=1` | `docs/deployments.md` |
| State format | owned (unchanged) | `version=1` | `docs/deployments.md` |
| `USERDATA_RESERVE_KIB` in `deploy.conf` | owned; set by a device package | — | `conf/deploy.conf.example` |

## Device scope and risk

- **Writes:** the system partition's state and size (the grow is in place), and all of
  userdata, which is formatted. Formatting userdata destroys whatever another system kept
  there; that is the install's decision, made before the marker is written.
- **Escape:** a first start that can't finish leaves the marker and a bare boot, and
  tries again at every boot; the recovery can remove the marker or stage a deployment.
- Running it on a device is a separate run with the person's go.

## Acceptance

- Host tests (`make check`) on real btrfs and ext4: Stories 1–4, a cut after each step
  and the next boot, a formatter that fails half way, a stage cut before its selection.
- On the first device, with the person's go: an install from the image builder's pool
  image reaches an accepted first deployment.

## Out of scope

- How the image reaches the system partition (the installer's work), and building it
  (the image builder's).
- Which file systems another system on the device needs (the device's description).

## Success criteria

- **SC-001** `make check` passes, with a check for every acceptance scenario above.
- **SC-002** On hardware: from the installer's last write to an accepted first
  deployment with no step by the person, through at most two restarts.
