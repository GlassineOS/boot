# Feature Specification: Keep and remove deployments

**Feature branch:** `keep-remove`
**Created:** 2026-11-12 · **Status:** spec, for review; nothing built
**Builds on:** [001-deployments](../001-deployments/spec.md),
[002-stage-base](../002-stage-base/spec.md) · **Interfaces:**
[docs/deployments.md](../../docs/deployments.md) (the state files, `glassine-deploy`,
porcelain, exit codes)

## Summary

Every reset, base update and package replay leaves one more deployment on userdata, and
every received base one more subvolume on the system partition. Any of them can be booted
again: `select` makes it the candidate, and it counts only after it has been accepted
(001). There may be any number of them; nothing assumes two.

This feature adds what keeping many of them needs:

1. **Pinning.** A deployment the person wants to keep is pinned and is never removed
   automatically.
2. **Removing.** A deployment can be removed by hand, in the running system or in the
   recovery, without touching any deployment the boot can pick.
3. **Retention.** Unprotected deployments are removed by a policy: a count each target
   sets, or, where it sets none, a count estimated from the size of its system partition.
   When an
   update or a reset lacks space, the oldest unprotected ones go first. A deployment the
   boot may need is never removed to make room.
4. **Space.** For each deployment and base, the space its removal would free, which for a
   base differs from the size of the files in it, because bases share data.

## User scenarios

### Scenario 1 – Remove a deployment (P1)

**Given** a deployment that is not protected (FR-004),
**When** the person removes it,
**Then** its directory on userdata is gone, its space is back, and `list` no longer shows
it. Nothing in `state/deploy` changes except a `failed=` that named it, which is cleared.
**And given** a protected deployment, **then** removal refuses and names the reason (booted,
current, candidate, staged, previous, pinned).
**And given** the previous deployment, **when** the person removes it with the explicit
option for it (FR-006), **then** the tool says rollback is lost and asks first, and after
removal `previous=` is empty.

### Scenario 2 – Pin a deployment (P1)

**Given** a deployment,
**When** the person pins it,
**Then** `list` shows it pinned, and no automatic removal (Scenarios 3 and 4) ever takes
it, until the person unpins it.
**And given** a pinned deployment, **when** the person removes it by hand, **then** removal
refuses until it is unpinned.

### Scenario 3 – Retention after an accept (P2)

**Given** more unprotected deployments than the retention count (set by the target, or
estimated, FR-008),
**When** a candidate is accepted,
**Then** the oldest unprotected deployments beyond the count are removed, failed ones
first, and each removal is logged with its id.

### Scenario 4 – An update or a reset that lacks space (P2)

**Given** a staged deployment whose switch lacks space on userdata,
**When** the switch runs,
**Then** the oldest unprotected deployments are removed one at a time, failed ones first,
until the switch fits, and the switch goes on.
**And given** that removing every unprotected deployment still isn't enough, **then**
nothing at all is removed, the switch stops with "not enough space" (exit 5), and the
deployment stays staged.
**And given** a base stream that lacks space on the system partition, **when** it is
received, **then** the same holds for bases that no deployment uses, oldest first, never
the newest base.

### Scenario 5 – See what removal frees (P2)

**Given** several bases that share most of their data,
**When** the person lists bases,
**Then** each base shows the space its removal would free on its own, next to the size of
its files, and the two differ as the sharing makes them differ.
**And given** deployments, **then** each shows the space its removal frees on userdata.

### Scenario 6 – The recovery shows them all (P2)

**Given** a device with many deployments,
**When** the recovery lists them,
**Then** every deployment is shown with its state, base, creation time, pin and whether its
base is present, and the recovery can select, pin, unpin and remove each, with the same
refusals as the running system.

### Edge cases

- Removal interrupted (power loss, a killed process): the deployment is no longer listed
  and never boots; the next writer finishes the removal. A half-removed deployment is
  never picked by the boot.
- A deployment whose base is gone (`base_present=no`): removable like any other; it is
  first in line for automatic removal after failed ones.
- Removing the last deployment that uses a base: the base stays; `bases` shows it unused.
  Unused bases are removed automatically only to make room (Scenario 4).
- A hibernated session on userdata: removal, pinning and the automatic removals refuse
  like every other write (exit 4), unless the hibernation is discarded first.
- Two writers at once: the second gets exit 6, as for every other writer.
- A retention count of 0 turns count-based removal off; making room (Scenario 4) still
  works.
- A target with a small system partition: the estimate can be 1 (only one unprotected
  deployment is kept), never 0; current, previous and the other protected ones are kept
  regardless.

## Requirements

### Pinning

- **FR-001**: A deployment's `meta` takes `pinned=1` for a pinned deployment; no key or
  any other value means not pinned. This is an added key: `state/format` stays at 1.
- **FR-002**: `glassine-deploy pin ID` and `unpin ID` set and clear it, with the state lock
  and an atomic write of `meta` (001 FR-004).
- **FR-003**: `list` reports `pinned=yes|no` for every deployment.

### Removing

- **FR-004**: Protected, never removed (by hand or automatically): the booted deployment,
  `current`, `candidate`, `staged`, and a deployment a running switch writes. `previous`
  and pinned deployments are protected from automatic removal and from removal by hand
  without the option of FR-006 (previous) or an unpin first (pinned).
- **FR-005**: `glassine-deploy remove ID` removes an unprotected deployment: under the
  state lock it renames the deployment's directory to a name no deployment id can have
  (ids never start with a dot), syncs, clears `failed=` if it names the deployment, then
  deletes the renamed directory. Any writer that finds such a directory deletes it.
- **FR-006**: `remove ID --previous` removes the previous deployment after asking (`--yes`
  skips the question), saying that rollback is lost, and clears `previous=` in the same
  locked write.
- **FR-007**: The boot never picks a deployment whose directory is missing or renamed for
  removal; with `previous=` naming one, it goes on as when previous doesn't assemble
  (001 FR-005).

### Retention and making room

- **FR-008**: `KEEP_DEPLOYMENTS` in `deploy.conf` is the number of unprotected deployments
  kept after an accept. `deploy.conf` belongs to the target's device package, so each
  target sets its own. 0 turns count-based removal off. Empty or missing means the
  estimate of FR-008a.
- **FR-008a**: The estimate is computed at each accept from the system partition:
  `floor((0.9 × partition size − full) / step)`, at least 1, where `full` is the size of the
  files of the newest base and `step` is the average space the bases other than the oldest
  would free on their own (FR-014), or `full` while there is only one base. It is the
  number of base updates the partition holds next to one full base, with a 10 % margin.
  Deployments on the same base cost nothing on the system partition, so the estimate
  errs toward keeping.
- **FR-008b**: `status` reports the count in use and where it comes from
  (`keep=<N>`, `keep_source=set|estimate`).
- **FR-009**: After a successful `accept`, deployments beyond `KEEP_DEPLOYMENTS` among the
  unprotected ones are removed: failed ones first, then ones whose base is gone, then the
  oldest by `created`. The accept succeeds whether or not a removal fails; a failed removal
  is logged.
- **FR-010**: A switch that lacks space first works out whether removing unprotected
  deployments (order of FR-009) would make it fit. Only if so does it remove them, one at
  a time, re-checking after each, and then go on. Otherwise it removes nothing and exits 5.
- **FR-011**: `receive` that lacks space on the system partition does the same with bases
  that no deployment's `meta` names, oldest first, never the newest base and never a base
  a running command uses.
- **FR-012**: Every automatic removal goes to the kernel log with the id and why (retention
  or room), and `status` reports the last one.

### Space

- **FR-013**: `list` reports, per deployment, the space on userdata its removal frees.
- **FR-014**: `bases` reports, per base and modules subvolume, the size of its files and the
  space its removal alone would free, as the file system accounts shared data.
- **FR-015**: Space figures that can't be read (userdata not mounted, the file system
  can't account sharing) are empty, never guessed.

### Interface

- **FR-016**: The added commands, keys and porcelain fields are documented in
  `docs/deployments.md` and follow its compatibility rule: added fields only, porcelain
  format 1, existing exit codes.

## Key entities

- **Deployment** (001): one bootable root; now also pinned or not.
- **Protected deployment**: one the boot may pick or a running command uses (FR-004).
- **Retention count**: how many unprotected deployments an accept leaves; set per target,
  or estimated from the system partition's size and the bases on it.

## Success criteria

- **SC-001**: In host tests, no sequence of removals, automatic removals and interruptions
  ever removes a protected deployment, and every interrupted removal is finished by the
  next writer.
- **SC-002**: A switch that lacks space either fits after automatic removals or removes
  nothing; host tests cover both, and the "removes nothing" case leaves userdata
  byte-identical.
- **SC-003**: With ten deployments on three bases, `list` and `bases` report space per
  entry, and removing a base frees the reported amount within 5 %.
- **SC-004**: On host-test partitions of 3, 8 and 32 GiB with bases of a real size, the
  estimated count keeps the bases it protects plus one incoming full base within the
  partition every time.
- **SC-005**: The recovery's list shows every deployment on a device with at least ten.

## Assumptions

- Deployments don't share data on userdata (each has its own layers); only bases share
  data, on the system partition.
- Automatic removal never runs in a bare boot (it has no deployment state to protect
  against).
- Recovery clients use `glassine-deploy` and its porcelain (001 Story 6); this feature adds
  no second interface.
