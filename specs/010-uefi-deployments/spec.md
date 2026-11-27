# Feature Specification: Deployments on UEFI PCs

**Feature branch:** `uefi-deployments`
**Status:** spec, for review; built: the boot modules (FR-049, SC-017), the initramfs's
side of FR-005 (the identities on the command line) and of FR-042 to FR-047 (the one-shot
deployment request), and the running system's kernel hand-off (FR-025 to FR-028:
`glassine-bootimg` with `HANDOFF=uefi`), the healthy mark and the shutdown step
(FR-012, FR-023: `glassine-loader-mark`), the rollback after the limit (FR-013:
`glassine-bootimg rollback --limit`), the running system's partitions by their
identities (FR-051); nothing else
**Builds on:** [001-deployments](../001-deployments/spec.md),
[004-kernel-records](../004-kernel-records/spec.md),
[008-recovery](../008-recovery/spec.md), [009-first-start](../009-first-start/spec.md) ·
**Interfaces:** [docs/deployments.md](../../docs/deployments.md) (`glassine-deploy`, the
deployment state), [docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) (kernel
records, the trial), [docs/boot-partition.md](../../docs/boot-partition.md) (the boot
partition's layout, the loader record, a kernel set, the splash store), installer
[`devices/uefi-pc.toml`](https://github.com/GlassineOS/installer/blob/main/devices/uefi-pc.toml)
(the partitions and boot settings an install makes) · **Decisions:** docs
[0007](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0007-recovery-mainline-twrp.md),
[0010](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0010-root-and-deployments.md),
[0014](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0014-installation-and-provisioning.md)

## Summary

On a PC (x86-64) that starts from UEFI, the firmware starts one GlassineOS loader from a
boot partition GlassineOS owns. The loader starts a kernel set: a kernel, its initramfs
and its command line, tried and replaced together. The initramfs then picks and
assembles the deployment from the system partition's state, exactly as on every other
machine.

So a PC adds one thing: its kernel hand-off. Deployments, their tries, acceptance,
rollback and resets are 001's and don't change. Kernel records, the trial and the verdict
are 004's and don't change. This spec says what the boot partition holds, what the
loader does, how the recovery is reached, and what GlassineOS may touch in the firmware
and on a disk it shares with another system.

One addition reaches every machine: a deployment chosen at start-up runs for that one
start, as a request to the initramfs that changes no state.

Deployments are never firmware boot entries (0014): the firmware knows one GlassineOS
entry, however many deployments and kernels there are.

## Terms

| Term | Meaning |
|---|---|
| boot partition | The partition the installer creates for GlassineOS (`glassine-boot`): a FAT file system with long names that the firmware can read. GlassineOS owns all of it. On a PC it is always this FAT form; machines whose firmware reads no FAT use the raw form of the same partition (`docs/boot-partition.md`, "Two forms"; 012). |
| loader | The program the firmware starts from the boot partition. It starts a kernel set or the recovery. |
| kernel set | A kernel, its initramfs and its command line. The unit that is tried, accepted and rolled back (one image record of 004). |
| default set | The kernel set of the current kernel record. It starts when nothing else is asked for. |
| previous set | The kernel set of the previous kernel record. |
| trial set | The kernel set of the kernel candidate. |
| loader record | The record on the boot partition that tells the loader what to start: the default set, the previous set, a one-shot request, the count of starts not yet marked healthy. It is kept in two slots, so one of them is always whole. |
| healthy mark | The running system's statement, on the boot partition, that this start reached a healthy system. |
| our entry | The one firmware boot entry the installer made for GlassineOS. |

## User scenarios

### Scenario 1 – An ordinary start (P1)

**Given** an installed PC with an accepted deployment,
**When** it is switched on and nobody touches it,
**Then** the firmware starts the loader, the loader starts the default set, and the
initramfs picks the deployment from the system partition's state (001 FR-005). No
firmware variable is written.

### Scenario 2 – A new deployment is tried (P1)

**Given** a deployment candidate with two tries (001 Story 2),
**When** the PC starts,
**Then** the default set starts, and the initramfs counts the try and boots the
candidate. A candidate that is never accepted leaves the current deployment booting
after its tries, with no step by the person. The loader and the boot partition take no
part in this.

### Scenario 3 – A new kernel is tried (P1)

**Given** a kernel candidate (004), its trial set complete on the boot partition, and a
one-shot request for it,
**When** the PC restarts,
**Then** the loader removes the request, durably, and only then starts the trial set.
Whatever happens next (a hang, a panic, a power cut, a healthy boot), the following
start uses the default set again. The trial set becomes the default set only through
004's accept.

### Scenario 4 – The recovery, by key (P1)

**Given** a PC that is starting,
**When** the person holds or presses the recovery key during the loader's wait,
**Then** the GlassineOS recovery (008) starts from the boot partition, from memory,
whatever state the system partition is in.

### Scenario 5 – The recovery, by itself (P1)

**Given** starts in a row that no healthy mark followed,
**When** their count passes the limit,
**Then** the loader starts the previous set once, and after that the recovery. The
recovery shows which deployment and which kernel failed (008 Scenario 1). Left alone, it
restarts into the default set after its idle time (008 Scenario 6), and a new round
of counting starts.

### Scenario 6 – Another system stays as it is (P1)

**Given** a PC that also holds another operating system,
**When** GlassineOS is installed, updated, repaired or removed,
**Then** that system's partitions, its EFI system partition and its firmware boot
entries are byte for byte as they were, and the firmware's boot order differs only by
our entry.

### Scenario 7 – The firmware forgets (P2)

**Given** a firmware that lost its variables, or never honoured the boot order,
**When** the PC starts,
**Then** it starts either another system that is on the disk, or GlassineOS through the
boot partition's removable-media path. It never starts a half-written GlassineOS. Once
GlassineOS runs, it reports that our entry is missing and offers to make it again.

### Scenario 8 – A cut update (P1)

**Given** any write to the boot partition (a trial set, an accept, a rollback, a
recovery update, a healthy mark),
**When** the power is cut at any point,
**Then** the next start uses the default set as it was before the write began, or as it
is after the write completed, and nothing in between.

### Scenario 9 – An earlier deployment, once (P2)

**Given** a current and a previous deployment,
**When** the person opens the loader's list and picks the previous deployment,
**Then** that deployment starts, this once. The deployment state is not written, and
the next start without a choice runs the current deployment again.

## Requirements

### What lives where

- **FR-001** The firmware starts one loader from the boot partition. The boot partition
  holds the loader, the loader record, the default set, the previous set (when there
  is one), at most one trial set, and the recovery image. It holds nothing of the
  person's and no secret.
- **FR-002** The kernel records, the kernels, the initramfs of every kernel set as it
  was assembled and the command lines stay on the system partition, the same as on
  every machine (004). The boot partition is a copy made from them. Every file on it can
  be made again from the system partition and the recovery's own record, by copying,
  with no network.
- **FR-003** GlassineOS creates exactly one firmware boot entry. A deployment, a base or
  a kernel never adds, removes or renames a firmware boot entry. Entries the firmware
  makes by itself (for the removable-media path of FR-034, for example) are the
  firmware's.
- **FR-004** The loader finds its files on the partition it was started from. It never
  searches other disks or partitions for kernel sets, so a second GlassineOS disk, or an
  install medium, is never mixed in.
- **FR-005** The command line of every kernel set carries the unique identity of this
  installation's system partition and userdata (`glassine.system=`,
  `glassine.userdata=`; [boot.md](../../docs/boot.md#command-line-keys)), so the
  initramfs never picks another disk's. A kernel set without them is not written to the
  boot partition. The rest of a set's command line has one source, the board's
  configuration, the same one at install and at every kernel update.

### The loader

- **FR-006** With no request and the count of unmarked starts within the limit, the
  loader starts the default set.
- **FR-007** Before it starts a kernel set, the loader checks that the set is complete
  and matches the checksums the loader record names: the record names the set's own
  record by its checksum, and that names the kernel and the initramfs by theirs. The
  loader reads both files whole, checks them, and starts the kernel with exactly the
  bytes it checked; the kernel reads nothing from the boot partition after that. A set
  that fails the check is not started; the loader goes on to the next choice: the
  default set, then the previous set, then the recovery.
- **FR-008** A slot of the loader record that is missing, cut or fails its own check
  counts as absent. A write goes only to the slot that is not in use, so the record it
  replaces stays whole until the new one is durable, and the loader uses that one
  instead, without its request. With no valid slot at all, the loader starts the
  recovery, which it finds in its fixed place by the recovery's own record. It never
  starts a trial set without a valid record that requests it.
- **FR-009** A one-shot request (the trial set, or the recovery) is removed from the
  loader record before the loader acts on it, and the removal is durable. If the loader
  can't write the boot partition, it doesn't start a trial set: it starts the default
  set and leaves the request for the running system to fail (004: the trial never
  started).
- **FR-010** A trial set starts at most once per request. Nothing the loader does makes
  a trial set the default set.
- **FR-011** The loader counts every start of the default set and the previous set in
  the loader record before it starts the set. The count is cleared by the healthy mark.
  When the count has reached the limit, the next start uses the previous set; the start
  after that uses the recovery. With no previous set, the recovery comes at once. The
  loader records which set it started and why, so the running system can tell a start
  the limit caused (FR-013).
- **FR-012** A start that ends in an orderly shutdown or restart is taken out of the
  count again, unless it was a bare boot or a health check failed in it. So a person
  who switches the PC on and off for short sessions never reaches the recovery by
  that.
- **FR-013** A start on the previous set that the limit caused, and that reaches a
  healthy system, makes the previous set the default set by 004's rollback, with no
  step by the person. The kernel that failed is listed as failed, and the person is
  told at the next login.
- **FR-014** When the recovery restarts by itself after its idle time (008 FR-013), it
  clears the count, so a new round starts with the default set. A PC with nothing that
  starts healthy, left alone, goes round by round and rests in the recovery for its
  idle time in each. A choice the person makes in the recovery also clears the count.
- **FR-015** The limit is larger than the deployment tries of 001, so a deployment
  candidate that fails and falls back to the current deployment never reaches the
  previous set or the recovery by that alone. Default: three unmarked starts.
- **FR-016** When neither the default set nor the previous set can be started, the
  loader starts the recovery. When the recovery can't be started either, it shows a
  message that names the boot partition and returns to the firmware, so the firmware
  goes on to its next entry.
- **FR-017** The loader waits for the recovery key for a short, fixed time at every
  start, and longer after a start that wasn't marked healthy. Whenever the loader runs, the key works without any
  firmware variable, loader record or system partition being intact.
- **FR-018** The loader needs no network, no firmware set-up password and no firmware
  setting other than the ones FR-032 names. It works with only a keyboard and the
  firmware's own display, and with no keyboard at all for every path that needs no
  choice.

### The form of the loader's state

- **FR-019** The loader record has one form, which the loader, the installer, the
  running system and the recovery share
  ([boot-partition.md](../../docs/boot-partition.md#the-loader-record)): a text record
  with a format version, a sequence number and its own check value, kept in two slots of
  fixed size. FAT has no step that replaces a file whole, so each change is one write of
  the slot that is not in use. A power cut at any byte of it leaves the slot in use
  untouched and the other one either whole or told as damaged by its check.
- **FR-020** Every key of the loader record has its writers
  ([boot-partition.md](../../docs/boot-partition.md#keys)). A writer changes only its
  own keys and carries every other key over as it read it.

### The running system's side

- **FR-021** The initramfs picks and assembles the deployment as 001 and
  [docs/boot.md](../../docs/boot.md) define, from the system partition's state. The
  deployment state has no copy on the boot partition and none in firmware variables.
- **FR-022** Acceptance is the shared one: the boot-success service accepts a deployment
  candidate (001 FR-018), and the kernel verdict promotes or fails a kernel candidate
  (004). Neither needs a service manager other than the base's init system, and neither
  needs the loader to implement any other system's boot counting.
- **FR-023** The healthy mark is written on every boot that reaches the health
  conditions of 001 FR-018, also when there was no candidate. A bare boot, a kernel
  trial before its verdict, and a boot that fails a health check write none. A session
  resumed from hibernation writes it after the resume.
- **FR-024** `reboot recovery` writes a one-shot request for the recovery into the
  loader record and restarts. It doesn't depend on the firmware honouring a one-time
  boot variable.
- **FR-025** The kernel hand-off of this platform is one more hand-off kind of 004
  (`HANDOFF=uefi`; 004 FR-007 and "Hand-off kinds"): a trial set is written to the boot
  partition next to the default set, never over it, and the request is written last.
  `install` assembles the set's initramfs, keeps it with the record on the system
  partition, writes the set to the boot partition and names it in the loader record as
  the trial set; `reboot-test` writes the request. Accept, rollback, cancel and a failed
  trial each change the loader record in one write, and a set nothing names any more is
  removed after it
  ([boot-partition.md](../../docs/boot-partition.md#who-assembles-a-set)).
  Accept, rollback and repair change the default set under 004's rules for a
  default-slot write that hold for every kind (004 FR-009, FR-010: the write is named in
  the kernel state before it starts, and a start in the middle is a finishing boot). The
  bytes are written as FR-027 says, never in place.
- **FR-026** The boot partition is mounted only for the time of a write, and unmounted
  again. No service keeps it mounted, and nothing reads it for the system's ordinary
  work.
- **FR-049** A PC's kernel may build the drivers of its disks and the file systems the
  start needs as modules, which live on the system partition they are needed to reach.
  So every kernel set's initramfs carries, after the GlassineOS initramfs and the
  board's configuration, that kernel's boot modules: its own
  modules for NVMe disks (and the controller in front of them), SATA, eMMC, USB disks
  and virtual disks, for the btrfs, ext4 and overlay file systems, and every module
  these depend on, hard or soft (btrfs's checksums), taken from that kernel's modules
  on the system partition. What the kernel builds in needs nothing, and a kernel with
  everything built in carries none.
  - The initramfs loads them as its first step, in dependency order: before it arms a
    watchdog, before it looks for any partition and before the hibernation step.
  - A module that fails to load is logged by name and the start goes on; boot modules
    made for another kernel load nothing, and that is logged.
  - A kernel that has btrfs, ext4 or overlay neither built in nor as a module gets no
    kernel set.
  - The initramfs itself is the same file for every kernel (004): only the boot modules
    and the microcode are the kernel's.
- **FR-050** A kernel that ships CPU microcode has it applied at every start: its
  microcode comes first in the kernel set's initramfs, before the GlassineOS initramfs,
  in the form the kernel loads early. The order of a set's initramfs is in
  [boot-partition.md](../../docs/boot-partition.md#files).
- **FR-051** The running system's tools that read or write the system partition or
  userdata outside the initramfs (the deployment tool, the first start, hibernation, the
  kernel tool, and the shutdown's read-only step) find them as the initramfs does: by the identities on
  the running kernel's command line (FR-005), never by a partition name, so a second
  disk that carries partitions of the same names (an install medium, a clone, another
  installation) is never written. A PC's system configuration names neither partition.
  - Each identity is taken when the command line gives its key exactly once, as
    `PARTUUID=` and a whole unique partition identity (compared in lower case), and
    exactly one partition carries it.
  - A key that is missing, given twice or malformed, or an identity that no partition
    or more than one partition carries, makes the tool refuse with the reason, a
    nonzero exit and no write. Two go on and say the reason instead, writing nothing to
    that partition:
    the deployment tool's status, which shows what it can read without that partition
    (a status report must work on a broken start), and the shutdown's read-only step,
    which must never stop a shutdown and leaves that partition to the shutdown's own
    handling.
  - A machine whose description fixes its partition names (one disk, its names unique)
    names both partitions in its system configuration and starts with no identities
    on its command line; the names are then used.
  - When the system configuration names a partition and the command line names one
    too, both must be the same partition; otherwise the tool refuses as above. The
    command line names what this start runs on, so a configured name that points
    elsewhere (a stale name, a second disk with the same names) is a fault, never a
    choice between the two.

### Writing the boot partition safely

- **FR-027** A file of a kernel set or of the recovery image is never changed in place.
  A new file is written under a new name, synced and read back against its checksum;
  only then does one step (a write of the loader record, FR-019) make the loader use
  it. Old files are removed only after both slots of the loader record have stopped
  naming them.
- **FR-028** Before any write, the free space is checked against what the write needs
  plus the loader record's own room. Too little: the command refuses, writes nothing
  and says how much is needed and free. It never removes the default set, the previous
  set or the recovery image to make room. A trial set that nothing requests, and files
  no record names, are removed first.
- **FR-029** The boot partition is sized by the installer from the release: room for
  three kernel sets, two recovery images (the one in place and its replacement) and the
  boot splash and its one-time override at their largest size (011), with
  as much again free. An install onto less is refused in the plan.
- **FR-030** A boot partition whose file system is damaged is rebuilt from the system
  partition by the recovery's "repair the boot" (008 FR-009), and by the installer's
  repair from removable media when the recovery itself can't start. The repair writes
  only the boot partition and, where FR-032 allows, our entry.

### The firmware and other systems

- **FR-031** GlassineOS writes firmware variables only at install, at removal, and in a
  repair the person confirmed. No start, update, trial, acceptance or rollback writes
  one.
- **FR-032** The only firmware settings GlassineOS writes are our entry and the boot
  order, and the boot order only to add or remove our entry's number. Entries GlassineOS
  didn't create are never changed, removed, renamed or moved relative to each other.
  Our entry is recognised by the boot partition's unique identity, not by its label.
- **FR-033** GlassineOS never writes an EFI system partition it didn't create, and never
  places or replaces a file another system put on one. The boot partition is its own
  partition even when the disk already has an EFI system partition.
- **FR-034** The boot partition also carries the loader at the removable-media path, so
  a firmware that lost its variables, or ignores the boot order, can still start
  GlassineOS from its boot menu or its fallback search. Correctness never depends on
  that path being used, nor on the boot order being honoured: whichever system the
  firmware starts, it starts whole.
- **FR-035** The running system and the recovery report when our entry is missing or no
  longer first, and say what the firmware starts instead. GlassineOS never moves an
  entry back by itself: the boot order is the person's, and another system's update
  may set it again. A missing entry is made again only in a repair the person
  confirmed (FR-031).
- **FR-036** GlassineOS starts only with Secure Boot off. With it off, everything in this
  spec holds, and nothing in it asks the person to change another firmware setting.
  The installer's check reads the Secure Boot state wherever it runs: from another
  system on the PC before the install medium is made, and on the install medium where
  the firmware started it. While Secure Boot is on, the check refuses the install, says
  why (the firmware would not start the loader), and says how to switch it off in the
  firmware's set-up. The install medium's instructions say the same, because a firmware
  that enforces Secure Boot doesn't start the medium at all.

### The recovery on a PC

- **FR-037** The recovery image is on the boot partition in the form of a kernel set,
  in a place of its own, and the loader starts it like one. Its record carries its own
  check value, so the loader can find and check the recovery with no loader record. It
  runs from memory (008 FR-001) and needs nothing from the system partition to start.
  Its files are the release's, written whole: nothing is assembled into them at install
  or at an update.
- **FR-038** The recovery is updated like a kernel set: the new image next to the old
  one, checked, then named in the loader record. A cut update leaves the old one in
  use.
- **FR-039** The loader shows no menu by default. During its wait, about two seconds,
  it shows one line that names the recovery key. The key opens a short list:
  GlassineOS, the previous deployment and "more" for the other deployments (FR-040),
  the previous kernel, the recovery, the firmware's set-up. A machine whose parent
  bootloader can't start a kernel set (the board says so;
  [handback.md](../../docs/handback.md#the-start-menu)) leaves the previous kernel out.
  The other system is not in
  the list; it is started from the firmware's own boot menu, so its start is never
  altered by passing through our loader.
- **FR-048** The loader is the earliest stage that owns the display on a PC, so it draws
  the boot splash and the one-time override of
  [011](../011-boot-splash/spec.md), through the firmware's graphics output, before
  the kernel starts. The line of FR-039 is drawn over the splash or the override for the wait only, and the picture under it is restored when the wait ends (011 FR-016a). A splash that can't
  be drawn never delays or stops a start.

### A deployment chosen at start-up

- **FR-040** The loader's list offers the previous deployment, named by its base's
  version as `glassine-deploy list` reports it. A base's version is the GlassineOS
  image version the base carries; a base that carries none is named by the version of
  the distribution it is built on. Where two deployments in the list would read the
  same, each of them also shows the time it was made, to the minute, or to the second
  where the minute matches too. One further entry
  opens the other deployments that can start: the candidate, the last failed one and
  every kept one. A staged deployment is not offered: it never boots (001), and the
  switch starts its layer from empty.
- **FR-041** The loader has the list from the loader record. The running system and the
  recovery write it there whenever a command changes which deployments exist or what
  they are (switch, accept, select, rollback, remove), under FR-019, and the boot-success step
  on a start that accepts nothing, so a list written before it is brought up to date.
  The loader can't
  read the system partition, so the list may be out of date; FR-043 covers that.
- **FR-042** A deployment picked in the list is a one-shot request to the initramfs,
  passed with this start only (on the kernel command line). The loader writes nothing
  for it: not to the boot partition, not to a firmware variable. A power cut, a reset or
  the next start without a choice therefore has no request, and the ordinary pick
  applies. The request (`glassine.deploy.once=`;
  [boot.md](../../docs/boot.md#command-line-keys)) is the only thing the loader adds to
  a kernel set's command line.
  Where the loader's parent bootloader passes no command line (the board says so;
  [handback.md](../../docs/handback.md#the-start-menu)), the request goes through the
  loader record instead: the loader writes the picked id as a one-shot key with the
  start's own record write, and the initramfs clears it in the record, read back,
  before it takes it. A request it can't clear is not taken, so it never outlives the
  start it was made for; any other pick clears one still there. On a PC nothing
  changes.
- **FR-043** With a request, the initramfs starts that deployment in place of the pick
  of 001 FR-005, for this start only. `state/deploy` is not written: current stays
  current, the requested deployment is no candidate, and no deployment try is used or
  given back. A request that names a deployment that isn't there, is staged or doesn't
  assemble is dropped with a message; the ordinary pick then runs, and nothing is
  marked failed.
- **FR-044** Such a start is a full start of that deployment: its writes land in its
  own layer, and the person's storage is bound as always. The boot-success service
  accepts nothing in it (the booted deployment is no candidate). When it reaches the
  health conditions, the healthy mark is written as on any start (FR-023), so it never
  counts towards the loader's limit. It can be combined with the previous kernel set.
- **FR-045** Making that deployment the current one is a separate step: the rollback or
  select of `glassine-deploy` in the running system or in the recovery (008 FR-007),
  with its try and its acceptance.
- **FR-046** A hibernated session comes first. When a resumable image is there (001
  Story 4), the initramfs resumes it, drops the request and says so. No session is lost
  to a choice in the list. A kernel trial and a finishing boot (004) take no request.
- **FR-047** The request is the initramfs's interface, not the PC's. Any machine whose
  boot chain can pass it for one start gets the same behaviour from the same
  initramfs, whatever offers the choice there.

## Key entities

- **The boot partition**: `glassine-boot`, FAT, created by the installer, owned whole by
  GlassineOS. Identified by its unique partition identity.
- **The loader record**: format version, sequence number, the default set, the
  previous set and the trial set (ids and checksums), the recovery image, a one-shot
  request, the count of unmarked starts, the set started last and why, the list of
  deployments that can be chosen at start-up, its own check value; in two slots.
  Read and written by the loader, the installer, `glassine-bootimg`, `glassine-deploy`,
  the boot-success and shutdown steps, and the recovery.
- **A kernel set**: the files of one 004 image record (the kernel, the assembled
  initramfs, the set's record), on the boot partition in a directory named by the
  record's id, so a set once written never changes.
- **Our entry**: label, the boot partition's identity, the loader's path.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The loader record | owned (new); read and written by the loader, the installer, the running system and the recovery | `format=1` | `docs/boot-partition.md`, "The loader record" |
| The boot partition's layout and fixed names | owned (new); consumed by the loader, the installer's `write-boot-files` step and its repair | `format=1` | `docs/boot-partition.md`, "Layout" |
| A kernel set: its files, the order of its initramfs, its record and id | owned (new); consumed by the loader and the installer | `format=1` | `docs/boot-partition.md`, "A kernel set" |
| The identities on the command line | owned (new); written by whatever makes a kernel set, read by the initramfs and the running system's tools (FR-051) | two command-line keys | `docs/boot.md`, "Command-line keys" |
| The one-shot deployment request to the initramfs | owned (new); device-neutral | a command-line key | `docs/boot.md`, "Command-line keys"; 001 FR-005 |
| The deployment list in the loader record | owned (new) | part of the loader record | `docs/boot-partition.md`, "Keys" |
| The healthy mark | owned (new); written by the boot-success step on every healthy boot | part of the loader record | `docs/boot-partition.md`, "Keys"; `docs/deployments.md`, "Accepting a candidate" |
| The boot modules of a kernel set (FR-049) | owned (new); consumed by whatever makes kernel sets (the installer, the boot partition's writer) | the archive's layout, unversioned (the initramfs reads the load list of its release) | `docs/boot.md` ("Boot modules"), `docs/kernel-artifacts.md` ("Packing") |
| The hand-off kind `uefi` in `HANDOFF` | owned (added value; 004 FR-007) | 004's records, unchanged | `docs/kernel-artifacts.md` |
| `state/deploy`, `state/kernel`, `glassine-deploy` | owned (unchanged) | state `version=1`, porcelain 1 | `docs/deployments.md` |
| Firmware boot entries and boot order | consumed; written by the installer (`add-boot-entry`) and the repair | UEFI | installer 002 |
| `glassine-boot` (2 GiB, role `esp`) and `glassine-userdata` | consumed; the installer's description | description `format = 4` | installer `devices/uefi-pc.toml` |

## Device scope and risk

- **Writes:** the boot partition, in the running system and the recovery. Our entry and
  the boot order, at install, removal and confirmed repair only.
- **Never written:** another system's partitions, any EFI system partition GlassineOS
  didn't create, firmware boot entries it didn't create, any other firmware setting.
- **Escape:** a broken boot partition leaves the other system starting (where there is
  one) and the installer's removable medium, whose repair rebuilds the boot partition
  from the system partition (FR-030). A broken system partition leaves the recovery,
  which starts from the boot partition alone.
- **No watchdog is assumed.** Where the PC has one the kernel can arm, the initramfs and
  the recovery (008 FR-013) arm it as on other machines, and a hang ends in a reset.
  Where it has none, a hang waits for the person to switch the PC off and on. That start
  is counted like any other, so the tries and the limit still end the loop.

## Edge cases

- **Power cut while the loader record is written:** the slot in use was not touched, so
  the old record is read, whole; once the write is durable, the new one. A slot that is
  neither is absent (FR-008).
- **Power cut after the loader counted a start and before the kernel ran:** one start is
  counted that never ran. The limit absorbs it; it can't select a trial set.
- **Power cut during a trial:** the request is already gone, so the next start is the
  default set, and 004 gives the trial its verdict (`no-verdict`).
- **Boot partition full:** FR-028. Kernel updates stop with a message; every start still
  works.
- **Boot partition read-only for the loader** (a firmware whose FAT driver can't write):
  no trial set ever starts and no start is counted, so the recovery isn't reached by
  itself. The default set starts and the key works. A request stays in the record, and
  the running system reports that the loader couldn't take it. The installer's check
  names such a firmware before the install.
- **Firmware variables reset:** Scenario 7. Nothing on a disk changed, so a repair
  restores our entry without touching the boot partition.
- **Firmware that ignores the boot order or a one-time boot variable:** nothing in this
  spec uses a one-time boot variable. If our entry is not started first after the
  install, the installer's last step (the booted, accepted first deployment of 0014) is
  not reached, and it says so and how to choose GlassineOS in the firmware's boot menu.
- **The other system writes the boot order or puts itself first:** reported (FR-035);
  nothing is undone by itself.
- **The other system, or a person, deletes files on the boot partition:** FR-007 and
  FR-016 decide the start; the repair rebuilds.
- **Two GlassineOS installs on one PC:** each has its own boot partition, entry and
  loader record; FR-004, FR-005 and FR-051 keep them apart.
- **A second disk with partitions of the same names** (an install medium, a clone):
  the running system's tools use the partitions the command line names (FR-051). A
  clone carries the same identities, so two partitions carry one: the tools refuse
  until one disk is removed.
- **The first start (009):** the bare boot writes no healthy mark and restarts once; the
  first deployment's boots follow. The limit leaves room for that restart.
- **The loader's list names a deployment that is gone:** FR-043; the ordinary pick runs.
- **A candidate with tries left, and the person picks the previous deployment:** the
  candidate keeps its tries and is tried at the next ordinary start.
- **A hibernated session:** the loader's count rises at the resume start and is cleared
  after the resume (FR-023). A kernel trial never resumes (004).
- **A PC that starts from legacy BIOS, or a 32-bit UEFI:** not this platform; the
  installer refuses with the reason.
- **Removable or external target disk:** the removable-media path of FR-034 makes it
  start on another PC; our entry exists only on the PC it was installed from.

## Success criteria

Each is a test in QEMU with OVMF unless it says otherwise.

- **SC-001** From a written install image to an accepted first deployment with no key
  pressed, through at most two restarts (009 SC-002), with the firmware variables
  written once, at install.
- **SC-002** A deployment candidate that fails its health check twice: the third start
  boots the current deployment, the recovery is not started, and the boot partition is
  byte for byte unchanged apart from the loader record.
- **SC-003** A trial set whose kernel panics, one that hangs (ended by a reset), and one
  whose initramfs is cut short on disk: in each case the next start is the default set
  with no key pressed, and the kernel candidate is listed as failed with 004's reason.
- **SC-004** A default set that never reaches a healthy system: within the limit plus
  two starts the recovery is on the screen, with no key pressed. Left alone, it restarts
  into the default set after its idle time.
- **SC-005** The recovery key, sent during the loader's wait, starts the recovery in
  each of these states: healthy system, system partition wiped, loader record deleted,
  our entry removed and the loader started from the removable-media path.
- **SC-006** The disk image is snapshotted after every single write of a trial-set
  install, an accept, a rollback, a recovery update and a healthy mark. Every snapshot
  starts, and starts either the old default set or the new one.
- **SC-007** With a second system's EFI system partition and boot entries on the same
  disk: after install, ten updates, a kernel accept, a rollback, a repair and a removal,
  that partition's checksum and the other system's boot entries are unchanged, and the
  other entries keep their order relative to each other. Changes the firmware makes by
  itself at a start are told apart by a run of the same starts without GlassineOS's
  writes.
- **SC-008** With the firmware's variable store deleted, the PC starts either the other
  system or GlassineOS from the removable-media path; GlassineOS then reports the
  missing entry, and a confirmed repair restores it.
- **SC-009** With the boot partition filled to its last block, an install of a kernel
  refuses, names the space needed and free, and the next start is unchanged.
- **SC-010** With the boot partition deleted and made again empty, the installer's
  repair rebuilds it from the system partition with no network, and the PC starts the
  same deployment as before.
- **SC-011** Over a hundred starts, twenty updates and five kernel trials, the loader,
  the initramfs and the running system write no firmware variable (the firmware's own
  writes at a start don't count).
- **SC-013** Four sessions in a row, each shut down in an orderly way before the health
  time: the fifth start is the default set. A default set that fails with a previous
  set that is healthy: the PC ends on the previous set as the default, with no key
  pressed.
- **SC-012** On at least two real PCs of different firmware makers, with the person's
  go: SC-001, SC-003 and SC-005.

- **SC-014** With a current and a previous deployment: the previous one is picked once
  in the list and runs. The next start, with no key pressed, runs the current one.
  `state/deploy` is byte for byte the same before the first and after the second
  start, and the boot partition holds no trace of the choice. The same after a power
  cut during the chosen start.
- **SC-015** A request for a deployment that was removed, and one given while a
  resumable hibernate image is there: the ordinary pick, respectively the resume,
  happens, with a message, and `state/deploy` is unchanged.
- **SC-016** The installer's check, run against OVMF's variables with Secure Boot on,
  refuses the install, names the reason and the way to switch it off, and writes
  nothing. An OVMF that enforces Secure Boot starts neither the install medium nor the
  loader, and another system on the disk still starts.

- **SC-017** A distribution kernel whose disk and file system drivers are all modules
  starts its kernel set under OVMF, from a virtio disk and from an NVMe disk: the
  deployment is assembled from the btrfs system partition and the ext4 userdata, and no
  boot module failed. The same initramfs without the boot modules does not find the
  system partition.
- **SC-018** With a second disk whose partitions have the same names as the
  installation's, and a system configuration that names neither partition, every
  command of the deployment tool and the first start acts on the partitions the command
  line names. With the key missing, given twice, malformed, naming no partition or a
  partition two disks carry, or with a configured name that is another partition than
  the key's, they refuse with the reason and write nothing.

## Assumptions

- A PC has a system partition and a userdata as 001 defines them, found by their
  identity on the command line. How the installer makes userdata on a PC is the
  installer's.
- The recovery of 008 exists for x86-64 as one image; its screen and keys on a PC are
  008's (008 FR-006).
- The loader is a program GlassineOS builds for the release. It reads and writes the
  loader record of FR-019, so it is no other system's loader, packaged.
- x86-64 only. Other UEFI machines (arm64 PCs) follow this spec once they have a
  description.

## Out of scope

- Starting with Secure Boot on. The intended route is a signing key of GlassineOS's own
  that the person enrols once; it is a later feature with its own spec.
- Disk encryption and measured boot.
- Starting another system from the loader.
- Network boot, and firmware updates.
- The installer's steps, plan and backup (installer 001, 002).
- Building the loader and the recovery image, and the parts a release's first kernel set
  is assembled from (the plan, and GlassineOS/images).
