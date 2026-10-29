# Feature Specification: Root deployments

**Feature branch:** `deploy-v1`
**Created:** 2026-10-28 · **Status:** built, host-tested, not yet run on hardware
**Formats and interface:** [docs/deployments.md](../../docs/deployments.md) (owning
reference; not repeated here) · **Boot steps:** [docs/boot.md](../../docs/boot.md)

## Summary

The root file system is assembled at boot from a read-only base on the btrfs system
partition plus the deployment's own layers on userdata. Deployments are tried before
they become the default, can be rolled back, and can be reset to the shipped state
while keeping a defined list of settings. The same tool serves the running system and
the recovery.

## User scenarios and testing

### Story 1: the system protects itself (P1)

The user runs the system daily. Installing or changing files outside `/etc`, `/var`,
`/usr/local` and `/opt` needs an explicit unlock. The base can never be damaged from
the running system.

**Acceptance:**

1. **Given** a booted deployment, **when** a program writes to `/usr`, **then** the
   write fails (read-only), and **when** it writes to `/etc`, **then** it succeeds and
   lands in the deployment's own layer.
2. **Given** any sequence of writes, deletions and renames in the running system,
   **then** the base subvolume's contents and metadata are unchanged.

### Story 2: a new deployment is tried before it counts (P1)

**Acceptance:**

1. **Given** a candidate, **when** the device boots, **then** the candidate boots and
   uses one of its two tries.
2. **Given** a candidate that never gets accepted, **when** its tries run out, **then**
   the next boot is the current deployment again, and the candidate is listed as
   failed.
3. **Given** a candidate whose base is missing or that does not assemble, **when** the
   device boots, **then** the current deployment boots in the same boot, and the
   candidate is marked failed.
4. **Given** the booted candidate, **when** the boot-success service accepts it,
   **then** it becomes current and the old current becomes previous.

### Story 3: reset the system, keep my settings (P1)

**Acceptance:**

1. **Given** a running system, **when** the user resets it, **then** nothing changes
   until the next shutdown the user starts. Changes made in between are kept.
2. **Given** a staged reset and a user-started shutdown with enough battery or the
   charger, **then** the migrate-list paths (modes and owners kept) are carried into a
   fresh layer, and the new deployment boots next as the candidate. Everything else
   from the old deployment is gone: packages, other edits, deletions.
3. **Given** a staged reset, **when** the shutdown was not started by the user, or the
   battery is below the threshold without a charger, **then** the reset stays staged.
4. **Given** a switch interrupted at any point (copy failure, power loss), **then**
   nothing is selected, the old deployment boots unchanged, and the next switch
   starts from scratch.
5. **Given** a full reset, **then** nothing is carried. Home is never touched by any
   reset.
6. **Given** the recovery, **when** it runs `reset --now`, **then** the switch happens
   at once.

### Story 4: a hibernated session is never corrupted (P1)

**Acceptance:**

1. **Given** a hibernate image whose guard matches (userdata not mounted since, same
   kernel build, same deployment), **when** the device boots, **then** the initramfs
   resumes it before mounting anything read-write.
2. **Given** an image whose guard does not match, or a boot in the test role or with
   `glassine.noresume`, **then** the image is cancelled before any read-write mount.
3. **Given** a hibernated session, **when** any `glassine-deploy` command would write,
   **then** it refuses (exit 4) unless `--discard-hibernation` is given, and then it
   cancels the image first.

### Story 5: a broken userdata never blocks a boot (P2)

**Acceptance:**

1. **Given** userdata that is missing or does not mount, **when** the device boots,
   **then** it boots the base with a temporary upper layer, keeping nothing.

### Story 6: the recovery manages deployments (P2)

**Acceptance:**

1. **Given** the recovery with userdata mounted at its own path, **then**
   `glassine-deploy` uses that mount and never writes the raw device under it.
2. **Given** any command, **then** `--porcelain` output and exit codes follow
   [docs/deployments.md](../../docs/deployments.md).

### Edge cases

- A state format newer than the tool: commands refuse (exit 3), `status` still reports,
  and the initramfs boots read-only from the state without writing it.
- Two writers at once: the second gets exit 6.
- Not enough space for a switch: exit 5, still staged.
- A stale "switching" marker from a crash does not block the next switch.
- A cut write of `meta` or `state/` leaves the old file whole.

## Requirements

- **FR-001** The merged root of a deployment is an overlay of its switch layer
  (upper) over its build layer and its base (lowers).
- **FR-002** `/` is read-only by default. `/etc`, `/var`, `/usr/local` and `/opt` are
  writable through the same overlay. Unlocking is an explicit remount.
- **FR-003** Bases and modules subvolumes are never written by the running system or
  by `glassine-deploy`.
- **FR-004** Every write to `state/` or `meta` is atomic and synced, and every writer
  holds the state lock.
- **FR-005** The boot picks the deployment as defined in
  [docs/deployments.md § state/deploy](../../docs/deployments.md#statedeploy): a
  candidate gets two tries, and one that fails or does not assemble falls back to
  current, then previous, then bare.
- **FR-006** No deployment becomes current without a boot as candidate followed by
  `accept`.
- **FR-007** `reset` only stages. The carry and the selection happen in `switch`. A
  newer reset replaces a staged one.
- **FR-008** `switch` starts the switch layer from empty every time, and selects only
  after all copies and a sync succeed.
- **FR-009** The shutdown hook switches only at a user-started shutdown, with a charger
  online or the battery at or above `SWITCH_MIN_CAPACITY`, and never fails a shutdown.
- **FR-010** In the running deployment, the carry reads a plain bind of `/`, never a
  second overlay on the live upper. In recovery it reads a read-only overlay of the
  layers.
- **FR-011** The initramfs mounts nothing read-write and runs no fsck before the
  hibernation step. It resumes only under the rules of
  [docs/boot.md § Hibernation](../../docs/boot.md#hibernation), and otherwise
  cancels the image.
- **FR-012** The hibernation guard is written and compared through the same helper
  (UTC, C locale).
- **FR-013** `glassine-deploy` never writes a raw device under a mounted file system,
  and never runs fsck on a file system in use.
- **FR-014** Porcelain output starts with its format version. Keys may be added within
  a version, and readers ignore unknown keys.
- **FR-015** Everything runs with busybox ash and its applets, e2fsprogs
  (`e2fsck`, `dumpe2fs`, `debugfs`) and the kernel's btrfs and overlayfs; no bash, no
  util-linux, no btrfs-progs.
- **FR-016** Before `switch_root`, the initramfs moves its mounts to `/run/glassine/`
  and releases the state lock.
- **FR-017** A base lists `/` with `bind,ro` in `/etc/fstab`, so the init system keeps
  the lock without making `/etc` and `/var` read-only.
- **FR-018** The boot-success service (`glassine-deploy-accept`) accepts only the
  booted candidate, only after `ACCEPT_AFTER` seconds of uptime, and only when no
  OpenRC service has crashed and every health check in `ACCEPT_HEALTH_DIR` passes.

## Not in this feature (later)

- Package updates as deployments: the build in the background, the replay of the
  user's packages, the accounts merge, deferred upgrade scripts, `.apk-new` conflicts,
  carrying all of `/var/lib`.
- The apk wrapper and `glassine unlock`.
- `kernel-restore`, `--wipe-flatpak`, `--wipe-docker`.
- The kexec loader.
- The hibernate step itself (it writes the guard).

## Success criteria

- **SC-001** `make check` passes. Every acceptance scenario above has at least one
  check (see [docs/testing.md](../../docs/testing.md)).
- **SC-002** On hardware: a reset made from the running system, switched at a
  user-started shutdown, boots as the candidate with the carried settings, is accepted,
  and a rollback returns to the old deployment.
- **SC-003** On hardware: a hibernate image survives a normal boot only if it was
  resumed; after a TWRP mount of userdata it is cancelled.
