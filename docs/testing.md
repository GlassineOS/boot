# Testing

`make check` runs four host suites in Docker (Alpine 3.22, busybox userland as on the
device). Each prints `ok`/`FAIL` lines; exit 0 = all pass.

| Suite | Container | What it proves |
|---|---|---|
| `test/bootimg` | plain | `glassine-bootimg`'s state machine: install, test boot, promote, fail, retry, rollback, on 64 MiB slot files |
| `test/initramfs` | plain, stubs for mount/switch_root/reboot/USB servers | the init's roles, developer mode (never on by default, nothing listens without it), hooks, other board configs; in the deployments layout: the libraries are sourced, the root partition is looked up, no staged-image peek |
| `test/deploy` | plain, fake mounts | the state library (key=value, atomic writes, format check), `glassine-deploy` commands and porcelain, the hibernation gate, the shutdown hook's rules (user shutdown, charger, battery threshold, failure exit) on a stub; the accept service's rules (only the booted candidate, uptime wait, crashed service, failing or timed-out health check) |
| `test/root` | **privileged** (loop devices, mounts) | real btrfs + ext4 + overlayfs: the locked root (read-only `/`, writable `/etc` `/var` `/usr/local` `/opt`, copy-up, whiteouts, rename-replace, base unchanged), modules, bare boot, persistence, the try counter, reset → switch → candidate → accept/failed, interrupted switch, stale marker, space check, cut meta write, userdata mounted elsewhere; the hibernation step (no image, `noresume`, no guard, userdata mounted since, other kernel build, other deployment, every check passing → the resume write with the watchdog stopped, then cancel when the kernel returns); `gr_boot` with its fallbacks and a newer state format; `gr_carry` and `glassine-deploy` working on the carried mounts; the shutdown switch in the running deployment after OpenRC-style unmounts, with a submount that must not be carried |

CI (`.github/workflows/test.yml`) runs all four and also builds the initramfs twice and
compares the two (reproducible).

`test/qemu/test.sh` (not in `make check`: about 10 minutes, emulated) boots the real
initramfs and a real OpenRC system in QEMU (arm64, Alpine's virt kernel) from a GPT disk
with a btrfs system partition and an ext4 userdata, through four boots:

1. d1 boots. Checks: `/run/glassine/booted` and the moved mounts survive OpenRC, `/` is
   read-only, `/etc` and `/var` are writable, the modules subvolume is bound, the state
   lock is free. Then a reset, a change after it, `--user-shutdown`, `poweroff`: the
   switch runs in the shutdown runlevel.
2. The reset boots as the candidate (1 try left), the migrate list is carried
   (including the change made after the reset), other files aren't; the
   `glassine-deploy-accept` service accepts it after 40 s with its health check
   passing; hibernate.
3. The initramfs resumes the image (memory state kept); hibernate again.
4. With `glassine.noresume`: the image is cancelled, the initramfs logs why, the
   accepted deployment boots fresh, and the accept service leaves it alone.

A test shim in front of `/init` loads the virt kernel's modules (virtio, ext4, btrfs,
overlay), and the agent in the base (`test/qemu/agent.sh`) plays the hibernate step. The
virt kernel has no watchdog driver, so the watchdog stop around the resume is covered by
`test/root` only.

## Proven where

| Behaviour | Host test | Hardware |
|---|---|---|
| plain layout boot, roles, developer mode | ✅ (stubs) | ✅ the daily boot today |
| deployments: state, pick, fallbacks, locked root, reset/switch/accept | ✅ real file systems; ✅ QEMU | not yet |
| the boot-success service accepting a healthy candidate | ✅ stubs (test/deploy); ✅ QEMU | not yet |
| initramfs end to end in the deployments layout (mounts moved, `switch_root`, OpenRC start) | ✅ QEMU (2026-10-29) | not yet |
| hibernation decision + cancel | ✅ real devices; ✅ QEMU (`noresume`) | not yet |
| a real resume through the initramfs (the kernel reads the image) | ✅ QEMU (2026-10-29) | not yet; the kernel's own `test_resume` passed on the Note Air (2026-10-27) |
| OpenRC: keeps the pre-mounted `/run`; the shutdown runlevel runs the switch; the lock survives `localmount` and `root` | ✅ QEMU, with the base's `bind,ro` fstab line ([boot.md](boot.md#deployments-layout)) | not yet |
| the watchdog stop around the resume | ✅ order only (test/root) | not yet |
| the initramfs's extra tools run on arm64 | ✅ (arm64 container, QEMU) | not yet |
| the device kernel (mainline 7.3, SDM636) | no: the host kernel, Alpine's virt kernel 6.12 in QEMU | not yet |

What the host can't prove: the device kernel's overlayfs, btrfs and hibernation
behaviour, timing under the hardware watchdog (and the SoC's 31 s limit), and the
device's own init scripts (the image's services, the kit).
