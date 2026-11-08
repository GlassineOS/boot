# Testing

`make check` runs nine host suites in Docker (Alpine 3.22, busybox userland as on the
device). Each prints `ok`/`FAIL` lines; exit 0 = all pass.

| Suite | Container | What it proves |
|---|---|---|
| `test/bootimg` | plain | `glassine-bootimg`'s state machine: install, test boot, promote, fail, retry, rollback, on 64 MiB slot files |
| `test/initramfs` | plain, stubs for mount/switch_root/reboot/USB servers | the init's roles, developer mode (never on by default, nothing listens without it), hooks, other board configs; in the deployments layout: the libraries are sourced, the root partition is looked up, no staged-image peek |
| `test/deploy` | plain, fake mounts | the state library (key=value, atomic writes, format check), `glassine-deploy` commands and porcelain, the hibernation gate, the shutdown hook's rules (user shutdown, charger, battery threshold, failure exit) on a stub; the accept service's rules (only the booted candidate, uptime wait, crashed service, failing or timed-out health check); the account merge (kept users and groups, a taken gid, swapped system IDs, memberships, passwords by name, a lost system account, shadow owner and mode, subuid) and the owner remap (one pass, spaces, links, setuid); `packages` (added/removed world entries, raised/lowered/changed versions, a deployment not running) |
| `test/root` | **privileged** (loop devices, mounts), own PID namespace (`unshare`) | real btrfs + ext4 + overlayfs: the locked root (read-only `/`, writable `/etc` `/var` `/usr/local` `/opt`, copy-up, whiteouts, rename-replace, base unchanged), modules, bare boot, persistence, the try counter, reset → switch → candidate → accept/failed, interrupted switch, stale marker, space check, cut meta write, userdata mounted elsewhere; the hibernation step (no image, `noresume`, no guard, userdata mounted since, other kernel build, other deployment, every check passing → the resume write with the watchdog stopped, then cancel when the kernel returns); the hibernate step (`glassine-hibernate`: setup and its space check, the refusals, the guard as the initramfs reads it, the resume files, swap on/off, the watchdog stopped and restarted without the state lock, device hooks in order and a failing pre hook, `--reboot`, the next boot not resuming into it, a refused hibernate, unwritable resume files, the board's `DEVICE_PART` mounted read-write); `gr_boot` with its fallbacks and a newer state format; `gr_carry` and `glassine-deploy` working on the carried mounts; the shutdown switch in the running deployment after OpenRC-style unmounts, with a submount that must not be carried (nor home and Flatpak's data, and the person's `/home` bind is never taken for userdata's own mount); the power-off step (`gr_shutdown_ro`: userdata kept alive only by the overlay made read-only with a clean journal, the overlay's upper read-only after it, the system partition read-only with a mount of it still in the table, a file system that isn't mounted left unwritten); the person's storage (`gr_storage`: `home/` and `flatpak/` made on userdata `root:root 0755` and bound, writes landing on userdata, the deployment's own `/home` hidden and not moved, `/var/tmp` a shared bind of itself, the record in `/run/glassine/storage` and `status`'s keys, a bind that fails and a directory that can't be made: logged, the deployment's own directories, nothing written, the next boot binding both; a bare boot binding nothing); the initramfs's device data step (`gd_boot` on a real ext4 `DEVICE_PART`: no seed, a seed that verifies with a line not held, bound read-only with the firmware path, `firmware_class.path` on the command line, a damaged copy, a stray file, a journal that needs recovery, the partition's other files untouched); `receive` (wrong checksum, cut stream, two subvolumes, a name that exists, `.zst`, an incremental stream onto the received base, `--modules`), `bases`, `stage` (unknown base, bad name, a base without accounts) → switch with the account merge and the remapped owners → the candidate's root on the new base; `glassine` on a real locked root (the acknowledgement, a read-only command, `add` writable for its run only and landing in the upper, apk's exit code, a second change waiting for the lock, unlock/lock, called as `apk`, outside a deployment) |
| `test/replay` | **privileged** (loop devices, mounts) **and network** (Alpine's package repositories), real `apk` | `glassine-deploy stage` replaying the user's packages on a new base, with a real Alpine base, a btrfs system partition and an ext4 userdata: added and removed packages land in the new deployment's build layer and world, the running root is untouched, and the switch selects a candidate that has them; `--no-replay`; the offline replay from the cache; a package that no longer resolves (exit 7: nothing staged, the chroot mounts and the new deployment removed); `--without`; a repository the user added; a version that would go down (exit 7, named) and `--accept-downgrades`; a replay staged from a deployment that is not the booted one (its read-only view: the cache must still be writable) |
| `test/blocklist` | **privileged** (loop devices, mounts) | the block-list hand-off's library on real ext4: `FIEMAP` and the extent checks, the record, the raw read-back, the ash record helpers on a slot, a simulated bootloader reader written from `docs/blocklist.md`, and `glassine-bootimg` with `HANDOFF=blocklist` through install, reboot-test, trial, accept, cancel, retry and rollback, cut and failed writes included |
| `test/seed` | **privileged**, a directory per partition (`GLASSINE_SEED_FAKE`), one real vfat image on a loop device | `glassine-device-seed` and the list and manifest formats: no list, an empty list, no `DEVICE_PART`, invalid lists (a source on `DEVICE_PART`, bad names, a name twice), a newer format; the first seed, its manifest, the firmware path without a newline (not with `firmware_class.path` on the command line); later boots read nothing; a damaged copy, a source gone, a changed source and `refresh` (now and at the next boot), a grown and a shorter list, split images by their program headers (synthetic ELF32 and ELF64 `.mdt` files: the hash segment, a segment with no file bytes and one inside the `.mdt` need no part, parts the headers don't need not copied, a needed part missing, a `.mdt` that isn't ELF, no `.mdt`, fewer parts on a refresh, a damaged seed `.mdt`), an upper-case 8.3 split image on a real vfat source, a name the kernel's firmware provides; writes cut off before and after the manifest's rename (the cut refresh done again), a failed write, a refused read-write mount, no manifest, a stray file, a journal replay, a bad waveform, `blkid` output of busybox and util-linux, an unknown file system |
| `test/devmode` | plain, stubs for the network, the address server, the SSH server and `ssh-keygen`, a configfs stand-in | `glassine-devmode`: nothing without `glassine.devmode=usb` (no call, no folder, nothing said), a bare boot and a plain boot (no folder, said), no `DEVMODE_ADDR`; the developer folder `root:root 0700` (a looser mode fixed), the host key made once, the NCM gadget on the first UDC, NetworkManager told to leave its interface alone, the address and the developer range on that interface, the SSH server's configuration (one listen address, the folder's keys, no passwords), status, a second start, stop, no developer range, `DEVMODE_NETDEV`, a UDC that appears while start waits, no UDC after the wait |
| `test/slot` | plain (a disk image, sgdisk as an independent writer and checker) | `glassine-slot`: status and the next-boot rule (with ABL's first-boot default when no slot is active), set-active / mark-successful / reset-tries bits (checked with sgdisk), only the two attribute words change, no write when nothing changes, the refusals (no booted slot, no boot_a/boot_b, copies differing beyond the attributes (entries or headers), both copies broken, set-active where ABL's set_active would also swap type GUIDs or refuse the slot), cut writes after each step and the re-run, a broken or zeroed primary/backup rebuilt from the other (refused with no room for the rebuilt primary's entries), a 64-entry table whose rebuilt backup array goes where ABL keeps it (16 KiB before the last LBA) and stays valid after ABL's attribute write (modelled in `test/slot/gpt.py`), read-back mismatch, busy; the plain build (what `make` installs) without the test hooks |

`test/root` also runs on a device (for its kernel's btrfs, ext4 and overlayfs): the
same `inner.sh` in an Alpine chroot with this repository at `/p` (the chroot
directory bind-mounted onto itself, so `unshare --mount-proc` can make it private). It runs itself in a
new PID namespace, because the hibernate checks stop and restart the watchdog daemon
they find by name, and outside one they would find the device's real one.

CI (`.github/workflows/test.yml`) runs all nine (`test/root`, `test/replay`, `test/blocklist` and `test/seed` need a privileged Docker, `test/replay` also the network) and also builds the initramfs twice and
compares the two (reproducible).

`test/qemu/test.sh` (not in `make check`: about 45 minutes, emulated) boots the real
initramfs and a real OpenRC system in QEMU (arm64, Alpine's virt kernel) from a GPT disk
with a btrfs system partition, an ext4 userdata, an empty ext4 `devdata` (the board's
`DEVICE_PART`) and two source partitions (ext4 `srcext`, vfat `srcvfat`), through twelve
boots:

1. d1 boots. Checks: `/run/glassine/booted` and the moved mounts survive OpenRC, `/` is
   read-only, `/etc` and `/var` are writable, the modules subvolume is bound, the state
   lock is free. Then a reset, a change after it, `--user-shutdown`, `poweroff`: the
   switch runs in the shutdown runlevel.
2. The reset boots as the candidate (1 try left), the migrate list is carried
   (including the change made after the reset), other files aren't; the
   `glassine-deploy-accept` service accepts it after 40 s with its health check
   passing; `glassine-hibernate setup` + `check` + `now`.
3. The initramfs resumes the image (memory state kept, the guard removed); hibernate
   again.
4. With `glassine.noresume`: the image is cancelled, the initramfs logs why, the
   accepted deployment boots fresh, and the accept service leaves it alone. Then a
   full reset and a user shutdown.
5. The full reset boots as the candidate: nothing carried, the same home and Flatpak
   data. `flatpak/` on userdata is then replaced by a file.
6. The storage step can't make `flatpak/`: logged, `status` says `flatpak=failed`, the
   deployment's own `/var/lib/flatpak`, the file untouched, home still bound. A
   device-data list from here on, in the deployment's upper directory (boots 1–6 have
   none: no device-data step in the log, `DEVICE_PART` reads as built).
7. The initramfs finds no seed; the seed service fills it: a split image, a rename into
   a directory, the waveform, a vfat source; complete, bound read-only, the firmware
   path without a newline; `glassine-hibernate` refuses while `DEVICE_PART` is mounted
   read-write. A copy is damaged.
8. The initramfs binds nothing; the service copies it again. A changed source is left
   out until `refresh --now`; a source gone keeps the seed's copy. A grown list's fill is
   cut off (sysrq power off) right after the manifest's rename.
9. Complete with the grown list after the cut. A shorter list, a name the kernel's
   firmware provides, a split image missing a part its program headers need, a source on `DEVICE_PART`: none changes
   the manifest. A refresh is cut off before the manifest's rename.
10. The initramfs binds nothing; the cut refresh is done again at boot: complete, the
    new bytes, no temp file. A developer key goes into `devmode/`.
11. With `glassine.devmode=usb` (a dummy interface stands in for the USB gadget): the
    developer folder `root:root 0700` with its host key, the address server, SSH
    listening only on `DEVMODE_ADDR`, a login with the key, refused with another key and
    with a password. A reset and a user shutdown.
12. With `glassine.devmode=usb`: the reset's deployment, the same host key, the login.

Boots 1–10 have no `glassine.devmode`: no SSH server, no address server, no developer
folder.

After every device-data boot the source partitions read as the test left them.

Every boot of a deployment checks the person's storage: `home/` and `flatpak/` bound
from userdata, `/var/tmp` shared, d1's own `/home` (in its build layer) hidden and
reported by `status`, the files written on d1 still there after the reset.

After boots 1 and 4, which power off, both file systems are checked as the next boot
finds them (`btrfs check --readonly`; userdata's journal needs no replay and
`e2fsck -fn` passes).

A test shim in front of `/init` loads the virt kernel's modules (virtio, ext4, btrfs,
overlay, vfat), and the agent in the base (`test/qemu/agent.sh`) drives each stage. The
virt kernel has no watchdog driver, so the watchdog stop around the resume is covered by
`test/root` only.

`test/qemu/test.sh --base FULL.btrfs.zst [--base2 DELTA.btrfs.zst] [--base2-file PATH]`
boots an outside base instead, as an image builder makes it (GlassineOS/images runs it
as its acceptance test). The harness keeps its kernel, modules (a `modules/<release>`
subvolume) and initramfs (the deployments board configuration). The base is received
with `btrfs receive` into `bases/` (read-only, with a received UUID, as on a device)
and never changed. What the test adds goes into the first deployment's own build layer
(`build-base.sh`): the agent (`agent-base.sh`, as `/usr/local/sbin/qtest-agent`), its
OpenRC service and runlevel link, two health checks, the base's `deploy.conf` with the
test disk's devices and `ACCEPT_AFTER=40`, a guard that keeps `bluetooth` from starting
(the virt kernel has no Bluetooth, and a crashed service would block every accept), a
pass in place of the base's health checks of its graphical session (`*desktop*`: no
panel in the VM), and a migrate list naming all of these, so each switch carries them into the next
deployment like any other setting. The guest runs the base's own `glassine-deploy` and
has QEMU user networking for the live package. Boots, each followed by a read-only
check of both file systems from the host (`btrfs check`, `e2fsck -fn`, ext4
`needs_recovery`):

1. d1 (the candidate, no current yet) comes up: booted, `/` the read-only overlay of
   its build layer and base, the machine id filled in, every enabled service of
   sysinit, boot and default started and none crashed; the boot-success step accepts
   it. `apk add tree` live through the base's wrapper, and `packages` names it; a file
   of the base's migrate list and an account changed; the delta received; `stage`
   replays the package; a user shutdown switches.
2. The staged deployment boots as the candidate on the second base: the second base's
   file, the migrate list, the machine id and the account carried, the package
   replayed; accepted; `rollback`.
3. d1 again, with its own state; accepted; `reset`; a user shutdown.
4. The reset: the migrate list kept, the package gone; accepted; another `reset`,
   marked to fail its health check.
5. and 6. That candidate is not accepted (its two tries).
7. The reset boots as current again, the candidate is marked failed.

A boot that does not power off within `QTEST_BOOT_TIMEOUT` fails, and the run stops
after the first boot with a failed check (`--keep-going` goes on). Hibernation needs
this repository's code in the base, so it stays on the default path.

## Proven where

| Behaviour | Host test | Hardware |
|---|---|---|
| plain layout boot, roles, developer mode | ✅ (stubs) | ✅ the daily boot today |
| deployments: state, pick, fallbacks, locked root, reset/switch/accept | ✅ real file systems; ✅ QEMU | not yet |
| the person's storage (home and Flatpak on userdata, `/var/tmp` shared, failures) across a reset and a full reset | ✅ real file systems; ✅ QEMU | not yet |
| device data: the list, the seed, the initramfs step, the seed service, cut writes, the clashes with the kernel's firmware | ✅ plain directories (test/seed); ✅ real ext4 (test/root, test/bootimg); ✅ QEMU | not yet |
| developer access in the booted system (SSH with the folder's keys only, on `DEVMODE_ADDR` only) | ✅ stubs (test/devmode); ✅ QEMU, a dummy interface for the USB gadget | not yet (the USB gadget itself) |
| the kernel loading firmware from the seed in the same boot | no: the virt kernel has no firmware test driver; QEMU checks only the parameter's value | not yet |
| the boot-success service accepting a healthy candidate | ✅ stubs (test/deploy); ✅ QEMU | not yet |
| initramfs end to end in the deployments layout (mounts moved, `switch_root`, OpenRC start) | ✅ QEMU (2026-10-29) | not yet |
| hibernation decision + cancel | ✅ real devices; ✅ QEMU (`noresume`) | not yet |
| the hibernate step (guard, resume files, swap, watchdog) | ✅ real ext4, stubbed swapon and `/sys/power`; ✅ QEMU (a real hibernate and resume) | not yet |
| a real resume through the initramfs (the kernel reads the image) | ✅ QEMU (2026-10-29) | not yet; the kernel's own `test_resume` passed on the Note Air (2026-10-27) |
| OpenRC: keeps the pre-mounted `/run`; the shutdown runlevel runs the switch, then leaves userdata and the system partition read-only (clean at the next boot); the lock survives `localmount` and `root` | ✅ QEMU, with the base's `bind,ro` fstab line ([boot.md](boot.md#deployments-layout)) | not yet |
| the watchdog stop around the resume | ✅ order only (test/root) | not yet |
| the initramfs's extra tools run on arm64 | ✅ (arm64 container, QEMU) | not yet |
| `glassine-slot` (GPT slot attributes, both copies) | ✅ disk images, sgdisk-checked (test/slot) | not yet |
| the device kernel (mainline 7.3, SDM636) | no: the host kernel, Alpine's virt kernel 6.12 in QEMU | not yet |

What the host can't prove: the device kernel's overlayfs, btrfs and hibernation
behaviour, timing under the hardware watchdog (and the SoC's 31 s limit), and the
device's own init scripts (the image's services, the kit).
