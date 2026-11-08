# Feature Specification: Kernel records, trial and hand-off

**Feature branch:** `kernel-records`
**Created:** 2026-11-07 · **Status:** phases 1 and 2 built and host-tested (nothing run
on a device)
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
the trial and the interlocks with `glassine-deploy` and `glassine-hibernate`, with the
`bootpart-test` hand-off and the empty one ("kernel updates are paused"). The
`blocklist` hand-off plugs in later (hub#56). The plain layout keeps today's
`glassine-bootimg` unchanged.

Two phases, one pull request each:
1. The records, the commands, and every guard that has to exist as soon as a candidate
   or a `rollback` can: `glassine-deploy`'s interlocks and `glassine-hibernate`'s
   refusal. Without the refusal, a `rollback` to another release loses a hibernated
   session without warning: the resume is refused and the image invalidated, by the
   guard's `krel` and `kver` check (`lib/glassine-root.sh:166-169`).
2. The trial: the initramfs, promote's verdict, and the finishing boot.

Each story says which phase it belongs to.

## User scenarios and testing

### Story 1: install a kernel (P1, phase 1)

1. **Given** the deployments layout, `modules/<release>/` with its `kernel.manifest` and
   `Image.gz`, and the device tree and initramfs in `boot/`, **when**
   `glassine-bootimg install <release>` runs with `HANDOFF=bootpart-test`, **then** it
   packs the image, writes `state/bootimg/<id>.img` and `<id>.manifest`, writes the test
   slot (FR-008), and sets `candidate`, `candidate_img` and `tries=1` in `state/kernel`.
2. **Given** `HANDOFF` empty, **then** `install` refuses with "kernel updates are paused"
   and writes nothing.
3. **Given** `HANDOFF=blocklist`, **then** `install` refuses ("not built yet: hub#56") and
   writes nothing.
4. **Given** a release whose `modules/<release>/` is missing, whose image string doesn't
   match the release, or whose packed image doesn't fit the slot, **then** it refuses and
   writes nothing.
5. **Given** a deployment candidate or a staged deployment, **then** `install` puts the
   release in `deferred` and exits 0. **Given** a kernel trial running (this boot is the
   candidate's), the same. It defers only after the checks of FR-005 and FR-006 (an
   install they refuse isn't deferred), and keeps the device tree and initramfs it
   checked in `deferred_dtb` and `deferred_initramfs`, for the deferred install.
6. **Given** a kernel candidate with `tries=1` (its trial hasn't started), **then** a new
   `install` replaces it and says so. It first clears the old candidate's keys and
   `requested`, then writes the test slot. If that write fails, no candidate is left,
   and `install` says so (FR-008).
7. **Given** a kernel candidate with `tries=0` on a boot that isn't the candidate's (the
   trial ended without a verdict, and promote hasn't run yet), **then** `install` gives
   the verdict first, the one promote would give (FR-012: failed, reason `no-verdict`),
   and then installs.

### Story 2: the trial (P1, phase 2)

1. **Given** a candidate, **when** `glassine-bootimg reboot-test` runs, **then** it
   re-checks the test slot against the candidate's manifest (FR-008), writes
   `requested=<candidate_img>` and reboots with the board's reason. If the slot doesn't
   match, it refuses and names `retry`. While a deployment is a candidate or staged, it
   refuses: one trial at a time. (`reboot-test` ships in phase 1.)
2. **Given** the boot of the candidate's image (`glassine.img=` = `candidate_img`),
   **then** the initramfs takes the try and clears `requested` in one write (`tries=0`
   `requested=`), boots `current` (the deployment) without a deployment pick or try,
   and never resumes a hibernated session.
3. **Given** that trial is healthy, **then** promote accepts: the default slot is written
   with the procedure of FR-009, then `current` ← candidate and `previous` ← the old one,
   both release and image, and `requested`, `writing` and `writing_op` are cleared.
4. **Given** the trial fails its health check, **then** promote marks the candidate
   failed (`failed`, `failed_img`, and `reason` in its manifest), and the default slot
   is untouched. **Given** a later boot of another image while the candidate has
   `tries=0`, **then** promote marks it failed with reason `no-verdict` (it hung,
   crashed or rebooted before the check).
5. **Given** `requested` = `candidate_img`, `tries=1` and a boot of another image,
   **then** promote marks the candidate failed with reason `no-boot` and clears
   `requested`. `no-boot` means the candidate never reached the initramfs: the kernel
   died before it, or the reboot never happened. `status` says both and offers `retry`.
   A `requested` that names another image than `candidate_img` is stale: it is cleared
   and logged, and nothing is failed. On the boot that ran `reboot-test` (a marker in
   `/run`), the shutdown is under way, and promote judges nothing.
6. **Given** `writing` set, **when** a boot runs, **then** promote checks the default
   slot before it does anything with `writing` (FR-010). If it holds the image
   `writing` names, it completes `writing_op`. If not, the write didn't finish, and
   promote writes it again from `state/bootimg/<writing>.img` (FR-009), then completes
   `writing_op`. If that write fails too, `writing` stays, `status` says
   `state=writing` with `default_slot=bad`, and nothing reboots.
7. **Given** a boot whose `glassine.img=` equals `writing` (a finishing boot), **then**
   the initramfs takes no try and resumes no hibernated session, and boots `current` as
   in a trial. Promote then does what 2.6 says.

### Story 3: undo (P1, phase 1)

1. **Given** a candidate, **when** `glassine-bootimg cancel` runs, **then** `candidate`,
   `candidate_img`, `tries` and `requested` are cleared, the default boot isn't touched,
   and the files are kept.
2. **Given** `cancel` during the trial boot itself, **then** promote finds no candidate
   and gives no verdict. The next boot is the old kernel. A `deferred` release stays in
   `deferred`, and promote installs it on that next boot. `glassine-hibernate` refuses
   until then (FR-014).
3. **Given** a previous image (`previous_img` set, its `.img` kept), **when**
   `glassine-bootimg rollback` runs, **then** the default slot gets that image (FR-009),
   and `current` and `previous` swap. Without `previous_img`, it refuses: "no previous
   image" (FR-015). A kernel candidate is cancelled in the same state write that sets
   `writing`, so a write that fails and is put back (FR-009) leaves it set.
4. **Given** a kernel candidate, **then** `glassine-deploy select`, `stage` and `reset`
   refuse with exit 8 and name `glassine-bootimg cancel`. `reset --now` and `rollback`
   cancel it first and say so.
5. **Given** a kernel candidate and a staged deployment, **then** the shutdown switch
   leaves the deployment staged.
6. **Given** a failed candidate whose image is still in `state/bootimg`, **when**
   `glassine-bootimg retry` runs, **then** the test slot is written again from it if it
   no longer matches (FR-008), and it becomes the candidate again (`tries=1`), with
   `failed` and `failed_img` cleared. While a deployment is a candidate or staged, it
   refuses, as `reboot-test` does.

### Story 4: see the state (P2, phase 1)

1. **Given** any state, **when** `glassine-bootimg status` runs, **then** it prints
   `format=1` and the keys of FR-017. In the plain layout it prints today's one line.

## Requirements

- **FR-001** `ROOT_LAYOUT=deployments` selects the records of this spec. `plain` keeps
  today's files under `/var/lib/glassine-bootimg`, and its tests are unchanged.
- **FR-002** `state/kernel` holds the keys of kernel-artifacts.md: `current`,
  `previous`, `current_img`, `previous_img`, `candidate`, `candidate_img`, `tries`,
  `failed`, `failed_img`, `deferred` (with `deferred_dtb` and `deferred_initramfs`),
  `requested`, `writing` and `writing_op`. Every
  write goes through `gs_update` under `state/.lock` (busy: exit 6, as `glassine-deploy`).
  A newer `state/format` is refused (exit 3).
- **FR-003** `state/bootimg/<id>.manifest`: `format=1`, `id`, `release`, `size`,
  `sha256`, `staged` (UTC), `reason`, and the boot record (`device`, `kernel`, `dtb`,
  `initramfs`, `cmdline`, `board`). `<id>.img` is kept for `current_img`,
  `previous_img`, `candidate_img`, `failed_img` and `writing`, and removed otherwise.
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
- **FR-008** `bootpart-test` needs a spare test slot. `install` refuses when `TEST_DEV`
  is the recovery partition (its partition name is `recovery`): there the recovery
  stays permanently (decision 0010). `conf/board.conf.example`'s development flow uses
  it, so that board needs another `HANDOFF`.
  - The test slot is written with FR-009's write and read-back, but without the RAM copy:
    the test slot is no one's default.
  - The old candidate is cleared before the write, so a failed write leaves no
    candidate whose image is gone from the slot.
  - `reboot-test` and `retry` compare the test slot's first `size` bytes with the
    candidate's `sha256` before anything else, and `reboot-test` reboots with
    `TEST_REBOOT_REASON`.
- **FR-009** Every write of the default slot, for every hand-off (accept, `rollback`,
  and promote's write again of FR-010), follows blocklist.md's "Writing the default
  slot":
  - the default image's own bytes kept in RAM, never the whole partition;
  - `writing` and `writing_op` set before the write;
  - written and read back with `O_DIRECT`, the first 4 KiB zeroed first and written
    last, with one retry.

  On failure while Linux runs, the RAM copy goes back the same way:
  - If that passes, `writing` and `writing_op` are cleared, and `state/kernel` is as
    before the command, except that a failed accept marks the candidate failed (reason
    `default slot write`), and a `current_img` seeded by this command (FR-015) stays,
    since it names the image the slot holds again. The command exits 1.
  - If it fails too: `repair` isn't in this feature, so `writing` stays, `status` says
    `state=writing` with `default_slot=bad`, the command exits 1, and nothing reboots.
    On `bootpart-test`, the way out is the test slot's image, if the bootloader can
    still be brought to boot it (not verified). Its promote then writes the default
    slot again (FR-010).

  A promote write again (FR-010) has no RAM copy, because the slot holds nothing good
  to keep. This also replaces today's whole-slot `prev.img` in this layout.
- **FR-010** When `writing` is set, promote never trusts `glassine.img=` alone: on
  `bootpart-test`, the test slot can boot the very image `writing` names while the
  default slot is still cut. Before it completes `writing_op` or clears `writing`,
  promote compares the sha256 of the default slot's first `size` bytes (`O_DIRECT`)
  with the manifest of `writing`'s image. This applies to every boot, whatever its
  `glassine.img=`:
  - **It matches:** `writing_op` is completed (kernel-artifacts.md, "A kernel trial").
  - **It doesn't:** the write is done again (FR-009, without a RAM copy), and then
    completed. If that fails, see FR-009's last case.
- **FR-011** The initramfs reads `state/kernel` before `gr_resume`, with the system
  partition mounted `ro,rescue=nologreplay`. A boot of `writing` is a finishing boot,
  one of `candidate_img` a trial.
  - Both boot `current` through a new `gr_boot` mode with no deployment pick or try,
    and neither resumes a hibernated session.
  - Only a trial takes the try; it clears `requested` in the same write.
  - With a state format newer than the initramfs, the boot is neither, and
    `state/kernel` isn't written.
  - On `bootpart-test` in developer mode, a trial boot runs the default boot without
    waiting for the host, as today's `AUTOTEST` does (`initramfs/init`) (phase 2).
- **FR-012** `glassine-bootimg-promote`, at every boot of this layout, in this order:
  1. `writing` (FR-010);
  2. `requested` (Story 2.5);
  3. the verdict: on a trial, the system it ran, then today's `health` (the generic checks
     and `health.d`), then accept or fail. A trial fails (`reason` `health: ...`) when
     `/run/glassine/booted` is missing, a bare boot or not `state/deploy`'s `current`, or
     when `/lib/modules/<release>` isn't bound; a candidate at `tries=0` on another boot is failed with reason
     `no-verdict`. The generic check of a read-write root checks `/var` in this layout
     (reason `var-not-rw`), because `/` is a read-only bind there (`docs/boot.md`);
  4. a `deferred` install, with the lock held from clearing its keys through the install.
     One that fails writes the notice, and isn't tried again.

  `glassine-deploy-accept` doesn't run on a trial or a finishing boot (phase 2).
- **FR-013** Who clears `requested`:
  - an `install` that replaces a candidate;
  - the trial boot (the initramfs, with the try);
  - promote, for `no-boot` and for a stale value;
  - accept and a finishing accept;
  - `cancel`.

  Trial fail needs no clear, because the trial boot already did it.
- **FR-014** `glassine-hibernate` refuses (exit 3, with the reason) when the next boot
  could run another kernel than the running one, or skip the resume. That is the case
  when:
  - the running `glassine.img=` isn't `current_img` (a trial, a cancelled trial, a
    `rollback` since this boot);
  - with `current_img` empty, `uname -r` isn't `current`;
  - `writing` is set.

  It ships in phase 1, with `rollback`.
- **FR-015** The first `current_img`. After the migration to this layout, `state/kernel`
  has only `current` and `previous` (`docs/deployments.md`), and nothing names the
  running image.
  - The first accept (or `rollback`) whose `current_img` is empty saves FR-009's RAM copy
    as `state/bootimg/<id>.img`, with a manifest. `<id>` is the `glassine.img=` in that
    copy's header, the release is `current`, the boot-record fields are empty, and
    `seeded=1` marks it.
  - It does so only if the copy is a valid boot image whose command line has a
    `glassine.img=`, and whose kernel carries the `current` release string. That is the
    packer's own `--expect-release` check. Then `previous_img` ← `<id>`.
  - Otherwise nothing is seeded, `previous_img` stays empty, and `rollback` is
    unavailable until the second accept.
- **FR-016** Busybox ash for everything the initramfs or the recovery runs. Python only
  in the packer, as today.
- **FR-017** `status` in this layout prints `format=1`, then `state=`, then every key of
  FR-002 that is set except `deferred_dtb` and `deferred_initramfs` (the deferred
  install's inputs), `reason=` for a failed candidate, and `default_slot=bad` after a
  failed check or write (FR-009, FR-010). `state=` is one of:
  - `none`;
  - `candidate`;
  - `trial`;
  - `finishing`;
  - `writing` (`writing` set on a boot that isn't a finishing boot);
  - `failed`.

  Readers ignore unknown keys; a key changing meaning bumps `format`.

## Decisions this spec adds to the contract (for review)

| What | Proposed | Where it goes when implemented |
|---|---|---|
| board key `DEVICE` | the device name used in `<device>@<id>` | boot.md, `conf/board.conf.example` |
| `install` flags | `--dtb <device>@<id>`, `--initramfs <commit12>`, with the defaults of FR-005 | kernel-artifacts.md, "Order on the device" |
| `status` format 1 | `format=1`, `state=`, the keys, `default_slot=` (FR-017) | kernel-artifacts.md, "What the user sees" |
| the default-slot write | blocklist.md's procedure for every hand-off (FR-009), checked again by promote (FR-010) | kernel-artifacts.md, beside `writing` (the check is in this pull request) |
| failure reasons | `no-boot`, `no-verdict`, `default slot write`, and the health check's own | kernel-artifacts.md, "Records" |
| `bootpart-test` | needs a spare test slot, not the recovery partition (FR-008) | kernel-artifacts.md, the hand-off table |
| `seeded=1` | marks the manifest of the first `current_img` (FR-015) | kernel-artifacts.md, "Records" |
| `glassine-bootimg` exit codes in this layout | 0, 1, 2 as today; 3 newer state format; 6 busy | kernel-artifacts.md |

## Not in this feature (later)

- `receive --boot`, and `bases remove` for modules and `boot/` files.
- The feature table (`conf/kernel-features`), the `provides`/`needs` coverage of a
  deployment, and exit 8 "not covered by the current kernel".
- The `DEVICE_PART` seed, and the firmware bind of "On the system partition".
- `glassine-hibernate`'s refusal while `DEVICE_PART` is read-write (it comes with the
  seed).
- The `blocklist` hand-off (hub#56) and `repair`, which the recovery runs.

## Success criteria

- **SC-001** `make check` passes with a check per acceptance scenario, and these failure
  cases:
  - a cut default-slot write, a read-back mismatch, a failed write put back from RAM,
    and a RAM restore that fails too (`state=writing`, `default_slot=bad`);
  - a finishing boot whose default slot doesn't match `writing`'s image (written again,
    then completed);
  - `writing` set with another `glassine.img=`, matching and not matching;
  - the `requested` rows: `no-boot`, a stale value, and a replace while `requested` is
    set;
  - `install` with `tries=0` on a boot that isn't the trial;
  - `cancel` during a trial, with a `deferred` release;
  - a failed test-slot write during a replace, and `reboot-test` with a test slot that
    doesn't match;
  - the newer-state-format refusal (exit 3) and a held lock (exit 6);
  - `glassine-hibernate` refused after a `rollback` and during a trial;
  - the first accept with an empty `current_img`, seeded and not seeded.
- **SC-002** The plain layout's existing `test/bootimg` checks pass unchanged.
- **SC-003** Nothing here is called hardware-proven before hub#57.
