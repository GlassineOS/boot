# Kernel artifacts: what a build hands to a device

Status: **agreed design; nothing here is implemented yet.** It builds on `glassine-deploy`
0.4 (`receive --modules`, `stage`, `bases remove`; branches `deploy-0.3-*`, not yet on
main), which this repository merges first. Today kernel updates are paused in the
deployments layout (no staged test boot, [boot.md](boot.md)). Once implemented, `images`
builds to this page and the tools here consume it. Changes go through this repository
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

Each has its own place, so a new initramfs or a device tree for a new device reaches a
device without a new kernel, and a new kernel without a new initramfs.

The **boot image** joins kernel, device tree, initramfs and the board's command line. Today
it is **device-level**: one default slot, and every deployment boots whatever kernel the
slot holds. So a base never contains a kernel, modules, or firmware tied to a kernel
release, and is never built for one. Deployment rollback and kernel rollback stay
independent; their state lives in one place (below), so neither loses track of the other.

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
(new). Files that no image in `state/bootimg/` names may be removed.

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

1. `debugfs -R 'stat /glassine/manifest'` on `DEVICE_PART`, without mounting.
2. If the manifest exists: mount `DEVICE_PART` `ro,noload` (no journal replay, nothing
   written) and bind its `glassine/` on `$NEWROOT/run/glassine/device`, read-only. The
   mount moves to the new root with the others.
3. If not: nothing is mounted; the seed hook runs later.

Device firmware is reached through `firmware_class.path=/run/glassine/device/firmware`
(the board's constant command line), searched before the `/lib/firmware` paths, so
`firmware/` must never hold a name the kernel's `firmware/` provides (the device's own
older GPU microcode would win over the pinned one). Drivers that request firmware before
`switch_root` find neither path: they stay modules, or defer.

**Seeding (OpenRC, the device package's hook, early in boot).** Only when nothing is on
`/run/glassine/device` (no manifest at boot) or a refresh is asked for (a refresh
unmounts the boot mount first, so the read-write mount below is the only one):

1. Each source is read read-only: an ext4 source with `debugfs -R dump` (no mount), a
   source without a journal (vfat) mounted `ro`, a btrfs source `ro,rescue=nologreplay`.
   Each file is checked (for the waveform: size and header).
2. `DEVICE_PART` is mounted read-write; files are written as temp files and renamed;
   the manifest is written last; it is unmounted.
3. It is mounted `ro,noload` and `glassine/` bound on `/run/glassine/device`.

`glassine-hibernate` refuses (exit 3) while `DEVICE_PART` is mounted read-write.

**Failure and escape:** a copy cut off has no manifest, so it is no seed: the hook tries
again at the next boot, and the daemons and the recovery read the original sources
meanwhile. The recovery can remove `glassine/`; the stock files on `DEVICE_PART` stay. A
seed write never touches the original sources.

- **Daemons** read their file paths from configuration (for the panel: `waveform=` in
  `/etc/glassine/epd.conf`), never a fixed path in the base.
- **The recovery** reads the seed first (mounted `ro,noload`) and falls back to the
  original sources. It never needs the system partition for this.
- **Not a backup:** the seed protects against resets and reformats, not against losing the
  device's storage. Before any stock partition the seed came from is retired or reused,
  the installer must have copied the device's own partitions to a backup off the device.

## Kernel state

On the system partition, written through `gs_write` under `state/.lock`:

```
state/kernel                 the device's kernel state (keys below)
state/bootimg/<id>.img       an image staged or promoted, kept for rollback
state/bootimg/<id>.manifest  its record (below)
```

`state/kernel` keeps today's meaning of its keys and adds new ones (no format bump):

| Key | Meaning |
|---|---|
| `current`, `previous` | releases (unchanged) |
| `current_img`, `previous_img` | image ids the default slot holds now / held before the last promote |
| `pending_img` | the image staged in the test slot, or empty |
| `failed_img` | the last image whose test boot failed, or empty |
| `deferred` | a release that arrived during a test boot |

Per image, in `state/bootimg/<id>.manifest`: `release`, `size`, `sha256`, `staged` (UTC),
`tries` (0 or 1), `reason` (why it failed), plus the boot record fields below. These
replace today's files under `/var/lib/glassine-bootimg` (`pending`, `failed`, `current`,
`deferred`, `prev`, `prev.img`). Those were per deployment, so a test boot staged from one
deployment was invisible after a switch to another.

Writers: `glassine-bootimg` (install, promote, rollback, retry) and the initramfs (one try).

**The test boot in the deployments layout:**

1. Before `gr_resume`, the initramfs may read `state/kernel` with the system partition
   mounted `ro,rescue=nologreplay` (boot.md rule 1) to know whether this boot is the
   pending image's test (`glassine.img=` on the command line equals `pending_img`). A test
   boot never resumes a hibernated session.
2. After `gr_boot` has the partition read-write and the lock, it writes `tries=1` into the
   pending image's manifest. A test boot then runs the default boot by itself.
3. `glassine-bootimg-promote` (OpenRC, last) checks the boot and promotes, as today.

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

**dtb manifest** (`boot/dtb/<device>@<id>.manifest`): `device`, `source` (`URL@COMMIT`),
`sha256`.

**initramfs manifest** (`boot/initramfs/<commit12>.manifest`): `commit`, `sha256`,
`state_format` (newest it writes), `needs`, `features`.

**boot record** (in `state/bootimg/<id>.manifest`): `id` (the `glassine.img=` value),
`device`, `kernel` (release), `dtb` (identity), `initramfs` (commit12), `cmdline`,
`board` (sha256 of the `board.conf` the header fields came from).

**Base manifest:** `/usr/share/glassine/base.manifest` in the base tree, written by
`images` (base id, its stage locks' checksums); this page adds `needs` and `features`.

**Feature names** are this repository's: a versioned table (`conf/kernel-features`, first
line `features=<N>`) maps each name to the config options that provide it (`btrfs` =
`CONFIG_BTRFS_FS=y`, `overlayfs` = `CONFIG_OVERLAY_FS=y`, `zram-writeback` =
`CONFIG_ZRAM_WRITEBACK=y`, …). The build derives `provides` from `.config` with it; nobody
writes it by hand. Renaming a feature or changing its options bumps `features`.

## Which combinations boot

A boot image is **valid** when:

1. the kernel's `provides` covers the initramfs's `needs`;
2. kernel and device tree come from the same source commit (`source` in both manifests);
3. it fits the board's limits (slot size, the bootloader's ramdisk limit).

A kernel **covers** a deployment when its `provides` covers the base's `needs` and its
subvolume is on the system partition.

Checked by:

- the build, when it packs (1–3);
- `glassine-bootimg install`, before it writes a slot: 1–3, and that the kernel covers every
  deployment that may boot (current, previous, candidate, staged). The modules are checked
  at `<system>/modules/<release>`, not under `/lib/modules`, where a new release can't
  appear until it boots;
- `glassine-deploy select` and `stage`: refuse a deployment the slot's kernel doesn't cover,
  with a new exit code 8 ("the kernel in the boot slot doesn't cover this base").

## Packing

`lib/glassine-bootimg-pack` packs on the device with header fields from `board.conf`.
`images` keeps each device's target description, and its boot section **is** that
`board.conf`, verbatim; nothing is taken from a reference image. In the deployments layout
the packer takes the kernel from `modules/<release>/Image.gz` and the device tree and
initramfs from `boot/`, not from the base.

## Order on the device

1. `glassine-deploy receive --modules` (the kernel's subvolume), and `receive --boot` for
   a device tree or initramfs the device doesn't have yet.
2. `glassine-bootimg install <release>`: checks, packs, stages.
3. Test boot, promote (writes `state/kernel`). Modules of current, previous, pending and
   deferred are never removed; older ones may be (`bases remove` extends to modules).
4. Promote runs inside the test boot, where no hibernation image can exist, so it never
   waits. A `rollback` rewrites the default slot while the system runs; until the next
   reboot the slot then holds a different kernel from the running one, and a resume under
   it would be cancelled. So `glassine-hibernate` refuses (exit 3, with that reason) while
   `state/kernel` says the slot's kernel isn't the running one.

## What the user sees

`glassine-bootimg status` is the interface; it gains a `format=1` field. The shell reads it
and notifies:

- once, when an image is staged and waits for its test reboot, with a restart action
  (`glassine-bootimg reboot-test`);
- when a test boot failed, with its `reason`.

A successful promote needs no message.

## Deployment meta

`kernel=` in a deployment's `meta`: the release it last booted under, written at accept;
informational only (`glassine-deploy list` already prints it). Kept so a per-deployment
kernel (with a kexec loader) is a loader change, not a format change: an empty value means
"the device's default".

## Interface additions

| Where | What |
|---|---|
| `glassine-deploy` | `receive --boot FILE`; exit 8 for `select`/`stage`; `bases remove` also removes unused modules and `boot/` files |
| `glassine-bootimg` | state on the system partition in the deployments layout; `status` `format=1` |
| `glassine-hibernate` | exit 3 after a rollback until reboot, and while `DEVICE_PART` is read-write |
| `board.conf` | `DEVICE_PART`; `KERNEL`, `DTB`, `INITRAMFS` only for the plain layout |

## When this is implemented

What changes with it:

- [deployments.md](deployments.md): the on-disk layout (`modules/<release>/` contents,
  `boot/`), `state/kernel` keys, `state/bootimg/`, `kernel=` in the meta table, the
  interface additions and exit 8.
- [boot.md](boot.md): `DEVICE_PART` in the board keys; the boot steps (the two binds,
  `DEVICE_PART` after `gr_carry`, the test boot in the deployments layout); its line that
  the Note Air uses `plain`, which is out of date.
- `initramfs/init` (`TRIES=1` and `ID=` from `/var/lib/glassine-bootimg`, and the "no staged
  test boot in this layout" path), `lib/glassine-root.sh` (`gr_modules` `mkdir -p`; the
  `DEVICE_PART` mount), `sbin/glassine-bootimg` (`ST`, `MODS`, the inputs it packs from),
  `test/root/inner.sh` (the base's `/lib/modules/<release>`), README.md (Kernel updates),
  `conf/board.conf.example`.
- docs.glassine.org, Boot flow: vendor partitions are mounted read-only without replaying a
  journal, except the seed's read-write copy.

## Not covered here

- The kexec loader (it consumes the same layout and records).
- How `images` builds these (stages `kernel-<soc>`, `dtb-<device>`, `initramfs-<device>`,
  `boot-<device>`), signing and publishing.
