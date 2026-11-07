# Feature Specification: Kernel records, trial and hand-off

**Feature branch:** `kernel-records`
**Created:** 2026-11-07 · **Status:** draft, under review; nothing implemented
**Builds on:** [001-deployments](../001-deployments/spec.md) · **Interface:**
[docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) ("Kernel records, trials and
hand-off", "Records", "Packing", "Order on the device", "What the user sees"),
[docs/blocklist.md](../../docs/blocklist.md) (the default-slot write) · **Ticket:**
[hub#60](https://github.com/GlassineOS/hub/issues/60), for
[hub#56](https://github.com/GlassineOS/hub/issues/56)

## Summary

In the deployments layout, a kernel becomes current only after a trial boot. Its
records live on the system partition, the same on every device. Only the hand-off to the
bootloader differs per board (`HANDOFF`). This feature builds the records, the commands,
the trial and the interlocks with `glassine-deploy`, with the `bootpart-test` hand-off and
the empty one ("kernel updates are paused"). The `blocklist` hand-off plugs in later
(hub#56). The plain layout keeps today's `glassine-bootimg` unchanged.

Phases, one pull request each (hub#60): 1 the records and commands, 2 the trial, 3 the
interlocks. Each phase's stories say which phase they belong to.

## User scenarios and testing

### Story 1: install a kernel (P1, phase 1)

1. **Given** the deployments layout, `modules/<release>/` with its `kernel.manifest` and
   `Image.gz`, and the device tree and initramfs in `boot/`, **when**
   `glassine-bootimg install <release>` runs with `HANDOFF=bootpart-test`, **then** it
   packs the image, writes `state/bootimg/<id>.img` and `<id>.manifest`, writes the test
   slot (read back), and sets `candidate`, `candidate_img` and `tries=1` in
   `state/kernel`.
2. **Given** `HANDOFF` empty, **then** `install` refuses with "kernel updates are paused"
   and writes nothing.
3. **Given** `HANDOFF=blocklist`, **then** `install` refuses ("not built yet: hub#56") and
   writes nothing.
4. **Given** a release whose `modules/<release>/` is missing, whose image string doesn't
   match the release, or whose packed image doesn't fit the slot, **then** it refuses and
   writes nothing.
5. **Given** a deployment candidate or a staged deployment, **then** `install` puts the
   release in `deferred` and exits 0. **Given** a kernel trial running, the same.
6. **Given** a kernel candidate that hasn't started its trial, **then** a new `install`
   replaces it, and says so.

### Story 2: the trial (P1, phase 2)

1. **Given** a candidate, **when** `glassine-bootimg reboot-test` runs, **then**
   `requested=<candidate_img>` is written and the board's reboot follows.
2. **Given** the boot of the candidate's image (`glassine.img=` = `candidate_img`),
   **then** the initramfs takes the try (`tries=0`), boots `current` (the deployment)
   without a deployment pick or try, and never resumes a hibernated session.
3. **Given** that trial is healthy, **then** promote accepts: the default slot is written
   with the procedure of FR-009, then `current` ← candidate and `previous` ← the old one,
   both release and image.
4. **Given** the trial fails its health check, or a boot of another image follows a
   trial that took its try, **then** the candidate is marked failed (`failed`,
   `failed_img`, and `reason` in its manifest), and the default slot is untouched.
5. **Given** `requested` set, `tries=1` and a boot of another image, **then** the
   candidate is failed with the hand-off's reason, and `requested` is cleared.
6. **Given** `writing` set, **when** the boot runs the image `writing` names, **then** it
   is a finishing boot: no try is taken, and promote completes `writing_op`.

### Story 3: undo (P1, phases 1 and 3)

1. **Given** a candidate, **when** `glassine-bootimg cancel` runs, **then** the candidate
   keys are cleared, the default boot isn't touched, and the files are kept (phase 1).
2. **Given** a previous kernel, **when** `glassine-bootimg rollback` runs, **then** the
   default slot gets the previous image (FR-009), and `current` and `previous` swap
   (phase 1).
3. **Given** a kernel candidate, **then** `glassine-deploy select`, `stage` and `reset`
   refuse with exit 8 and name `glassine-bootimg cancel`, while `reset --now` and
   `rollback` cancel it first and say so (phase 3).
4. **Given** a kernel candidate and a staged deployment, **then** the shutdown switch
   leaves the deployment staged (phase 3).

### Story 4: see the state (P2, phase 1)

1. **Given** any state, **when** `glassine-bootimg status` runs, **then** it prints
   `format=1` and the keys of FR-011. In the plain layout it prints today's one line.

## Requirements

- **FR-001** `ROOT_LAYOUT=deployments` selects the records of this spec. `plain` keeps
  today's files under `/var/lib/glassine-bootimg`, and its tests are unchanged.
- **FR-002** `state/kernel` holds the keys of kernel-artifacts.md: `current`,
  `previous`, `current_img`, `previous_img`, `candidate`, `candidate_img`, `tries`,
  `failed`, `failed_img`, `deferred`, `requested`, `writing` and `writing_op`. Every
  write goes through `gs_update` under `state/.lock` (busy: exit 6, as `glassine-deploy`).
  A newer `state/format` is refused (exit 3).
- **FR-003** `state/bootimg/<id>.manifest`: `format=1`, `id`, `release`, `size`,
  `sha256`, `staged` (UTC), `reason`, and the boot record (`device`, `kernel`, `dtb`,
  `initramfs`, `cmdline`, `board`). `<id>.img` is kept for `current_img`,
  `previous_img`, `candidate_img` and `writing`, and removed otherwise.
- **FR-004** Packing in this layout takes the kernel from `modules/<release>/Image.gz`,
  and the device tree and initramfs from `boot/`, through `lib/glassine-bootimg-pack`
  with `--expect-release`. The board's `KERNEL`, `DTB` and `INITRAMFS` aren't used.
- **FR-005** The device tree is `--dtb <device>@<id>`, or else the entry for board key
  `DEVICE` in the kernel's `dtbs`. The initramfs is `--initramfs <commit12>`, or else
  the one in `current_img`'s boot record. Neither present: refuse, naming the flag.
- **FR-006** Before the hand-off, `install` checks rule 1 (`provides` covers the
  initramfs's `needs`) and rule 3 (the slot size) of "Which combinations boot", and
  warns for rule 2 (`dtbs` doesn't list the tree). The deployment coverage checks wait
  for the feature table (not in this feature).
- **FR-007** `HANDOFF` is read from board.conf: `bootpart-test` (FR-008), empty (refuse),
  `blocklist` (refuse until hub#56), anything else (refuse).
- **FR-008** `bootpart-test`: `install` writes the image to `TEST_DEV` with the write of
  FR-009, but without its RAM copy, since the test slot is no one's default.
  `reboot-test` reboots with `TEST_REBOOT_REASON`.
- **FR-009** Every write of the default slot, for every hand-off (accept, `rollback`,
  `repair`), follows blocklist.md's "Writing the default slot":
  - the default image's own bytes kept in RAM, never the whole partition;
  - `writing` and `writing_op` set before the write;
  - written and read back with `O_DIRECT`, the first 4 KiB zeroed first and written
    last, with one retry;
  - on failure while Linux runs, the RAM copy written back, and `state/kernel` as
    before the command, except that a failed accept marks the candidate failed.
  This also replaces today's whole-slot `prev.img` in this layout.
- **FR-010** The initramfs reads `state/kernel` before `gr_resume`, with the system
  partition mounted `ro,rescue=nologreplay`. A boot of `writing` is a finishing boot,
  one of `candidate_img` a trial. Both boot `current` through a new `gr_boot` mode with
  no deployment pick or try; only a trial takes the try. A state format newer than the
  initramfs: neither, and `state/kernel` isn't written (phase 2).
- **FR-011** `status` in this layout prints `format=1`, then `state=` (`none`,
  `candidate`, `trial`, `finishing`, `failed`), then every key of FR-002 that is set,
  and `reason=` for a failed candidate. Unknown keys are ignored by readers; a key
  changing meaning bumps `format`.
- **FR-012** `glassine-bootimg-promote` gives the verdict with today's `health` (the
  generic checks and `health.d`). `glassine-deploy-accept` doesn't run on a trial or a
  finishing boot (phase 2).
- **FR-013** Busybox ash for everything the initramfs or the recovery runs. Python only
  in the packer, as today.

## Decisions this spec adds to the contract (for review)

| What | Proposed | Where it goes when implemented |
|---|---|---|
| board key `DEVICE` | the device name used in `<device>@<id>` | boot.md, `conf/board.conf.example` |
| `install` flags | `--dtb <device>@<id>`, `--initramfs <commit12>`, with the defaults of FR-005 | kernel-artifacts.md, "Order on the device" |
| `status` format 1 | `format=1`, `state=`, the keys (FR-011) | kernel-artifacts.md, "What the user sees" |
| the default-slot write | blocklist.md's procedure for every hand-off (FR-009) | kernel-artifacts.md, beside `writing` |
| `glassine-bootimg` exit codes in this layout | 0, 1, 2 as today; 3 newer state format; 6 busy | kernel-artifacts.md |

## Not in this feature (later)

- `receive --boot`, and `bases remove` for modules and `boot/` files.
- The feature table (`conf/kernel-features`), the `provides`/`needs` coverage of a
  deployment, and exit 8 "not covered by the current kernel".
- The `DEVICE_PART` seed, and the modules and firmware binds of "On the system partition".
- `glassine-hibernate`'s refusals (exit 3 during a trial, or with another kernel
  selected): phase 3 if small, otherwise its own ticket.
- The `blocklist` hand-off (hub#56) and the recovery's `repair`.

## Success criteria

- **SC-001** `make check` passes with a check per acceptance scenario, including the
  failure cases: a cut default-slot write, a read-back mismatch, a failed write put
  back from RAM, and a held lock.
- **SC-002** The plain layout's existing `test/bootimg` checks pass unchanged.
- **SC-003** Nothing here is called hardware-proven before hub#57.
