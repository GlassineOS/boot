# Boot: the initramfs and its layouts

`initramfs/init` is PID 1 of the boot image. It has two roles (default and test) and
two root layouts. Roles, developer mode and hooks are described at the top of
`initramfs/init` and in the [README](../README.md). This page covers the root
layouts and the hibernation step.

Status of the deployments layout: built and host-tested ([testing.md](testing.md));
**not yet run on hardware**. The Note Air's board configuration still uses `plain`.

## Board keys

From `conf/board.conf.example` (shipped as `/etc/glassine-boot/board.conf` in the
image):

| Key | Default | Meaning |
|---|---|---|
| `ROOT_PART` | — | GPT name of the root (plain) or of the system partition (deployments) |
| `ROOT_FSTYPE` | `ext4` | its file system |
| `ROOT_LAYOUT` | `plain` | `plain` or `deployments` |
| `USERDATA_PART` | — | GPT name of userdata (deployments) |
| `USERDATA_PREFIX` | `media/glassine` | the directory on userdata, the same value as deploy.conf's |
| `HANDOFF` | empty | how a new kernel reaches the bootloader in the deployments layout: `bootpart-test`, `blocklist` (no board sets it yet: [blocklist.md](blocklist.md#board-keys)), empty = kernel updates paused ([kernel-artifacts.md](kernel-artifacts.md)) |
| `BLOCKLIST_RECORD_PART`, `BLOCKLIST_REBOOT_REASON`, `BLOCKLIST_ABL_PART`, `BLOCKLIST_ABL_SHA256` | — | the `blocklist` hand-off ([blocklist.md](blocklist.md#board-keys)) |
| `DEVICE` | — | the device name of the board's device trees (`<device>@<id>`), for `glassine-bootimg install` |
| `DEVICE_PART` | empty | GPT name of the ext4 partition that holds the device seed (`glassine/`); empty = no device data ([kernel-artifacts.md](kernel-artifacts.md#device-data-files-from-the-device-itself)) |

The booted system reads the same keys from `/etc/glassine-bootimg/board.conf`, which the
image builder installs (the seed tool takes `DEVICE_PART` from there).

## Plain layout

`ROOT_PART` is checked (`fsck -p`) and mounted read-write. Then `switch_root`.

## Deployments layout

The data model is in [deployments.md](deployments.md). The default boot runs these
steps from `lib/glassine-root.sh`:

1. **The kernel trial** (`gr_kernel_mode`): with a `glassine.img=` on the command line,
   `state/kernel` is read from the system partition mounted `ro,rescue=nologreplay`. The
   image `writing` names makes a finishing boot, `candidate_img` a trial
   ([kernel-artifacts.md](kernel-artifacts.md), "A kernel trial"). Neither resumes. A
   trial on the test slot runs the default boot without waiting for the host, as a
   staged image's test boot does in the plain layout.
2. **Hibernation** (`gr_resume`), before anything else is mounted. See below.
3. **Boot** (`gr_boot`):
   - The system partition is mounted read-write and `state/.lock` is taken.
   - A trial takes its kernel try (`tries=0`, `requested` cleared, one write).
   - Userdata gets `e2fsck -p` and is mounted.
   - The deployment is picked (one try used) and assembled with its modules
     subvolume for `uname -r`. On a trial or a finishing boot, current is assembled
     instead, with no pick and no deployment try.
   - The person's storage is bound into it: `home/` and `flatpak/` under the userdata
     prefix on `/home` and `/var/lib/flatpak`, and `/var/tmp` made a shared bind of
     itself (`gr_storage`; [deployments.md](deployments.md#the-persons-storage)). A
     bind that fails leaves the deployment's own directory and is reported in
     `/run/glassine/storage`; the boot goes on.
   - Fallbacks:
     - a candidate that does not assemble is marked failed;
     - after that come current, then previous;
     - without userdata, or with no deployment that assembles, a bare boot: the base
       read-only with a tmpfs upper (nothing kept, nothing bound from userdata; only
       `/var/tmp` is made shared). The base is current's, or else the last by name.
   - A state format newer than the initramfs is read but never written, and the boot is
     neither a trial nor a finishing boot.
4. The boot's pstore save, the log and the developer hooks run. `/var` is writable.
5. **Carry** (`gr_carry`):
   - A tmpfs goes on `/run` of the new root. If the base has no `/run`, it is made
     through the overlay.
   - The system partition, userdata and the merged overlay are moved to
     `/run/glassine/{system,userdata,root}`.
   - The booted id is written to `/run/glassine/booted`, and `trial`, `finishing` or
     nothing to `/run/glassine/kernel-boot` (`glassine-deploy-accept` skips the first
     two). What the storage step did goes to `/run/glassine/storage`.
   - The lock is released.
6. **Device data** (`gd_boot`, `lib/glassine-device.sh`), only when the root's
   `/usr/share/glassine/device-data.list` names files and the board has `DEVICE_PART`:
   the seed on `DEVICE_PART` is mounted `ro,noload` on `/run/glassine/device-part` and,
   if its files verify, `glassine/` bound read-only on `/run/glassine/device` and the
   firmware path set; otherwise nothing is bound and the seed service in sysinit fills
   it ([kernel-artifacts.md](kernel-artifacts.md#device-data-files-from-the-device-itself)).
   No list: no step, nothing logged.
7. `switch_root`.

**The base must list `/` as `bind,ro` in `/etc/fstab`:** `overlay / overlay bind,ro 0 0`.
OpenRC's `root` service (pulled in by `localmount`) remounts `/` read-write unless
fstab says `ro`. It then remounts every fstab entry with `mount -o remount,<options>`,
so a plain `ro` would make the whole overlay read-only, `/etc` and `/var` included.
`bind,ro` changes only the `/` bind. Found by the QEMU test, 2026-10-29.

The test role's staged-image test boot is the kernel trial of step 1 in this layout:
the plain layout's pending record would be on userdata, which nothing mounts before the
hibernation step.

## Hibernation

The swap file is `<prefix>/swap/hibernate` on userdata, and the guard file sits next to
it ([format](deployments.md#the-hibernate-guard)). The rules:

1. **Nothing before it.** No fsck and no read-write mount of either partition before
   this step. A read-only ext4 mount would still replay the journal, and a btrfs mount
   its log tree. Userdata is read only with `debugfs`. The system partition may be
   mounted `ro,rescue=nologreplay` to read `state/`, and is unmounted again before the
   resume write.
2. **Finding the image.** `debugfs bmap` gives the file's first block. The swap header
   there must carry `S1SUSPEND` at byte 4086. Userdata's block size must be 4096 (the
   page size); otherwise there is no resume and nothing is written.
3. **When it resumes.** All five guard keys must match, and `state/` (read without a
   write) must boot the guard's deployment. A boot in the test role and a boot with
   `glassine.noresume` on the command line never resume.
4. **The resume write.** `resume_offset` = the block, then `maj:min` of userdata to
   `/sys/power/resume`. The watchdog is stopped right before (busybox's magic close;
   the SoC watchdog can't wait out an image load) and re-armed if the write returns.
5. **Otherwise: cancel.** `SWAPSPACE2` is written back over the signature on the raw
   device, followed by `sync` and `blockdev --flushbufs`. It is the only write before
   the mounts. If that fails, nothing is mounted and the boot stops.

The hibernate step is `glassine-hibernate` (the running system):

```
glassine-hibernate setup [MIB]   create the swap file (default: half the RAM)
glassine-hibernate check         would `now` hibernate? exit 0 = yes
glassine-hibernate now [--reboot]  hibernate; returns after the resume
```

`now` refuses while a switch runs (`switching`) or `glassine-deploy` holds the state
lock (exit 4), on a bare boot, without the swap file, a 4096-byte first block or
`disk` in `/sys/power/state`, and when the state would boot another deployment next
(a candidate on its last try, or one selected since this boot), because the initramfs
would then cancel the image (exit 3). Otherwise it holds the state lock across the
hibernate, switches the swap file on (if it isn't), writes the guard, then
`resume_offset` and `resume` (the same block and device the initramfs will use),
`shutdown` to `/sys/power/disk` (exit 3 if the kernel doesn't offer the mode), stops the watchdog daemon (magic close) and writes
`disk` to `/sys/power/state`. When the kernel returns (resumed, or it refused), it
starts the watchdog again with its old arguments, removes the guard, switches the
swap file off again and makes sure it carries the plain swap signature. `--reboot`
writes `reboot` instead of `shutdown` (bring-up: a failed resume keeps pstore); a
kernel without `/sys/power/disk` can only use its default (power off), so `--reboot`
refuses there (exit 3). The watchdog is restarted directly, not through the init
system: a watchdog service's pidfile goes stale (the initramfs starts it, so
nothing reads that pidfile today).

Device steps belong to the board, not to this tool: executables in
`HIBERNATE_HOOKS` (default `/etc/glassine/hibernate.d`) run in name order with `pre`
before anything is written (a failure cancels the hibernate, exit 1), and in reverse
order with `post resumed` or `post failed` when the kernel returns or after a cancel.
A post hook must cope with a pre step that did not run. It never shuts
down or reboots by itself and never runs the shutdown switch.

## Slots

On a dual-boot device the bootloader's A/B slots hold two systems (the Note Air:
A = Android, B = GlassineOS), not two copies of one. The bootloader's tries are then
the fallback between them, below the deployment tries of one system: a slot that
never reaches a working system (a broken kernel or initramfs) runs out of tries and
the bootloader boots the other slot.

`glassine-slot` (`src/glassine-slot.c`) reads and writes that state in the GPT
attributes of `boot_a`/`boot_b`, in the scheme of Qualcomm's bootloader (ABL): bits
48-49 priority, 50 active, 51-53 tries, 54 successful, 55 unbootable. ABL boots the
active slot with the highest priority; it counts one try per boot while the slot is
not successful, and with no tries left it marks it unbootable and boots the other
slot **only if that one is successful**. So a fallback target must have been marked
successful by its own system.

| Command | Does |
|---|---|
| `status [--porcelain]` | both slots, the booted one (`androidboot.slot_suffix`), and the one ABL boots next |
| `set-active a\|b [--successful]` | ABL's own `set_active` on its attributes: the slot gets priority 3, 7 tries, not successful; the other keeps its state with priority 2. `--successful`: marked successful at once, for a system that can't mark itself. Only on the layout below |
| `mark-successful [a\|b]` | the booted slot (default) works: successful, no tries counted (tries back to 7); no write when it already is |
| `reset-tries [a\|b]` | not successful again with 7 tries: after a kernel update in that slot |

ABL's `set_active` does more than the attributes when the slot changes: it swaps
the partition type GUIDs of each `_a`/`_b` pair, and on UFS it switches the boot LUN.
At boot it refuses a slot whose `boot` partition has the type GUID of that slot's
`system` partition, or that has no `system` partition. `glassine-slot` writes only
the attributes, which is the same thing on an eMMC disk where each `_a`/`_b` pair
shares its type GUID (the [A/B guide](https://docs.glassine.org/guides/ab-on-single-slot/)'s
layout). Anywhere else `set-active` refuses (exit 3); the other commands only touch
the attributes and work on any layout.

Only the two attribute words change; when the two GPT copies differ elsewhere it
refuses (exit 3). It writes the backup copy first, then the primary, each with
fsync, and reads both back. A cut between the writes leaves the primary (what ABL
reads) on the old state; a broken copy is rebuilt from the valid one on the next
write. Exit codes: 0, 1 I/O, 2 usage, 3 refused, 6 busy (`flock` on the disk).

Who marks a slot successful: GlassineOS's accept service, once a boot is healthy,
whichever deployment booted. A system without a marker (the Note Air's Android
today) must stay marked successful by hand, or each of its boots uses up a try.

## Files in the image

`build-initramfs.sh` adds `e2fsck`, `dumpe2fs` and `debugfs` (with their libraries)
and `/lib/glassine-boot/glassine-{state,root}.sh`. The build container needs
`busybox-static busybox-extras e2fsprogs e2fsprogs-extra cpio gzip`. btrfs and overlayfs
must be built into the kernel or loaded before `/init` needs them; no btrfs-progs is
used.
