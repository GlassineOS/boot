# Feature Specification: How many deployments a device keeps

**Feature branch:** `keep-deployments`
**Created:** 2026-11-12 · **Updated:** 2026-11-27
**Builds on:** [001-deployments](../001-deployments/spec.md),
[002-stage-base](../002-stage-base/spec.md) · **Interfaces:**
[docs/deployments.md](../../docs/deployments.md) (the state files, `glassine-deploy`,
porcelain, exit codes), GlassineOS/installer spec 002 (the device description, the
release's least partition sizes)

## Summary

Every reset, base update and package replay makes a deployment on the data partition,
and every base update a base on the system partition. Deployments nothing can start
are removed by themselves (002). How many earlier deployments a device keeps for going
back is a decision about its storage, made once per device, in its description:

- The device's description names how many earlier deployments it keeps
  (**keep updates**). A device with little storage keeps one, a device with a lot keeps
  more.
- The same number sizes the system partition at install (the room for that many base
  updates), so what the installer makes room for and what the system keeps agree.
- Beyond the one previous deployment, an earlier deployment stays only while both
  partitions keep room for the next update. When an update needs room, the oldest earlier
  deployment goes first.
- The person can pin a deployment; a pinned deployment is never removed by itself.

## User scenarios

### Scenario 1 – A small device keeps one earlier deployment (P1)

**Given** a device whose description keeps one update,
**When** a new deployment is accepted,
**Then** the deployment that was current before it stays (previous), every older one
that isn't pinned is removed, and with them the bases and module sets nothing uses
any more (002).

### Scenario 2 – A large device keeps several (P1)

**Given** a device whose description keeps four updates and partitions with room,
**When** new deployments are accepted one after another,
**Then** the four most recently current ones before the running one stay, and the fifth
oldest goes at the next accept.

### Scenario 3 – Room runs short (P1)

**Given** a device that keeps four updates, whose data partition has less free space
than the next update needs,
**When** a deployment is accepted, staged or switched,
**Then** the oldest earlier deployments beyond previous are removed until the room is
there again, each removal logged with why, and previous is never removed for room.
**And given** that removing every earlier deployment beyond previous still isn't enough,
**then** they all stay, and the command goes on as it does today (a stage or switch
that lacks space stops with exit 5 and removes nothing).

### Scenario 4 – Pin a deployment (P2)

**Given** a deployment the person wants to keep,
**When** they pin it,
**Then** `list` shows it pinned, no removal by itself takes it, whatever the count or the
room, and removing it by hand refuses until it is unpinned. A pinned deployment counts
towards the device's keep count.

### Scenario 5 – The installer makes the room the device keeps (P1)

**Given** a device description that keeps N updates,
**When** a release is made for that device,
**Then** the least size it states for the system partition holds one base, N base
updates and the kernel modules, with the file system's slack, and a device that keeps
more needs a larger system partition.

### Edge cases

- A description without the key: one update is kept (the safe value for a small device).
- Keep updates 0 is not a value: previous is always kept, it is the way back after a
  bad update.
- A deployment that was never current (a staged one replaced by another, a failed one
  older than the last failed) is not an earlier deployment: it goes as today (002).
- Deployments made before this feature have no record of when they were current: their
  creation time stands in for it.
- The partitions' free space can't be read: nothing is removed for room, and the count
  alone decides.
- A hibernated session on the data partition: nothing is removed, as for every write
  (exit 4 or skipped, as today).

## Requirements

### The device's decision

- **FR-001**: The device description (installer spec 002) has `keep_updates`, a whole
  number of 1 or more, in its `[data_partition]` section: how many earlier deployments
  the device keeps for going back. Missing means 1.
- **FR-002**: The device's package derives `KEEP_UPDATES` in `deploy.conf` from it, with
  the other device facts; it is never set by hand.
- **FR-003**: The release's least size for the system partition (installer spec 002
  FR-019a) counts `keep_updates` base updates instead of a fixed number: one base as
  received + 64 MiB × `keep_updates` + the kernel modules, × 1.25, at least 1 GiB,
  rounded up to a whole MiB.
- **FR-004**: The descriptions: the Onyx Boox Note Air keeps 1 (its data partition is
  the smallest it has room for: a deployment costs it 0.7 to 1.3 GB); the generic UEFI
  PC keeps 4.

### What is kept

- **FR-005**: An **earlier deployment** is one that was current and no longer is. Its
  `meta` gets `current_until=<time>` (seconds since the epoch) when another deployment
  is accepted over it; one without the key uses `created`. This is an added key:
  `state/format` stays at 1.
- **FR-006**: At every clean-up point of 002 (after a switch, after an accept, before
  a stage or reset), before the unused bases and module sets:
  1. Always kept (as today): the booted deployment, current, previous, candidate,
     staged, the last failed one, a mounted one, and every pinned one.
  2. Of the earlier deployments, the `KEEP_UPDATES` most recent by `current_until`,
     previous and pinned ones counted among them, are kept; older ones are removed.
  3. Room: while the system partition's free space is under one update's room
     (64 MiB × 1.25) or the data partition's under the room a replay needs
     (002's estimate) plus the hibernation reserve, the oldest earlier deployment that
     isn't previous or pinned is removed, one at a time, re-reading the free space after
     each and after its base goes (bases free their space only when no deployment uses
     them).
- **FR-007**: Removal works as `remove` does (002: rename, then delete; never a mounted
  one). Each removal is one line on stdout and in the kernel log with the id and why
  (`count` or `room`). A removal that fails is logged and never fails the command.
- **FR-008**: `status` reports `keep_updates=<N>`; `list` reports `pinned=yes|no` and
  `current_until` for every deployment.

### Pinning

- **FR-009**: `glassine-deploy pin ID` and `unpin ID` set and clear `pinned=1` in the
  deployment's `meta`, with the state lock and an atomic write. Any deployment can be
  pinned; a staged or failed one is still removed when it's replaced as today, unless
  pinned.
- **FR-010**: `remove ID` refuses a pinned deployment (exit 1, said) until it is unpinned.

### Interface

- **FR-011**: The added keys, commands and porcelain fields are documented in
  `docs/deployments.md` and follow its compatibility rule: added fields only, porcelain
  format 1, existing exit codes.

## Key entities

- **Keep updates**: the device's number of earlier deployments to keep, from its
  description; also what its system partition is sized for.
- **Earlier deployment**: one that was current once and was replaced by an accept.
- **Pinned deployment**: kept until the person unpins it.

## Success criteria

- **SC-001**: In host tests, with keep updates 1 and 4, no sequence of accepts, stages,
  switches, pins and interruptions ever removes a deployment of FR-006 step 1, and the
  number of earlier deployments left after each accept is the count (or fewer only when
  room is short, each such removal logged `room`).
- **SC-002**: A release for a device that keeps 4 states a larger least system
  partition than one that keeps 1, by 4 × 64 MiB × 1.25 minus 64 MiB × 1.25.
- **SC-003**: On the Note Air, after this feature, the clean-up keeps current and
  previous only (keep updates 1), as before it.

## Assumptions

- A base update costs about 64 MiB on the system partition (an incremental stream of a
  normal update), as the release's size rule already assumes; a change of Alpine branch
  costs more and is covered by the room rule (FR-006 step 3), not the count.
- Deployments cost space on the data partition (their build and switch layers), bases on
  the system partition; both limits are checked.
