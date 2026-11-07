# Kernel artifacts: what a build hands to a device

Status: **agreed design; partly implemented.** Built and host-tested, nothing run on a
device ([specs/004](../specs/004-kernel-records/spec.md), phases 1 and 2): the kernel
records, `glassine-bootimg` `install` (the `bootpart-test` hand-off), `status`, `cancel`,
`retry`, `accept`, `rollback`, the default-slot write, the interlocks with
`glassine-deploy` and `glassine-hibernate`, the trial in the initramfs, and `promote`
(finishing a cut write, `requested`, the verdict, a deferred install). Not built: the
`blocklist` hand-off, and everything under "Not covered here". It builds on
`glassine-deploy`'s `receive --modules`, `stage` and `bases remove`. Kernel updates stay
paused on a device until its hand-off (below) exists. Once implemented, `images` builds to
this page and the tools here consume it. Changes go through this repository
first ([constitution](../.specify/memory/constitution.md), principle IV).

A device boots four things with separate lifecycles: a **kernel**, a **device tree**, an
**initramfs** and a **base**. This page says how each is named, what travels with it,
where the device keeps it, which records tie them together, and which combinations may
boot. It doesn't say how they are built.

This page covers the **deployments** layout. A **plain** root has no system partition:
there `glassine-bootimg` keeps its state in `/var/lib/glassine-bootimg` and packs from
board.conf's `KERNEL`, `DTB`, `INITRAMFS`, as today.

## The four artifacts

| Artifact | Built from | Identity | On the device (system partition) |
|---|---|---|---|
| kernel | kernel source + config, per SoC (per device only if a device needs its own config) | its **release** (below) | `modules/<release>/`: image, modules, firmware |
| device tree | the kernel source's board files, per device | `<device>@<sha256-16>` of the `.dtb` | `boot/dtb/<device>@<sha256-16>.dtb` |
| initramfs | this repository (`build-initramfs.sh`) | `<commit12>` of this repository | `boot/initramfs/<commit12>.cpio.gz` |
| base | `images` stages | `<base-id>` | `bases/<base-id>/` ([deployments.md](deployments.md)) |

Each has its own place, so a new initramfs, a device tree for a new device or a fixed
device tree reaches a device without a new kernel (within the rules under "Which
combinations boot"), and a new kernel without a new initramfs.

The kernel is **device-level** ([decision 0010](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0010-root-and-deployments.md)):
the device selects one kernel, and every deployment boots under it. So a base never
contains a kernel, modules, or firmware tied to a kernel release, and is never built for
one. Kernel and deployment each have their own records, tries and rollback, kept apart
(below): one trial at a time, and a kernel trial never touches a deployment's tries.

## Kernel release

The release (`uname -r`) ties a kernel image to its modules, so **two different builds
never share one**. The build sets it from the effective inputs, so a stateless build gets
it right whatever the clone has (tags or not):

```
<KERNELVERSION>-<flavor>.<cfg6>-g<commit12>
```

- The build sets `LOCALVERSION=-<flavor>.<cfg6>-g<commit12>` itself, with
  `CONFIG_LOCALVERSION_AUTO` off and `CONFIG_LOCALVERSION` empty. `scripts/setlocalversion`
  then appends nothing.
- `<flavor>` names the SoC (`sdm660`), never a device or a person; a device-specific config
  gets its own flavor.
- `<cfg6>`: the first 6 hex digits of sha256 over the final `.config` and the builder
  image's digest.
- `<commit12>`: the kernel source commit. A build from a tree with uncommitted changes is
  refused (the build checks `git status`).
- The packer checks the string inside the kernel image (`--expect-release`, already in
  `lib/glassine-bootimg-pack`).
- Nothing sorts releases: `state/kernel` names them explicitly.

A modules subvolume, once received, is never replaced: `glassine-deploy receive --modules`
refuses a name that exists.

## On the system partition

```
system partition (btrfs, top level)
├── modules/<release>/            read-only subvolume, received
│   ├── kernel/ …, modules.*      modules_install output, stripped; depmod run at build (-b)
│   ├── firmware/                 redistributable firmware this kernel needs (below)
│   ├── Image.gz                  gzip -n, so its checksum is stable
│   └── kernel.manifest
└── boot/                         plain directory, written under state/.lock
    ├── dtb/<device>@<id>.dtb             + <device>@<id>.manifest
    └── initramfs/<commit12>.cpio.gz      + <commit12>.manifest
```

`boot/` files are named by their content, so a file once written never changes; a new
device tree or initramfs is a new file, added by `glassine-deploy receive --boot FILE`
(new). Their manifests hold only facts about the bytes, so the same bytes give the same
file and manifest, and receiving an existing name is a no-op. A file may be removed only when no kernel record names it (`state/kernel`'s
`deferred_dtb` and `deferred_initramfs` included) and it was received
before the last `glassine-bootimg install` (so a file received for an install that hasn't
happened yet stays).

At boot the initramfs (after `gr_boot`, through the merged root, whose upper is on
userdata, or the tmpfs on a bare boot) makes the mount points, then binds:

- `modules/<release>` on `/lib/modules/<release>`
- `modules/<release>/firmware` on `/lib/firmware/updates`

The kernel's built-in search order puts `/lib/firmware/updates` ahead of `/lib/firmware`,
so nothing goes on the command line for it, and the base needs no knowledge of the release.
The base ships only the empty directories `/lib/modules/` and `/lib/firmware/updates/`
(no files under the latter: the bind hides them). Today `gr_modules` needs the base to
carry `/lib/modules/<release>`; it changes to `mkdir -p` through the merged root. A
missing subvolume is logged loudly; the boot continues without modules. Packages can't
install modules into the read-only bind: out-of-tree modules are built with the kernel.

**Firmware tied to the kernel** (for example GPU microcode the driver depends on) comes from
`linux-firmware` at a pinned version with pinned checksums and goes in `firmware/`.

## Device data: files from the device itself

Some files can only come from the device: the panel's waveform, signed firmware read from
its own partitions (GPU zap shader, radio and DSP images). They are **never** in an
artifact; a build check enforces that by content, not only by name.

**The seed.** They are copied once from the device's own storage into a seed, checked, and
from then on read only from the seed (refreshed only on request). Nothing depends on the
original partitions afterwards. The seed lives on a partition of its own, the board's
`DEVICE_PART` (a new `board.conf` key), so it survives a reformat of the system partition,
a format of userdata and every deployment reset, and the initramfs and the recovery can
read it without either:

```
DEVICE_PART (the Note Air: vendor_b, ext4; GlassineOS otherwise only reads it)
└── glassine/
    ├── manifest             format=1, then one line per file: name, source (PART:PATH), sha256
    ├── waveform.wbf
    └── firmware/            device firmware, by the names drivers request
```

On a device with an A/B layout whose B slot belongs to GlassineOS, `DEVICE_PART` is the
B slot's vendor partition: a clone of the stock vendor partition, already a source of
device files. Its stock files stay untouched; only `glassine/` is added. Writing it breaks
that partition's Android verity, which matters only if Android ever booted from it.

**At boot (initramfs).** After `gr_resume` (boot.md rule 1: nothing is mounted before the
hibernation step) and after `gr_carry` has put the tmpfs on the new root's `/run`:

1. `dumpe2fs -h` on `DEVICE_PART`: if its journal needs recovery, nothing is mounted (the
   seed hook replays it).
2. `debugfs -R 'stat /glassine/manifest'`, without mounting.
3. If the manifest exists: mount `DEVICE_PART` `ro,noload` (no journal replay, nothing
   written) directly under the new root, `$NEWROOT/run/glassine/device-part` (after
   `gr_carry`'s tmpfs, so it needs no move), and check every file against the manifest's
   sha256 with `sha256sum` (about 33 MB on the Note Air, most of it radio and DSP images;
   estimated well under a second per boot, accepted for never exposing an unverified
   file). Only when all match is `glassine/` bound on
   `$NEWROOT/run/glassine/device`, read-only. Nothing unverified is ever visible there.
4. Otherwise nothing is bound (a mount without a valid seed is unmounted); the seed hook
   runs later.

Device firmware is reached through `firmware_class.path=/run/glassine/device/firmware`
(the board's constant command line), searched before the `/lib/firmware` paths, so
`firmware/` must never hold a name the kernel's `firmware/` provides (the device's own
older GPU microcode would win over the pinned one). Drivers that request firmware before
`switch_root` find neither path: they stay modules, or defer.

**The seed hook (OpenRC, the device package's, in sysinit before the device manager's
coldplug)** runs only when nothing is bound on `/run/glassine/device`, or when a refresh
is asked for (a refresh unmounts the boot mounts first, so the read-write mount below is
the only one):

- If the journal needs recovery: one read-write mount and unmount replays it, then the
  files are checked against the manifest as the initramfs does.
- A missing manifest, or a file that doesn't match, is copied again from its source:

1. Each source is read read-only: an ext4 source with `debugfs -R dump` (no mount), a
   source without a journal (vfat) mounted `ro`, a btrfs source `ro,rescue=nologreplay`.
   Each file is checked (for the waveform: size and header).
2. `DEVICE_PART` is mounted read-write; files are written as temp files and renamed;
   the manifest is written last; it is unmounted.
3. It is mounted `ro,noload` and `glassine/` bound on `/run/glassine/device`.

`glassine-hibernate` refuses (exit 3) while `DEVICE_PART` is mounted read-write.

**Failure and escape:** a copy cut off before the manifest's rename has no manifest, so
it is no seed. Cut off after it, the journal may need recovery, or a file may not match:
the next boot's hook replays the journal and verifies, and copies again what fails. Either
way the daemons and the recovery read the original sources meanwhile. The recovery can remove `glassine/`; the stock files on `DEVICE_PART` stay. A
seed write never touches the original sources.

- **Daemons** read their file paths from configuration (for the panel: `waveform=` in
  `/etc/glassine/epd.conf`), never a fixed path in the base.
- **The recovery** reads the seed first (mounted `ro,noload`) and falls back to the
  original sources. It never needs the system partition for this.
- **Not a backup:** the seed protects against resets and reformats, not against losing the
  device's storage. Before any stock partition the seed came from is retired or reused,
  the installer must have copied the device's own partitions to a backup off the device.

## Kernel records, trials and hand-off

As decision 0010 sets out: the kernels are kept on the device's storage with a try counter
and a fallback; records, selection, tries and acceptance are the same on every device; only
the **hand-off** to the bootloader differs. All of it on the system partition, written
through `gs_write` under `state/.lock`:

```
state/kernel                 the device's kernel state (keys below)
state/bootimg/<id>.img       a packed image, where the hand-off needs one
state/bootimg/<id>.manifest  its record (below)
```

`state/kernel` keeps today's meaning of `current` and `previous` (releases) and adds keys
(no format bump):

| Key | Meaning |
|---|---|
| `current`, `previous` | releases (unchanged) |
| `current_img`, `previous_img` | their image ids |
| `candidate`, `candidate_img` | the kernel on trial, or empty |
| `tries` | boots the candidate has left (0–1) |
| `failed`, `failed_img` | the last candidate that failed, and `reason` in its image record |
| `deferred` | a release waiting for its install: it arrived during a trial, or while a deployment was a candidate or staged |
| `deferred_dtb`, `deferred_initramfs` | the device tree (`<device>@<id>`) and initramfs (`<commit12>`) that deferred install was checked with, and installs with |
| `requested` | the `candidate_img` that `reboot-test` asked the bootloader for; cleared at the next boot. A boot that isn't the candidate's while `tries=1` means the trial never started: the candidate is failed, with the hand-off's reason |
| `writing`, `writing_op` | the image a command is writing to the default slot, and which command (`accept`, `rollback` or `repair`); set before the write, cleared after the state write that completes it. A boot of that image is a finishing boot (below) |

Per image, in `state/bootimg/<id>.manifest`: `release`, `size`, `sha256`, `staged` (UTC),
`reason` (why it failed), plus the boot record fields below. These replace today's files
under `/var/lib/glassine-bootimg` (`pending`, `failed`, `current`, `deferred`, `prev`,
`prev.img`), which were per deployment.

Writers: `glassine-bootimg` (install, accept, rollback, retry, cancel) and the initramfs (one try).

In an image record, `reason` is `no-boot` (the trial never reached the initramfs),
`no-verdict` (it ended before promote's check), `default slot write` (accept's write
failed and the old image went back), or the health check's own. `seeded=1` marks the
record of the first `current_img`: after the migration nothing names the running image,
so the first accept or `rollback` records the default slot's image, if it is a boot
image with a `glassine.img=` whose kernel is release `current`.

`glassine-bootimg` exits 0 done, 1 error, 2 usage, 3 the state format (or a record) is
newer than the tool, 6 busy (`state/.lock` held).

**One trial at a time.** "A kernel candidate is set" means from `install` until the
candidate is accepted, failed or cancelled, not only during the trial boot.
`glassine-bootimg cancel` drops it: clears `candidate`, `candidate_img` and `tries`,
leaves the default boot alone (on `bootpart-test` the default slot isn't touched), and
keeps the files for a later `install`.

- While a kernel candidate is set: `select`, `stage` and `reset` refuse (exit 8, the
  message names `glassine-bootimg cancel`), and the shutdown switch leaves a staged
  deployment staged (it switches at a later shutdown).
- **The escape routes always work:** `reset --now` and `rollback` (the recovery's) run
  `glassine-bootimg cancel` first and say so. A broken deployment never waits for a kernel
  trial.
- `cancel` is also allowed during the trial boot itself: promote then finds no candidate,
  the next boot is the old kernel again, and `glassine-hibernate` refuses until then
  because the selected kernel isn't the running one.
- While a deployment is a candidate or staged: `install` doesn't refuse, it puts the
  release in `deferred`, and `glassine-bootimg-promote` installs it automatically after
  that deployment is accepted or failed. `install` checks the device tree and the
  initramfs first, so a deferral is never one it would refuse. `reboot-test` and
  `retry` refuse then, so no kernel trial starts.

The same release may be `current` and `candidate` with different `_img` ids (a new device
tree or initramfs for the running kernel).

**A kernel trial:**

1. The initramfs reads `state/kernel` before `gr_resume`, with the system partition
   mounted `ro,rescue=nologreplay` (boot.md rule 1). A boot whose `glassine.img=` on the
   command line equals `writing` is a **finishing boot**: a default-slot write was
   started, and its state write didn't happen. Otherwise, the boot is the candidate
   kernel's trial when `glassine.img=` equals `candidate_img`. Neither resumes a
   hibernated session.
2. After the system partition is read-write and locked, a trial takes the try
   (`tries=0`). A finishing boot takes none: an accept's candidate is already at
   `tries=0`.
3. Both boot **current** (the deployment), without picking a candidate and without
   taking a deployment try (`gr_boot` gets a mode for this).
4. `glassine-deploy-accept` doesn't run on either. `glassine-bootimg-promote` (OpenRC,
   last):
   - On a trial, it checks the boot and accepts the kernel (`current` ← candidate, the
     old one to `previous`). A trial that fails, hangs or ends before the check leaves
     the candidate at `tries=0`: the next boot is the old kernel, and it marks the
     candidate failed.
   - **Whenever `writing` is set,** on a finishing boot or on any other boot, it first
     compares the sha256 of the default slot's first `size` bytes with the manifest of
     the image `writing` names. `glassine.img=` alone doesn't show that the slot was
     written: on `bootpart-test`, the test slot boots the same image while the default
     slot may still be cut. If they don't match, it writes the default slot again from
     `state/bootimg/<writing>.img`, and if that fails, `writing` stays and `status` says
     the default slot can't boot.
   - Once the default slot matches, it completes what `writing_op` names, with no new
     health check (an accept's check ran in its trial):
     - `accept`: `current` ← candidate, the old one to `previous`, and the candidate keys
       and `requested` are cleared;
     - `rollback`: `current` and `previous` swap;
     - `repair`: a candidate, if one is set, is cancelled.

     Then `writing` and `writing_op` are cleared.

   How each hand-off writes the default slot is its own
   ([blocklist.md](blocklist.md) for `blocklist`).

**Hand-off** (board key `HANDOFF`): how the bootloader gets the selected kernel.

| Value | How | Boards |
|---|---|---|
| `bootpart-test` | the candidate's image written to a one-shot test slot, the default slot written on accept (today's `glassine-bootimg`) | boards with a spare slot; never the recovery partition (`install` refuses a `TEST_DEV` named `recovery`) |
| `blocklist` | a cold boot of a kernel file whose storage blocks the bootloader reads | the Note Air (planned; [blocklist.md](blocklist.md), [hub#53](https://github.com/GlassineOS/hub/issues/53)) |
| `kexec`, `hardboot` | from a minimal loader / a warm reset into a staged image | not specified here |
| empty | none: `install` refuses ("kernel updates are paused") | the Note Air today |

The records, the trial and acceptance above are the same for every value.

## Records

Every record is `key=value`, one per line, the format of the state files
([deployments.md](deployments.md#state-files)); the first line is `format=<N>` (this page:
1). Unknown keys are ignored; a missing key is empty. A change of a key's meaning bumps
`format`; a reader refuses a newer format.

**`kernel.manifest`** (`modules/<release>/`)

| Key | Meaning |
|---|---|
| `release` | the release |
| `source` | `URL@COMMIT` |
| `config_sha256` | of the final `.config` |
| `image_sha256` | of `Image.gz` |
| `modules_sha256` | of a sorted `path sha256` list over the modules tree |
| `firmware` | space-separated `name@sha256-16` of `firmware/` |
| `provides` | features built in, from this repository's table (below) |
| `features` | the version of that table used |
| `dtbs` | the device trees built at the same commit (`<device>@<id>`) |

**dtb manifest** (`boot/dtb/<device>@<id>.manifest`): `device`, `sha256`, `source`
(`URL@COMMIT` of the first build that produced these bytes). A kernel built at the same
commit lists the trees it was built with in `kernel.manifest` (`dtbs`), so a fixed tree
ships for an installed kernel without recompiling it: it becomes a candidate with the
same release and its own image, and goes through a trial.

**initramfs manifest** (`boot/initramfs/<commit12>.manifest`): `commit`, `sha256`,
`state_format` (newest it writes), `needs`, `features`.

**boot record** (in `state/bootimg/<id>.manifest`): `id` (the `glassine.img=` value),
`device`, `kernel` (release), `dtb` (identity), `initramfs` (commit12), `cmdline`,
`board` (sha256 of the `board.conf` the header fields came from).

**Base manifest:** `/usr/share/glassine/base.manifest` in the base tree, defined here:
`format`, `base` (id), `locks` (sha256 of the stage locks), `needs`, `features`. `images`
doesn't write it yet; it adds it as part of hub#8 step 6.

**Feature names** are this repository's: a versioned table (`conf/kernel-features`, first
line `features=<N>`) maps each name to the config options that provide it (`btrfs` =
`CONFIG_BTRFS_FS=y`, `overlayfs` = `CONFIG_OVERLAY_FS=y`, `zram-writeback` =
`CONFIG_ZRAM_WRITEBACK=y`, …). The build derives `provides` from `.config` with it; nobody
writes it by hand. **A name keeps its meaning forever:** a new feature gets a new name, a
dropped one is never reused, and `features` only counts additions. The checks compare
names, never versions: a name the older side's table doesn't know counts as not provided.
So a kernel and a base built with different table versions still compare.

## Which combinations boot

A boot image is **valid** when:

1. the kernel's `provides` covers the initramfs's `needs`;
2. the kernel's `dtbs` lists the device tree (built together); otherwise `install` logs a
   warning and goes on: the device-tree ABI only promises that newer kernels accept older
   trees, so the trial (every install is one) is what proves the pair;
3. it fits the board's limits (slot size, the bootloader's ramdisk limit).

A kernel **covers** a deployment when its `provides` covers the base's `needs` and its
subvolume is on the system partition.

Checked by:

- the build, when it packs (1–3);
- `glassine-bootimg install`, before the hand-off: 1–3, and that the kernel covers the
  deployments that will boot next (current, and a staged one). `previous` isn't required:
  an old deployment never blocks a kernel update; going back to it is checked when it is
  selected. If the current kernel doesn't cover it (exit 8), the way back is
  `glassine-bootimg rollback` first (the previous kernel's modules are kept), then the
  deployment's. The modules are checked
  at `<system>/modules/<release>`, not under `/lib/modules`, where a new release can't
  appear until it boots;
- `glassine-deploy select` (and so `rollback`) and `stage`/`reset`: refuse a deployment
  the current kernel doesn't cover, with a new exit code 8 ("not covered by the current
  kernel"). The same exit code covers a set kernel candidate (above), except for
  `rollback` and `reset --now`, which cancel it first.

## Packing

Where the hand-off needs a boot image, `lib/glassine-bootimg-pack` packs it on the device
with header fields from `board.conf`.
`images` keeps each device's target description, and its boot section **is** that
`board.conf`, verbatim; nothing is taken from a reference image. In the deployments layout
the packer takes the kernel from `modules/<release>/Image.gz` and the device tree and
initramfs from `boot/`, not from the base.

## Order on the device

1. `glassine-deploy receive --modules` (the kernel's subvolume), and `receive --boot` for
   a device tree or initramfs the device doesn't have yet.
2. `glassine-bootimg install <release> [--dtb <device>@<id>] [--initramfs <commit12>]`:
   checks, makes it the candidate, hands it off. The device tree defaults to the entry for
   board key `DEVICE` in the kernel's `dtbs`, the initramfs to the one in `current_img`'s
   boot record.
3. The trial, then accept (writes `state/kernel`). Modules of current, previous, the
   candidate and deferred are never removed; older ones may be (`bases remove` extends to
   modules).
4. Accept runs inside the trial, where no hibernation image can exist, so it never waits.
   A `rollback` changes the selected kernel while the system runs; until the next reboot
   the selected kernel isn't the running one, and a resume under it would be cancelled.
   So `glassine-hibernate` refuses (exit 3, with that reason) while `state/kernel` selects
   another kernel than the running one, and during a trial.

## What the user sees

`glassine-bootimg status` is the interface. In this layout it prints `format=1`, then
`state=` (`none`, `candidate`, `trial`, `finishing`, `writing` or `failed`), then each key
of `state/kernel` that is set (except `deferred_dtb` and `deferred_initramfs`, the deferred
install's inputs), `reason=` for a failed candidate, and `default_slot=bad`
while `writing` is set and the default slot doesn't hold that image. The shell reads it
and notifies:

- once, when a kernel is the candidate and waits for its trial reboot, with a restart
  action (`glassine-bootimg reboot-test`);
- when a trial failed, with its `reason`.

A successful accept needs no message.

## Deployment meta

`kernel=` in a deployment's `meta`: the release it last booted under, written at accept;
informational only (`glassine-deploy list` already prints it). Kept so a per-deployment
kernel (with a kexec loader) is a loader change, not a format change: an empty value means
"the device's default".

## Interface additions

| Where | What |
|---|---|
| `glassine-deploy` | `receive --boot FILE` (an existing name is a no-op); exit 8 for `select`/`stage`/`reset`; `reset --now` and `rollback` cancel a kernel candidate first; `switch` leaves a deployment staged while a kernel candidate is set; `bases remove` also removes unused modules and `boot/` files |
| `glassine-bootimg` | kernel records, trial and accept on the system partition in the deployments layout; `install` defers during a deployment trial or with a staged deployment; `cancel` (new); `status` `format=1` |
| initramfs | the kernel trial (boots current, no deployment try, no accept); the `DEVICE_PART` mount, verified before it is bound |
| `glassine-hibernate` | exit 3 while another kernel than the running one is selected, during a kernel trial, and while `DEVICE_PART` is read-write |
| `board.conf` | `DEVICE_PART`, `HANDOFF`; `KERNEL`, `DTB`, `INITRAMFS` only for the plain layout |

## When this is implemented

What changes with it:

- [deployments.md](deployments.md): the on-disk layout (`modules/<release>/` contents,
  `boot/`), `state/kernel` keys, `state/bootimg/`, `kernel=` in the meta table, the
  interface additions and exit 8.
- [boot.md](boot.md): `DEVICE_PART` and `HANDOFF` in the board keys; the boot steps (the
  two binds, `DEVICE_PART` after `gr_carry`, the kernel trial); its line that the Note Air
  uses `plain`, which is out of date.
- `initramfs/init` (`TRIES=1` and `ID=` from `/var/lib/glassine-bootimg`, and the "no staged
  test boot in this layout" path), `lib/glassine-root.sh` (`gr_modules` `mkdir -p`; a
  `gr_boot` mode that boots current without a try; the `DEVICE_PART` mount),
  `openrc/glassine-deploy-accept` (skips a kernel trial), `sbin/glassine-bootimg` (`ST`, `MODS`, the inputs it packs from),
  `test/root/inner.sh` (the base's `/lib/modules/<release>`), README.md (Kernel updates),
  `conf/board.conf.example`.
- docs.glassine.org, Boot flow: vendor partitions are mounted read-only without replaying a
  journal, except the seed's read-write copy.

## Not covered here

- The kexec loader (it consumes the same layout and records).
- How `images` builds these (stages `kernel-<soc>`, `dtb-<device>`, `initramfs-<device>`,
  `boot-<device>`), signing and publishing.
