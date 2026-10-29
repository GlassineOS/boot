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

## Plain layout

`ROOT_PART` is checked (`fsck -p`) and mounted read-write. Then `switch_root`.

## Deployments layout

The data model is in [deployments.md](deployments.md). The default boot runs these
steps from `lib/glassine-root.sh`:

1. **Hibernation** (`gr_resume`), before anything is mounted. See below.
2. **Boot** (`gr_boot`):
   - The system partition is mounted read-write and `state/.lock` is taken.
   - Userdata gets `e2fsck -p` and is mounted.
   - The deployment is picked (one try used) and assembled with its modules
     subvolume for `uname -r`.
   - Fallbacks:
     - a candidate that does not assemble is marked failed;
     - after that come current, then previous;
     - without userdata, or with no deployment that assembles, a bare boot: the base
       read-only with a tmpfs upper (nothing kept). The base is current's, or else the
       last by name.
   - A state format newer than the initramfs is read but never written.
3. The boot's pstore save, the log and the developer hooks run. `/var` is writable.
4. **Carry** (`gr_carry`):
   - A tmpfs goes on `/run` of the new root. If the base has no `/run`, it is made
     through the overlay.
   - The system partition, userdata and the merged overlay are moved to
     `/run/glassine/{system,userdata,root}`.
   - The booted id is written to `/run/glassine/booted`.
   - The lock is released.
5. `switch_root`.

**The base must list `/` as `bind,ro` in `/etc/fstab`:** `overlay / overlay bind,ro 0 0`.
OpenRC's `root` service (pulled in by `localmount`) remounts `/` read-write unless
fstab says `ro`. It then remounts every fstab entry with `mount -o remount,<options>`,
so a plain `ro` would make the whole overlay read-only, `/etc` and `/var` included.
`bind,ro` changes only the `/` bind. Found by the QEMU test, 2026-10-29.

The test role makes no staged-image test boot in this layout: reading the pending
record would mean mounting userdata before the hibernation step.

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
glassine-hibernate now           hibernate; returns after the resume
```

`now` refuses while a switch runs (`switching`) or `glassine-deploy` holds the state
lock (exit 4), on a bare boot, without the swap file, a 4096-byte first block or
`disk` in `/sys/power/state` (exit 3). Otherwise it holds the state lock across the
hibernate, switches the swap file on (if it isn't), writes the guard, then
`resume_offset` and `resume` (the same block and device the initramfs will use),
`shutdown` to `/sys/power/disk`, stops the watchdog daemon (magic close) and writes
`disk` to `/sys/power/state`. When the kernel returns (resumed, or it refused), it
starts the watchdog again with its old arguments, removes the guard, switches the
swap file off again and makes sure it carries the plain swap signature. It never shuts
down or reboots by itself and never runs the shutdown switch.

## Files in the image

`build-initramfs.sh` adds `e2fsck`, `dumpe2fs` and `debugfs` (with their libraries)
and `/lib/glassine-boot/glassine-{state,root}.sh`. The build container needs
`busybox-static busybox-extras e2fsprogs e2fsprogs-extra cpio gzip`. btrfs and overlayfs
must be built into the kernel or loaded before `/init` needs them; no btrfs-progs is
used.
