# Feature Specification: Stage a deployment on a new base

**Feature branch:** `deploy-0.2-stage-base`
**Created:** 2026-10-31 · **Status:** built, host-tested; a base update through an incremental stream ran on the Note Air (2026-10-31 to 2026-11-01, as the [status page](https://docs.glassine.org/architecture/root-and-deployments/) has it); SC-002, the switched update booting as the candidate and being accepted, is not recorded as run
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
   base is listed with the deployments that use it, and each module set with the
   kernels that use it (FR-008), or as unknown when those can't all be told.

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

### Story 4: the system partition never fills with old bases (P1)

**Acceptance:**

1. **Given** a switch, an accept, a remove or a stage, **then** afterwards the system
   partition holds exactly the bases that deployments on userdata use (any deployment,
   not only current, previous, candidate and staged), and each removed base is
   reported in one line on stdout and in the kernel log.
2. **Given** a deployment meta that can't be read, **then** no base is removed.
3. **Given** a stream from a file that doesn't fit the free space, **when** `receive`
   runs, **then** the unused bases are removed (never the stream's parent) and the
   stream is received; one that still doesn't fit fails with exit 5, the space needed
   and free, and nothing kept.
4. **Given** a hibernated session on userdata, **then** a switch or a receive refuses
   (exit 4) and no base is removed.

### Story 5: the system partition never fills with old kernel modules (P1)

**Acceptance:**

1. **Given** a switch, an accept, a remove or a stage, **then** afterwards the system
   partition holds exactly the module sets of the kernels that can still start (FR-008),
   and each removed set is reported in one line on stdout and in the kernel log.
2. **Given** a source of those kernels that can't be read (the kernel state, a kernel
   record it names, the default boot slot's image, the boot partition's kernel sets,
   this start's time, a hibernated session's kernel), or a board whose boot can't be
   told, **then** no module set is removed and the reason is said.
3. **Given** the recovery, whose own kernel runs and binds no module set, on a board
   whose kernel state names no kernel, **then** the module set of the kernel in the
   default boot slot stays.
4. **Given** a module set that is mounted, or the running kernel's, **then** it stays.

### Edge cases

- `subuid`/`subgid` ranges are carried by name.
- The new base's `shadow` owner and mode are kept for the merged one.
- A migrate list that names `/etc/passwd` or `/etc/group`: the merge replaces the copy.

## Requirements

- **FR-001** `receive` needs `btrfs` (btrfs-progs) and, for a `.zst` stream, `zstd`;
  every other verb keeps 001's FR-015 (busybox, e2fsprogs, the kernel).
- **FR-002** `receive` writes straight into `bases/` (`modules/` with `--modules`): a
  read-only subvolume cannot be renamed, and clearing `ro` would drop its received UUID,
  so there is no temporary directory to move from. A stream for a name that exists
  fails in `btrfs receive` itself. After it, `receive` checks that exactly one
  subvolume was added, with a valid name, read-only and with a received UUID. When
  any of that fails, or `receive` is interrupted, whatever it added since it started
  is deleted.
- **FR-003** `stage` writes a deployment with `kind=update`, `carry=migrate`, the given
  base, and replaces a staged one, like `reset`.
- **FR-004** The account merge and the owner remap run in the switch, after the copy
  and before the sync that precedes the selection; a failure leaves the deployment
  staged.
- **FR-005** The merge runs with busybox `awk` and needs no other tool.
- **FR-006** A base no deployment on userdata names in its meta is removed after a
  switch, an accept (where userdata is mounted), a remove and a stage, after the
  clean-up of deployments, the way `bases remove` removes one (the wait for the space,
  then the `boot/` files no kernel record names). The bases kept follow from the
  deployments; there is no count of its own. A mounted base stays. Nothing is removed
  while the current deployment's meta can't be read, a deployment's meta names no base,
  or a hibernated session's base can't be told; a hibernated session's base is kept.
  The removal never fails the command and needs btrfs-progs (without it, nothing).
- **FR-007** `receive` of a file into `bases/` removes the unused bases (FR-006), all but
  the stream's parent, before the stream when the file is larger than the free space,
  and after a `btrfs receive` that runs out of space, then receives it once more. When
  it still doesn't fit: exit 5, the space needed and free, nothing kept. From stdin:
  exit 5, nothing removed.
- **FR-008** A module set no kernel that can still start uses is removed after a switch,
  an accept (where userdata is mounted), a remove and a stage, after the unused bases
  (FR-006); never in `receive`. The kernels that can still start are:
  - the running kernel, and the kernel of a module set that is mounted;
  - the kernels the kernel state names (current, previous, candidate, failed, deferred)
    and the kernels of the kernel records it names (current, previous, candidate,
    failed, the one being written);
  - what the boot chain holds: on a board with a raw default boot slot, the kernel in
    the slot's image (read from its bytes), and the test slot's on a board that tries
    kernels there, and the block-list record's image; on a PC, the kernel of every
    kernel set on the boot partition;
  - a hibernated session's kernel;
  - a module set received since this start (its kernel's install or boot image may
    still come; it goes at the first of these points after the next start that nothing
    else names it).

  A board with a raw default boot slot whose kernel state doesn't exist (no kernel was
  ever installed through the kernel tool) has no recorded kernels: there the running
  kernel and the boot chain's are all. On a PC the kernel state comes with the install,
  so its absence counts as unreadable. Nothing is removed while any of these can't be read, while the default slot's kernel
  has no module set (a release that matches none is taken as misread), or on a board
  whose default boot can't be told (no default slot, an unknown hand-off). The removal never fails
  the command and needs btrfs-progs (without it, nothing). `bases` lists each module
  set with the kernels that use it (their roles), empty when none, `unknown` when none
  is named and the kernels can't all be told.

## Not in this feature (later)

- The replay of the user's packages (the apk wrapper, epic P1) and carrying only what
  the device changed (P5).
- Downloading streams; checking a signature (`--sha256` only).

## Success criteria

- **SC-001** `make check` passes, with a check for every acceptance scenario.
- **SC-002** On hardware: a received base staged from the running system, switched at a
  user-started shutdown, boots as the candidate with the user account, Wi-Fi and
  pairings, and is accepted.
