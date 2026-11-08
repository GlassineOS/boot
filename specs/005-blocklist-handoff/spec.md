# Feature Specification: The block-list hand-off

**Feature branch:** `kernel-blocklist`
**Created:** 2026-11-08 · **Status:** spec, for review; nothing built
**Builds on:** [004-kernel-records](../004-kernel-records/spec.md) · **Interface:**
[docs/blocklist.md](../../docs/blocklist.md), and
[docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) for the records and the trial
· **Ticket:** [hub#56](https://github.com/GlassineOS/hub/issues/56), part of
[hub#53](https://github.com/GlassineOS/hub/issues/53)

## Summary

`HANDOFF=blocklist` is the Linux side of a cold boot from a kernel file, for a board with
no spare slot. `install` stores the candidate as an immutable file on userdata and writes
its storage blocks into a 4 KiB record inside the default slot. `reboot-test` reboots with
a reason of its own, and on that one boot the bootloader reads the record, checks the
image and boots it. The records, the trial and the verdict are 004's and don't change.

blocklist.md is the design. This spec doesn't repeat it. It says what is built in which
phase, and it settles the places where the design and the code from 004 differ
("Decisions", below).

**What this doesn't need yet:** the bootloader reader (hub#55) and the kernel's
`mode-blocklist` (`linux`) don't exist. A search of `abl` at 72f107b and `linux` at
d476aaa finds neither. The tests use a simulated reader, which follows blocklist.md's
acceptance rules. No board sets `HANDOFF=blocklist`, and none may until blocklist.md's
"Board keys" conditions hold. Nothing here runs on a device (hub#57).

## Phases

Each phase is one pull request, with its failure cases tested.

1. **The library** (`lib/glassine-blocklist`, the packer's limit, the board keys): no
   command changes, and `install` keeps refusing `blocklist`.
2. **The commands:** `install`, `reboot-test`, `retry`, `cancel`, `accept`, fail,
   `rollback`, promote's `handoff` verdict and the simulated-reader scenarios. This
   phase ends the refusal.
3. **`repair`**, what the recovery runs when the default slot can't boot.

## User scenarios and testing

### Story 1: try a kernel (P1, phase 2)

1. **Given** `HANDOFF=blocklist` and every check of FR-005, **when** `install <release>`
   runs, **then** the steps of blocklist.md run in order: the record cleared, the image
   stored, its extents mapped and checked, read back through the raw partition, the
   record written, then the candidate keys. A cut install leaves at worst a record and no
   candidate.
2. **Given** a candidate, **when** `reboot-test` runs, **then** it checks FR-007 again,
   sets `requested` and reboots with `BLOCKLIST_REBOOT_REASON`. A file that moved or
   changed is refused, and the message names `install`.
3. **Given** the simulated reader and a record that passes, **then** it returns exactly
   the candidate's bytes. **Given** a boot that fails, hangs or fails its health check,
   **then** the next boot is the default slot's, the candidate is failed and its record
   is cleared, with no manual step. (hub#56's "done when".)

### Story 2: the verdict (P1, phase 2)

1. **Given** a healthy trial, **then** the image is copied to the system partition
   (FR-009), the accept of 004 writes the default slot, then the record is cleared. A cut between those two is cleared by FR-010.
2. **Given** `requested` = the candidate, `tries=1` and another image's boot, **then**
   promote runs FR-007's checks: if they fail, the reason is `handoff`; if they pass,
   or can't run, `no-boot`. A `glassine.handoff_err=` on the command line decides it instead.
3. **Given** `cancel`, on any boot, **then** the record is cleared with FR-003's check,
   then the candidate keys. The file stays. A clear that fails is logged, and the cancel
   goes on: without the reason, the record is never read.

### Story 3: undo (P1, phases 2 and 3)

1. **Given** `rollback` and a previous image, **then** 004's rollback runs, under the
   battery rule, from the system partition's copy. A format of userdata doesn't affect it.
2. **Given** `retry` of a failed candidate whose file is there, **then** steps 4 to 7 of
   `install` run again.
3. **Given** a default slot that can't boot, **when** `repair` runs (phase 3), **then**
   it writes the image `writing` names for an accept or rollback (leaving `writing` set),
   else `current_img`'s (`writing_op=repair`). Both come from the system partition and are
   checked against their manifests first. It is ash only, packs nothing and doesn't need
   userdata.

## Requirements

- **FR-001** `lib/glassine-blocklist` encodes and fully decodes format 1, maps a file
  with `FIEMAP` and refuses the extent flags blocklist.md lists, and reads a file's bytes
  back through the raw partition with `O_DIRECT`. Python 3, standard library only
  (Decision 1). The record's only other reader is an ash helper in
  `lib/glassine-kernel.sh`, which reads the magic and the image id and zeroes a record.
- **FR-002** The record is 4096 bytes at `size - 65536` of `BLOCKLIST_RECORD_PART`, `size`
  from `blockdev --getsize64`. It is written, cleared and read back with direct I/O
  (busybox `dd` `iflag=direct`, `oflag=direct` for the ash helper).
- **FR-003** Before any record write, the default image's end is worked out from its
  header. A slot with no header v0, or whose image reaches the record area, is refused.
  The image's own bytes are kept in RAM (004's `gk_ram`), compared by sha256 after the
  write, and written back on a mismatch.
- **FR-004** The packer's limit is `PART_SIZE - 65536` on a board with
  `HANDOFF=blocklist`. Other boards keep `PART_SIZE`.
- **FR-005** `install` adds to 004's checks: the bootloader (Decision 2), the running
  kernel's `reboot_modes`, `mode-blocklist` in the candidate's device tree, and
  userdata's: mounted, not `data=journal`, 4096-byte blocks, no encryption on the
  directory. The system partition must have room for the image (FR-009). On a bare boot
  it refuses.
- **FR-006** An image the bootloader reads, `candidate_img` or `failed_img`, is
  `<USERDATA_MNT>/<USERDATA_PREFIX>/kernel/<id>.img`. An image that Linux or the recovery
  writes to the default slot is `state/bootimg/<id>.img` on the system partition, as in
  004: `current_img`, `previous_img`, `writing`, and the seed of 004's FR-015 (Decision 5).
  The manifests stay in `state/bootimg/`. Packing happens on userdata, not in `/run`
  (Decision 4).
- **FR-007** The checks `reboot-test` repeats: the record names `candidate_img`, the
  extents still pass, and the raw read-back matches. The running kernel still lists the
  mode, and the battery rule holds (`SWITCH_MIN_CAPACITY`, or a charger).
- **FR-008** Kept: on userdata, the files of `candidate_img` and `failed_img`
  (Decision 7); on the system partition, those of `current_img`, `previous_img` and
  `writing`. Others are removed (on userdata `chattr -i`, then `rm`), never one a record
  names.
- **FR-009** Before an accept sets `writing`, the candidate's file is copied to
  `state/bootimg/<id>.img` and checked against its manifest. From there the default-slot
  write is 004's, unchanged. A copy that fails leaves the default slot untouched and
  fails the candidate like a failed default-slot write. Nothing is packed again, by
  `rollback` or `repair`.
- **FR-010** In promote, after the verdict of 004's FR-012 and before a deferred
  install: a record that names anything but `candidate_img` is cleared, and so is any
  record when no candidate is set. That covers a cut accept, a finishing accept, and a
  candidate cancelled by `glassine-deploy` (Decision 3). On a board with this hand-off,
  promote therefore reads the record on every boot, before 004's "nothing set" return.
  That read takes no lock and writes nothing unless a record has to be cleared. Other
  boards keep the early return.
- **FR-011** Reasons added to a failed candidate's manifest: `handoff`. It is only a
  label, and the boot that fell back has already happened: if the checks can't run, the
  reason is `no-boot`. `status` is otherwise 004's FR-017.
- **FR-012** Board keys: blocklist.md's, plus `BLOCKLIST_ABL_PART` (Decision 2). No
  device constant in the tools.
- **FR-013** The simulated reader (`test/`) applies blocklist.md's "accepts a record
  only if" list, written from that list and not from the writer's code.
- **FR-014** `docs/blocklist.md` changes to match Decisions 1, 3, 5 and 7, and its status
  line stops saying "under review", in the phase that builds each.

## Decisions (for review)

| # | Decision | Why |
|---|---|---|
| 1 | Python only in `install`, `reboot-test`, `retry` and the `handoff` label. Nothing in the bootloader, the initramfs or the recovery needs it, and promote's record read and clear on every boot are ash. 004's FR-016 holds | `FIEMAP` is an ioctl with no busybox tool, and those commands already need the packer's Python. blocklist.md has the recovery carry Python for a fresh pack. Decision 5 removes that pack |
| 2 | `BLOCKLIST_ABL_SHA256` stays as blocklist.md has it, a hash of the whole partition. A new key, `BLOCKLIST_ABL_PART`, names the partition | The design names no partition, and the tools may not hard-code one. **Open, for hub#55:** the Note Air's `abl` is 1 MiB (docs 9d5d1c4, "Stock layout"). If a build is shorter and flashing leaves the old tail, a whole-partition hash differs between devices with the same build. A build's length isn't in the docs or in `abl` (72f107b). The check is a convenience, because an old bootloader ignores the reason and the trial simply fails, so it can be dropped if this proves awkward |
| 3 | `glassine-deploy`'s cancel-first leaves the record, and promote clears it (FR-010). blocklist.md has `cancel` clear it there too | That path holds the state lock and doesn't read `board.conf`, and it must never block an escape route. A stale record does nothing: only `reboot-test` sets the reason, and it checks the record names the candidate |
| 4 | Pack on userdata | `/run` already holds the RAM copy of FR-003, and whether it can hold both is open (hub#57) |
| 5 | Userdata holds only what the bootloader reads. Every image that can go back into the default slot has a copy on the system partition. blocklist.md has all of them on userdata, packed again when lost | The bootloader never reads those copies, so btrfs is fine for them. A seeded image has no recipe and can't be packed again, and it is the one kernel known to work on the device. With this, a format of userdata costs only an untried candidate, and `rollback` and `repair` need neither userdata nor Python. The cost: up to three images on the system partition during an accept, each under 64 MiB, on a 3 GiB partition in today's development layout (docs 9d5d1c4, "Development layout"; free space on a device not measured). The space check in FR-005 and the failure in FR-009 cover a full partition. Boards on `bootpart-test` already keep theirs there |
| 6 | `repair` is in this ticket, as phase 3 | hub#56 doesn't list it, but blocklist.md does, and `HANDOFF=blocklist` can't be set without it. Carrying it in the recovery image is elsewhere |
| 7 | `failed_img`'s file is kept too. blocklist.md's list leaves it out | The same page keeps a failed candidate's file for `retry`, and 004's `gk_prune` already keeps `failed_img` |

## Not in this feature

- The bootloader reader (hub#55), `mode-blocklist` in `linux`, and the on-device test
  (hub#57).
- The recovery image carrying `glassine-bootimg repair`, with a `dd` that has `oflag=direct`
  (checked only on Alpine 3.22's BusyBox 1.37). If it hasn't, the recovery's clear fails,
  is logged, and the escape route goes on.
- Packaging. No APKBUILD in `packages` at 697b5df installs `glassine-bootimg` or
  `lib/glassine-kernel.sh`, so a device build has neither yet. That needs a ticket before
  hub#57.
- Setting `HANDOFF=blocklist` on the Note Air, which comes last.

## Success criteria

- **SC-001** `make check` covers `install`, `accept`, `cancel`, `rollback`, `retry`,
  `repair` and `reboot-test`, and blocklist.md's failure cases: a file whose blocks
  changed after `install`, a torn record, a default image that reaches the record area,
  a cut accept or rollback and a finishing boot of each, a failed default-slot write put
  back from RAM, a full system partition at accept, `rollback` and `repair` with userdata
  formatted, a promote that reads a record with no Python present, a running kernel without the reboot mode, too many extents, unwritten
  extents, and `reboot-test` during a trial.
- **SC-002** Extents, immutability and raw read-back run on a real ext4 file system on a
  loop device (`test/root`), not stubs.
- **SC-003** The simulated reader passes Story 1.3 in each of the generic trial
  scenarios.
- **SC-004** `bootpart-test` and the plain layout's checks pass unchanged.
- **SC-005** Nothing here is called hardware-proven before hub#57.
