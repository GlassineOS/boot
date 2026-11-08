# Feature Specification: Device data, the person's storage, developer access

**Feature branch:** `device-data`
**Created:** 2026-11-08 · **Status:** spec, for review; nothing built
**Builds on:** [001-deployments](../001-deployments/spec.md) · **Interfaces:**
[docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) ("Device data"),
[docs/deployments.md](../../docs/deployments.md) (userdata, the migrate list),
the developer mode in [README.md](../../README.md) · **Ticket:**
[hub#8](https://github.com/GlassineOS/hub/issues/8) (Migration: the overlay sort)

## Summary

Three things every device in the deployments layout gets from `boot`, the same on every
board:

1. **Device data.** A device may declare files it takes, read-only, from its own
   partitions outside GlassineOS (firmware the kernel requests, a display waveform, a
   calibration file). They're copied once into a verified seed and read from there. A
   device that declares none, such as a computer whose firmware all comes with the kernel
   release, has no seed and nothing runs for it.
2. **The person's storage.** `/home`, `/root` and Flatpak's system data are on userdata,
   outside the deployments, so every deployment sees the same files.
3. **Developer access.** With `glassine.devmode=usb`, the booted system keeps the USB
   network and runs an SSH server that accepts only the person's keys. Without it, nothing
   listens.

What a device's files are and where they come from is the device package's business: it
ships a list and nothing else. The seed tool, its format and its boot steps are `boot`'s.

## User scenarios

### Scenario 1 – A device with no device data (P1)

**Given** a board whose device package declares no device data,
**When** it boots,
**Then** no seed partition is read or written, the firmware search path is the kernel's
own, and no step related to device data runs or logs anything.

### Scenario 2 – Firmware from the device's own partitions (P1)

**Given** a device package that lists firmware files with the paths the kernel requests
them by (`qcom/<soc>/<board>/…`, a board file under another name, a split image by one
pattern), each from a partition and path on the device,
**When** the device boots the first time,
**Then** the files are copied into the seed, read-only from their sources, before the
device manager loads drivers; every file is checked; the kernel finds them in that same
boot; and the seed's manifest names each resolved file with its sha256.

### Scenario 3 – Later boots and a damaged seed (P1)

**Given** a complete seed,
**When** the device boots,
**Then** the seed is verified and made visible read-only, and no source partition is
read. **And given** a seed with a file that doesn't match, that file is copied again from
its source in that boot, and nothing unverified is ever visible.

### Scenario 4 – The person's files in a new deployment (P1)

**Given** a device with files in `/home` and `/root` and Flatpak apps installed,
**When** it boots any deployment, including a fresh one on a new base or after a reset,
**Then** `/home`, `/root` and `/var/lib/flatpak` hold the same files, mounted before any
service that uses them, and Flatpak apps can use `/var/tmp` (a shared mount).

### Scenario 5 – A developer logs in (P1)

**Given** `glassine.devmode=usb` on the kernel command line and a public key in
`/root/.ssh/authorized_keys`,
**When** the device has booted,
**Then** a computer on the USB cable gets an address from the board's developer range and
logs in over SSH with that key, as root; a password or another key is refused; and the
host key is the same in every deployment.
**And given** a command line without it, no USB network function and no SSH server run.

## Requirements

### Device data

- **FR-001**: A device's list is a file the device package ships. Each entry names the
  file in the seed, its source (`PART:/PATH`) and an optional check. A missing or empty
  list means the device has no device data (Scenario 1).
- **FR-002**: Seed names may contain directories, may differ from the source's file name,
  and are relative without `.` or `..` parts.
- **FR-003**: One entry may name a split image (a `.mdt` and its numbered parts) by a
  pattern; it's resolved against the source when the seed is filled, and each resolved
  file is listed in the manifest on its own.
- **FR-004**: Sources are read read-only and never written: ext4 without mounting or
  journal replay, vfat mounted read-only, btrfs read-only without log replay.
- **FR-005**: The seed lives in `glassine/` on the board's `DEVICE_PART`; other files on
  that partition stay untouched. The board key is required only when the device has a list.
- **FR-006**: Firmware in the seed is under `firmware/`. When the seed has `firmware/`,
  the kernel searches it before its own paths: from `firmware_class.path` on the board's
  command line, or, when the running kernel's command line lacks it, set by the seed step
  before the device manager's coldplug. A seed must never hold a name the kernel release's
  own firmware provides.
- **FR-007**: The seed tool, the boot step and the service are `boot`'s and identical on
  every board; the device package ships only its list and the daemons' configuration that
  names seed paths.
- **FR-008**: The seed never holds a device's live state (a radio's file systems,
  calibration data that changes at run time); those stay read at run time by the
  services that own them.

### The person's storage

- **FR-009**: `/home`, `/root` and `/var/lib/flatpak` are directories under the userdata
  prefix, outside the deployments, created on first use and mounted into every deployment
  before the services start.
- **FR-010**: `/var/tmp` is a shared mount, so mount namespaces made from it see later
  mounts.
- **FR-011**: The plain layout (no deployments) is unchanged.

### Developer access

- **FR-012**: With `glassine.devmode=usb` and a board `DEVMODE_ADDR`, the booted system
  keeps the USB network the initramfs made (or makes it if the initramfs didn't), serves
  addresses from the board's developer range, and runs an SSH server: keys only, from
  `/root/.ssh/authorized_keys`; no passwords.
- **FR-013**: Without `glassine.devmode=usb`, no USB network function, address server or
  SSH server runs, whatever packages are installed.
- **FR-014**: The SSH host keys are on the migrate list. A deployment without them makes
  new ones on first start.
- **FR-015**: `conf/board.conf.example` and the documentation keep saying that no board
  for end users may put `glassine.devmode` on its constant command line.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Device data: the list, the seed, the manifest, `firmware_class.path` | owned (extended) | `format=1` | `docs/kernel-artifacts.md` |
| Deployments layout: userdata directories, the migrate list | owned (extended) | `format=1` | `docs/deployments.md` |
| Developer mode | owned (extended) | — | `README.md`, `conf/board.conf.example` |

## Device scope and risk

The seed writes only `glassine/` on `DEVICE_PART`, on a device that has a list. Every
other partition is read-only. A seed cut off before its manifest is no seed; the next boot
redoes it. Developer access changes nothing on storage. Putting these on a device is a
separate run with the person's go.

## Acceptance

- The QEMU tests cover Scenarios 1, 4 and 5 (a board without a list; the storage mounts
  across a new deployment; SSH with devmode on and nothing listening with it off), and
  Scenarios 2 and 3 on a test disk with a fake source partition (a pattern, a rename, a
  directory, a corrupted file).
- The seed tool's host test passes with the extended format.
- The first device runs a base with its list, and Scenarios 2–5 hold there.

## Out of scope

- Which files a given device lists and its daemons (a device package's work).
- Hibernation's interaction with the seed beyond what `docs/kernel-artifacts.md` already
  states.

## Success criteria

- **SC-001**: A board without device data boots with no device-data step in its log.
- **SC-002**: Verifying a complete seed of about 35 MB adds under a second to a boot on
  the first device.
- **SC-003**: After any boot, every source partition reads the same as before.
