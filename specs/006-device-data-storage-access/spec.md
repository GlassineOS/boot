# Feature Specification: Device data, the person's storage, developer access

**Feature branch:** `device-data`
**Created:** 2026-11-08 · **Status:** spec, for review; nothing built
**Builds on:** [001-deployments](../001-deployments/spec.md),
[004-kernel-records](../004-kernel-records/spec.md) · **Interfaces:**
[docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) ("Device data"),
[docs/deployments.md](../../docs/deployments.md) (userdata, resets),
[docs/boot.md](../../docs/boot.md) (the boot steps, bare boots),
the developer mode in [README.md](../../README.md) · **Ticket:**
[hub#8](https://github.com/GlassineOS/hub/issues/8) (Migration: the overlay sort)

## Summary

Three things every board in the deployments layout gets from `boot`, the same on every
board:

1. **Device data.** A device may declare files it takes, read-only, from its own
   partitions outside GlassineOS (firmware the kernel requests, a display waveform, a
   calibration file). They're copied once into a verified seed and read from there. A
   device that declares none, such as a computer whose firmware all comes with the kernel
   release, has no seed, and nothing related to device data runs for it.
2. **The person's storage.** Home and Flatpak's system data live on userdata, outside the
   deployments, so every deployment sees the same files and no reset touches them.
3. **Developer access.** With `glassine.devmode=usb`, the booted system brings up the USB
   network and an SSH server on it that accepts only keys the developer put in place.
   Without it, `boot` starts neither.

What a device's files are and where they come from is the device package's business: it
ships a list and nothing else. The seed tool, its format, its boot steps and its service
are `boot`'s.

## User scenarios

### Scenario 1 – A device with no device data (P1)

**Given** a deployment whose root has no device-data list,
**When** it boots,
**Then** `DEVICE_PART` is neither read nor written (whether or not the board names one),
the firmware search path is the kernel's own, and no device-data step runs or logs.

### Scenario 2 – Firmware from the device's own partitions (P1)

**Given** a list naming firmware files by the paths the kernel requests them by
(`qcom/<soc>/<board>/…`, a board file under another name, a split image by one pattern),
each from a partition and path on the device,
**When** the device boots the first time,
**Then** the files are copied into the seed, read-only from their sources, before the
device manager loads drivers; each file is verified by its sha256 and, where the entry
names one, its check; the kernel finds them in that same boot; and the manifest names
each resolved file with its source and sha256.

### Scenario 3 – Later boots, a damaged seed, a changed list (P1)

**Given** a seed complete for the running deployment's list,
**When** the device boots,
**Then** the initramfs verifies it and makes it visible read-only, and no source
partition is read.
**And given** a seed file that doesn't verify, it is copied again from its source in that
boot; nothing unverified is ever visible.
**And given** a deployment whose list names a file the seed lacks (a base update added
it), that file is copied in that boot; files the seed holds that the list doesn't name
stay (an older deployment's shorter list removes nothing).

### Scenario 4 – A source that is gone or differs (P2)

**Given** a list entry whose source can't be read, or whose source now gives different
bytes from the manifest's,
**When** the seed is checked,
**Then** an existing verified copy stays in use; an entry with no verified copy is left
out and the seed is reported incomplete (`glassine-device-seed status`, the log); the
entry is retried on every boot; and different source bytes replace the recorded ones
only on an explicit refresh.

### Scenario 5 – The person's files across deployments and resets (P1)

**Given** a device with files in home and Flatpak apps installed,
**When** it boots any deployment, including one made by a reset or a full reset, or one
on a new base,
**Then** home and Flatpak's system data hold the same files, mounted before any service
that uses them, and Flatpak apps can use `/var/tmp` (a shared mount).

### Scenario 6 – A developer logs in (P1)

**Given** `glassine.devmode=usb` on the kernel command line, a board with a developer
address, and a public key in the developer folder on userdata,
**When** the device has booted a deployment,
**Then** a computer on the USB cable gets an address from the board's developer range and
logs in as root over SSH with that key; a password or another key is refused; the SSH
server listens only on the developer address; and the host key is the same across
deployments, resets and rollbacks.
**And given** a command line without `glassine.devmode=usb`, `boot` starts no USB network
function, no address server and no SSH server.

## Requirements

### The list

- **FR-001**: A device package ships its list at `/usr/share/glassine/device-data.list`.
  The first line is `format=1`. Each following line is `NAME SOURCE [CHECK]`: the name in
  the seed, the source as `PART:/PATH`, and an optional check (`wbf`, a waveform header;
  more may be added). `#` starts a comment. The list never names `DEVICE_PART`; that is
  the board key's.
- **FR-002**: No list, or a list with no entries, means the device has no device data
  (Scenario 1). The initramfs reads the list from the assembled root before it reads
  `DEVICE_PART`.
- **FR-003**: Names may contain directories, may differ from the source's file name, and
  are relative without `.` or `..` parts or a leading `/`.
- **FR-004**: An entry may name a split image by a pattern (`NAME.*` for a `.mdt` and its
  numbered parts); it is resolved against the source when the seed is filled. It fails as
  a whole, and adds nothing, when it matches no `.mdt` or its numbered parts have a gap.
  Each resolved file is a line of the manifest on its own.
- **FR-005**: A source on `DEVICE_PART` itself is refused (the list is invalid, and
  nothing is seeded until it's fixed).

### The seed

- **FR-006**: The seed lives in `glassine/` on the board's `DEVICE_PART`, which must be
  ext4; other files there stay untouched. Its manifest (`format=1`) names each file with
  its source and sha256. A board with no `DEVICE_PART` can't have device data, and a list
  on such a board is reported once per boot and otherwise ignored.
- **FR-007**: The seed is complete for a list when every entry is in the manifest and
  every file verifies. The initramfs binds `glassine/` read-only on
  `/run/glassine/device` when the files it holds verify, complete or not; the seed
  service fills what is missing or doesn't verify (Scenarios 3 and 4) and binds again.
- **FR-008**: Sources are read read-only and never written: ext4 without mounting or
  journal replay, vfat mounted read-only, btrfs read-only without log replay. The only
  writes are to `DEVICE_PART`: the files and manifest in `glassine/` (temp files,
  renamed, the manifest last), and one read-write mount to replay its journal when it
  needs recovery.
- **FR-009**: A seed write cut off at any point leaves either the previous manifest with
  files that still verify, or a manifest whose files are checked and redone on the next
  boot; nothing unverified is ever bound.
- **FR-010**: `glassine-hibernate` refuses (exit 3) while `DEVICE_PART` is mounted
  read-write.
- **FR-011**: The seed never holds a device's live state (a radio's file systems,
  calibration data that changes at run time); the services that own them read those at
  run time.

### Firmware

- **FR-012**: Firmware in the seed is under `firmware/`. When `firmware/` is bound, the
  kernel searches it before its own paths, on every boot: from `firmware_class.path` on
  the board's command line, or, when the command line lacks it, written to
  `/sys/module/firmware_class/parameters/path` by the initramfs when it binds the seed
  and by the seed service when it binds it, without a trailing newline (the kernel keeps
  the value verbatim).
- **FR-013**: No seed name may be a name the running kernel release's own firmware
  provides (its `kernel.manifest` firmware list). The seed fill refuses such an entry, and
  the kernel install refuses a kernel release whose firmware list names a file the seed
  holds, naming the clash in both cases.

### The person's storage

- **FR-014**: Home is `/home`. It and Flatpak's system data (`/var/lib/flatpak`) are the
  directories `home/` and `flatpak/` under the userdata prefix, outside the deployments,
  created on first use (`root:root`, `0755`), and bound into the deployment by the
  initramfs while it assembles the root, before `switch_root`.
- **FR-015**: No reset touches them: `reset` and `reset --full` keep home and Flatpak's
  data. The reset prompt, `docs/deployments.md` and decision 0010 (in GlassineOS/docs)
  say so.
- **FR-016**: A bind that fails, or a directory that can't be created, is logged and
  reported by `status`; the boot goes on with the deployment's own directory in its
  place, and nothing is written into the userdata directory. The next boot tries again.
- **FR-017**: Files a deployment already holds in its own `/home` or `/var/lib/flatpak`
  are hidden by the bind, not moved or deleted; `status` reports a non-empty hidden
  directory.
- **FR-018**: A bare boot binds nothing from userdata (it keeps nothing, as before). An
  initramfs from before this feature (after a boot-image rollback) boots deployments
  without the binds, with the deployment's own directories, and loses nothing on
  userdata.
- **FR-019**: `/var/tmp` is a bind of itself made shared, so mount namespaces made from
  it see later mounts; its contents stay in the deployment's `/var`.
- **FR-020**: The plain layout (no deployments) is unchanged.

### Developer access

- **FR-021**: The developer folder is `devmode/` under the userdata prefix (`root:root`,
  `0700`). It holds `authorized_keys` and the SSH host keys. No reset touches it, and no
  base or migrate list carries any of it.
- **FR-022**: With `glassine.devmode=usb` and a board `DEVMODE_ADDR`, the booted system
  brings up the USB network at `DEVMODE_ADDR`, serves addresses from the board's
  developer range, and runs an SSH server listening only on `DEVMODE_ADDR`: keys only,
  from the developer folder; no passwords. Host keys are made in the developer folder
  on first start. It reads the board keys from `/etc/glassine-bootimg/board.conf`, which
  the image builder installs.
- **FR-023**: The first key gets into the developer folder from the running system (an
  administrator), or from the recovery, which can write userdata. A bare boot has no
  developer folder, so no SSH; the initramfs's developer shell (below) stays the way in.
- **FR-024**: The initramfs's developer mode is unchanged: with `glassine.devmode=usb`,
  its no-password telnet shell and HTTP endpoints run on test-role and failed boots, and
  anyone with a cable gets root there. `board.conf.example` and the README keep saying
  so, and that no board for end users may put `glassine.devmode` on its constant command
  line.
- **FR-025**: Without `glassine.devmode=usb`, `boot` starts no USB network function,
  address server or SSH server, and nothing `boot` ships listens on USB.

### Moving the seed tool

- **FR-026**: The seed tool and its service move from the first device's package into
  `boot`. The `boot` package version that adds them conflicts with the device package
  versions that still ship them; the device package's next version drops them and ships
  its list as FR-001 says. `docs/kernel-artifacts.md` says the service is `boot`'s.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Device data: the list, the seed, the manifest, the firmware path | owned (extended) | list `format=1`, manifest `format=1` | `docs/kernel-artifacts.md` |
| Deployments layout: `home/`, `flatpak/`, `devmode/` under the userdata prefix; resets | owned (extended) | `format=1` | `docs/deployments.md` |
| Developer mode in the booted system | owned (extended) | — | `README.md`, `conf/board.conf.example` |
| Board keys in the booted system (`/etc/glassine-bootimg/board.conf`) | owned; installed by the image builder (GlassineOS/images) | — | `docs/boot.md` |
| Decision 0010, "a full reset keeps only home" | consumed (GlassineOS/docs, amended by FR-015) | — | `docs/decisions/0010-root-and-deployments.md` |

The image builder also has to ship an SSH server; which one is the implementation plan's
choice, and the paths it reads are FR-021's.

## Device scope and risk

- **The seed:** writes only `glassine/` on `DEVICE_PART` (and a journal replay there), on
  a device with a list. Every source partition is read-only. A cut-off write is FR-009's;
  the recovery can remove `glassine/`, and the daemons and the recovery read the original
  sources meanwhile (`docs/kernel-artifacts.md`).
- **The storage binds:** they hide, never move or delete, a deployment's own directories
  (FR-017). A failed bind leaves the boot running on the deployment's own directories
  (FR-016). Escape: a boot-image rollback to an older initramfs boots without the binds
  and loses nothing (FR-018); the files stay on userdata.
- **Developer access:** writes only the developer folder on userdata. Off unless the
  command line asks for it.
- Putting these on a device is a separate run with the person's go.

## Acceptance

- QEMU tests cover:
  - Scenario 1, a root without a list: no device-data step in the log, `DEVICE_PART`
    untouched;
  - Scenarios 2–4 on a test disk with fake source partitions: a pattern, a gap in a
    split image, a rename, a directory, a corrupted seed file, a source gone, a source
    changed, a list grown by a base update, a source on `DEVICE_PART` refused, a name the
    kernel provides refused;
  - a seed write cut off before and after the manifest's rename (FR-009);
  - Scenario 5 across a new deployment, a reset and a full reset; a failed bind; a
    non-empty hidden directory;
  - Scenario 6 on a virtual network interface standing in for the USB gadget (the
    harness has no USB device side): SSH with the key, refused with a password and with
    another key, not listening elsewhere; nothing running without `glassine.devmode`.
- The seed tool's host test passes with the list and manifest formats above.
- On the first device, with the person's go: Scenarios 2, 3, 5 and 6 hold, including the
  USB gadget.

## Out of scope

- Which files a given device lists, and its daemons (a device package's work).
- A recovery menu for device data and resets (the recovery's own work).
- What makes a deployment after userdata has been formatted: until something does, the
  device boots bare (`docs/boot.md`).

## Success criteria

- **SC-001**: A board without device data boots with no device-data step in its log.
- **SC-002**: Verifying a complete seed of about 35 MB adds under a second to a boot on
  the first device.
- **SC-003**: After any boot, every source partition reads the same as before.
