# Kernel artifacts: what a build hands to a device

Status: **draft for review; nothing here is implemented.** Today kernel updates are
paused (no staged test boot in the deployments layout, [boot.md](boot.md)), and boot
images are packed outside this repository. Once agreed, `images` builds to this page and
the tools here consume it. Changes go through this repository first
([constitution](../.specify/memory/constitution.md), principle IV).

A device boots four things with separate lifecycles: a **kernel**, a **device tree**, an
**initramfs** and a **base**. This page says how each is named, what travels with it,
where the device keeps it, which records tie them together, and which combinations may
boot. It doesn't say how they are built.

## The four artifacts

| Artifact | Built from | Identity | On the device |
|---|---|---|---|
| kernel | kernel source + config, per SoC (per device only if a device needs its own config) | its **release** (below) | `modules/<release>/` on the system partition: image, modules, firmware |
| device tree | the kernel source's board files, per device | `<device>@<sha256-16>` of the `.dtb` | `modules/<release>/boot/dtb/` |
| initramfs | this repository (`build-initramfs.sh`) | `boot@<commit12>` | `modules/<release>/boot/` |
| base | `images` stages | `<base-id>` | `bases/<base-id>/` ([deployments.md](deployments.md)) |

The **boot image** joins kernel, device tree, initramfs and the board's command line. Today
it is **device-level**: one default slot, and every deployment boots whatever kernel the
slot holds. So a base never contains a kernel, modules, or firmware tied to a kernel
release, and is never built for one. Deployment rollback and kernel rollback stay
independent; their state lives in one place (below), so neither can lose track of the
other.

## Kernel release

The release (`uname -r`) ties a kernel image to its modules, so **two different builds
never share one**. It is derived from the effective inputs, so a stateless build gets it
right without remembering earlier builds:

```
<version>-<flavor>.<cfg6>-g<commit12>
```

- `<flavor>` names the SoC (`sdm660`), never a device or a person; a device-specific config
  gets its own flavor.
- `<cfg6>`: the first 6 hex digits of sha256 over the final `.config` and the builder
  image's digest. `LOCALVERSION=-<flavor>.<cfg6>`, and `CONFIG_LOCALVERSION_AUTO=y` appends
  `-g<commit12>`. A build from a dirty tree (`+` or `-dirty` in the release) is refused.
- The packer checks the string inside the kernel image (`--expect-release`).
- Nothing sorts releases: `state/kernel` names them explicitly.

A modules subvolume, once received, is never replaced; `glassine-deploy receive --modules`
refuses a name that exists (0.4.1 behavior, kept as the backstop).

## The kernel's subvolume

`modules/<release>/` is read-only and holds everything that changes with the kernel, so
the device-side packer (and later a kexec loader) finds it in one place:

```
modules/<release>/
├── kernel/ …, modules.*       modules_install output, stripped; depmod run at build (-b)
├── firmware/                  redistributable firmware this kernel needs (below)
├── boot/
│   ├── Image.gz               gzip -n, so its checksum is stable
│   ├── dtb/<device>@<id>.dtb  one per device this kernel is built for
│   ├── initramfs-<commit12>.cpio.gz
│   └── <device>.boot.manifest the record the packer used last (below)
└── kernel.manifest
```

At boot the initramfs makes the mount points through the merged root (the upper on
userdata, or the tmpfs on a bare boot), then binds:

- `modules/<release>` on `/lib/modules/<release>`
- `modules/<release>/firmware` on `/lib/firmware/updates`

The kernel's built-in search order puts `/lib/firmware/updates` ahead of `/lib/firmware`,
so nothing goes on the command line for it, and the base needs no knowledge of the release.
The base ships only the empty directories `/lib/modules/` and `/lib/firmware/updates/`. A
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
`DEVICE_PART`, so it survives a reformat of the system partition, a format of userdata and
every deployment reset, and the initramfs and the recovery can read it without either:

```
DEVICE_PART (the Note Air: vendor_b, ext4, otherwise unused by GlassineOS)
└── glassine/
    ├── manifest             key=value: each file's source (PART:PATH) and sha256
    ├── waveform.wbf
    └── firmware/            device firmware, by the names drivers request
```

On a device with an A/B layout whose B slot belongs to GlassineOS, `DEVICE_PART` is the
B slot's vendor partition: a clone of the stock vendor partition, already a source of
device files. Its stock files stay untouched; only `glassine/` is added. Writing it breaks
that partition's Android verity, which matters only if Android ever booted from it.

- **Seeding:** the device package's boot hook, when `glassine/manifest` is missing or a
  refresh is asked for. It reads each source read-only (an ext4 source with `debugfs -R
  dump`, without mounting, or mounted `ro,noload`; a btrfs source
  `ro,rescue=nologreplay`), checks each file (for the waveform: size and header), mounts
  `DEVICE_PART` read-write only for the copy (temp files, then renames, then the
  manifest), and unmounts it.
- **At boot** the initramfs mounts `DEVICE_PART` read-only and binds `glassine/` on
  `/run/glassine/device`. Device firmware is reached through
  `firmware_class.path=/run/glassine/device/firmware` (the board's constant command line),
  searched before the `/lib/firmware` paths, so `firmware/` must never hold a name the
  kernel's `firmware/` provides (the device's own older GPU microcode would win over the
  pinned one). Drivers that request firmware before `switch_root` find neither path: they
  stay modules, or defer.
- **Daemons** read their file paths from configuration (for the panel: `waveform=` in
  `/etc/glassine/epd.conf`), never a fixed path in the base.
- **The recovery** reads the seed first and falls back to the original sources. It never
  needs the system partition for this.
- **Not a backup:** the seed protects against resets and reformats, not against losing the
  device's storage. Before any stock partition the seed came from is retired or reused,
  the installer must have copied the device's own partitions to a backup off the device.

## Kernel state

All of it on the system partition, written through `gs_write` under `state/.lock`:

```
state/kernel              current=, previous=, pending=, failed= (releases + image ids)
state/bootimg/<id>.img    the images staged or promoted, kept for rollback
state/bootimg/<id>.manifest
```

`glassine-bootimg` moves its state here from `/var/lib/glassine-bootimg` (per deployment,
so a test boot staged from one deployment was invisible after a switch to another).
Writers: `glassine-bootimg` (install, promote, rollback) and nothing else.

## Records

Every artifact carries a manifest: `key=value`, one per line, the format of the state files
([deployments.md](deployments.md#state-files)). Unknown keys are ignored; a missing key is
empty.

**`kernel.manifest`**

| Key | Meaning |
|---|---|
| `release` | the release |
| `source` | `URL@COMMIT` |
| `config_sha256` | of the final `.config` |
| `image_sha256` | of `boot/Image.gz` |
| `modules_sha256` | of a sorted `path sha256` list over the modules tree |
| `firmware` | space-separated `name@sha256-16` of `firmware/` |
| `provides` | features built in, derived from `.config` by this repository's table (below) |

**`dtb.manifest`**: `device`, `source` (`URL@COMMIT`), `sha256`.

**`initramfs.manifest`**: `commit`, `sha256`, `state_format` (newest it writes), `needs`.

**`boot.manifest`**: `id` (the `glassine.img=` value), `sha256`, `device`, `kernel`,
`dtb`, `initramfs`, `cmdline`, `board` (sha256 of the `board.conf` the header fields came
from).

**The base's manifest** gains `needs`: kernel features its userspace relies on.

**Feature names** are this repository's: a table maps each name to the config options that
provide it (`btrfs` = `CONFIG_BTRFS_FS=y`, `overlayfs` = `CONFIG_OVERLAY_FS=y`,
`zram-writeback` = `CONFIG_ZRAM_WRITEBACK`, …). The build derives `provides` from `.config`
with it; nobody writes it by hand.

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
- `glassine-deploy select` and `stage`: refuse a deployment the slot's kernel doesn't cover.

## Packing

Header fields come from `board.conf`, never from a reference image. `images` keeps each
device's target description, and its boot section **is** that `board.conf`, verbatim. The
device-side packer takes the kernel, device tree and initramfs from the kernel's
subvolume, not from the base.

## Order on the device

1. `glassine-deploy receive --modules` (the kernel's subvolume, with `boot/`).
2. `glassine-bootimg install <release>`: checks, packs, stages.
3. Test boot, promote (writes `state/kernel`). Modules of current, previous, pending and
   anything staged are never removed; older ones may be (`bases remove` extends to
   modules).
4. Promote runs inside the test boot, where no hibernation image can exist, so it never
   waits. A `rollback` rewrites the default slot while the system runs; until the next
   reboot the slot then holds a different kernel from the running one, and a resume under
   it would be cancelled. So `glassine-hibernate` refuses (exit 3, with that reason) while
   `state/kernel` says the slot's kernel isn't the running one.

## What the user sees

`glassine-bootimg status` is the interface; the shell reads it and notifies:

- once, when an image is staged and waits for its test reboot, with a restart action
  (`glassine-bootimg reboot-test`);
- when a test boot failed, with the reason from `state/kernel`.

A successful promote needs no message.

## Deployment meta

`kernel=` in a deployment's `meta`: the release it last booted under, written at accept;
informational only. Kept so a per-deployment kernel (with a kexec loader) is a loader
change, not a format change: an empty value means "the device's default".

## Not covered here

- The kexec loader (it consumes the same subvolume and manifests).
- How `images` builds these (stages `kernel-<soc>`, `dtb-<device>`, `initramfs-<device>`,
  `boot-<device>`), signing and publishing.
