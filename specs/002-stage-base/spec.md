# Feature Specification: Stage a deployment on a new base

**Feature branch:** `deploy-0.2-stage-base`
**Created:** 2026-10-31 · **Status:** built, host-tested, not yet run on hardware
**Builds on:** [001-deployments](../001-deployments/spec.md) · **Formats and interface:**
[docs/deployments.md](../../docs/deployments.md)

## Summary

A new base (a system image built elsewhere) arrives as a btrfs send stream, is
received read-only onto the system partition, and a deployment on it is staged the
same way as a reset: the next user-started shutdown carries the migrate list over and
selects it, and the boot tries it before it counts. A switch now merges the user
accounts into the new deployment, so the people, their passwords and their group
memberships survive a base change and a reset alike.

## User scenarios and testing

### Story 1: install a new base (P1)

**Acceptance:**

1. **Given** a full or incremental base stream (plain, or zstd-compressed by its name),
   **when** `receive` runs, **then** the subvolume lands under `bases/` (or
   `modules/` with `--modules`), read-only, with a received UUID, so later incremental
   streams apply to it.
2. **Given** a stream whose checksum does not match `--sha256`, or a stream that fails
   half way, or one whose name exists already, **then** nothing new stays on the
   system partition and the exit code says so.
3. **Given** the bases on the system partition, **when** `bases` runs, **then** each
   base and modules subvolume is listed with the deployments that use it.

### Story 2: move to the new base, keep my settings (P1)

**Acceptance:**

1. **Given** a received base, **when** the user stages it, **then** nothing changes
   until the next user-started shutdown, exactly like `reset` (`--now` switches at
   once, for the recovery).
2. **Given** that switch, **then** the new deployment carries the migrate list from
   the current one, and boots next as the candidate with two tries.
3. **Given** a base that is not on the system partition, **then** `stage` refuses and
   changes nothing.

### Story 3: my account survives (P1)

**Acceptance:**

1. **Given** a switch that carries (`stage` or `reset`), **then** the new
   deployment's `/etc/passwd`, `/etc/group` and `/etc/shadow` hold the new base's
   accounts plus the current deployment's users and groups with IDs 1000 to 65533 the
   new base lacks (same ID when free, else the next free one from 1000), every
   password by name, and every group membership of a user that exists afterwards.
2. **Given** a system account whose ID differs between the two bases, **then** every
   carried file owned by it is owned by the new ID (by name), modes (setuid included)
   unchanged.
3. **Given** a system account the new base lacks, **then** it is not carried, and the
   switch reports it.
4. **Given** a full reset, **then** no account is carried (unchanged from 001).

### Edge cases

- `subuid`/`subgid` ranges are carried by name.
- The new base's `shadow` owner and mode are kept for the merged one.
- A migrate list that names `/etc/passwd` or `/etc/group`: the merge replaces the copy.

## Requirements

- **FR-001** `receive` needs `btrfs` (btrfs-progs) and, for a `.zst` stream, `zstd`;
  every other verb keeps 001's FR-015 (busybox, e2fsprogs, the kernel).
- **FR-002** `receive` writes only into a temporary directory on the system partition
  and moves the subvolume into place after it checked it: exactly one subvolume,
  read-only, a received UUID, a valid name not taken. Anything else is deleted.
- **FR-003** `stage` writes a deployment with `kind=update`, `carry=migrate`, the given
  base, and replaces a staged one, like `reset`.
- **FR-004** The account merge and the owner remap run in the switch, after the copy
  and before the sync that precedes the selection; a failure leaves the deployment
  staged.
- **FR-005** The merge runs with busybox `awk` and needs no other tool.

## Not in this feature (later)

- The replay of the user's packages (the apk wrapper, epic P1) and carrying only what
  the device changed (P5).
- Removing old bases (`bases` only lists).
- Downloading streams; checking a signature (`--sha256` only).

## Success criteria

- **SC-001** `make check` passes, with a check for every acceptance scenario.
- **SC-002** On hardware: a received base staged from the running system, switched at a
  user-started shutdown, boots as the candidate with the user account, Wi-Fi and
  pairings, and is accepted.
