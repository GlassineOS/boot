# Testing

`make check` runs four host suites in Docker (Alpine 3.22, busybox userland as on the
device). Each prints `ok`/`FAIL` lines; exit 0 = all pass.

| Suite | Container | What it proves |
|---|---|---|
| `test/bootimg` | plain | `glassine-bootimg`'s state machine: install, test boot, promote, fail, retry, rollback, on 64 MiB slot files |
| `test/initramfs` | plain, stubs for mount/switch_root/reboot/USB servers | the init's roles, developer mode (never on by default, nothing listens without it), hooks, other board configs; in the deployments layout: the libraries are sourced, the root partition is looked up, no staged-image peek |
| `test/deploy` | plain, fake mounts | the state library (key=value, atomic writes, format check), `glassine-deploy` commands and porcelain, the hibernation gate, the shutdown hook's rules (user shutdown, charger, battery threshold, failure exit) on a stub |
| `test/root` | **privileged** (loop devices, mounts) | real btrfs + ext4 + overlayfs: the locked root (read-only `/`, writable `/etc` `/var` `/usr/local` `/opt`, copy-up, whiteouts, rename-replace, base unchanged), modules, bare boot, persistence, the try counter, reset → switch → candidate → accept/failed, interrupted switch, stale marker, space check, cut meta write, userdata mounted elsewhere; the hibernation step (no image, `noresume`, no guard, userdata mounted since, other kernel build, other deployment, every check passing → the resume write with the watchdog stopped, then cancel when the kernel returns); `gr_boot` with its fallbacks and a newer state format; `gr_carry` and `glassine-deploy` working on the carried mounts; the shutdown switch in the running deployment after OpenRC-style unmounts, with a submount that must not be carried |

CI (`.github/workflows/test.yml`) also builds the initramfs twice and compares the
two (reproducible).

## Proven where

| Behaviour | Host test | Hardware |
|---|---|---|
| plain layout boot, roles, developer mode | ✅ (stubs) | ✅ the daily boot today |
| deployments: state, pick, fallbacks, locked root, reset/switch/accept | ✅ real file systems | not yet |
| initramfs end to end in the deployments layout (mounts moved, `switch_root`, OpenRC start) | stubs only | not yet |
| hibernation decision + cancel | ✅ real devices | not yet |
| a real resume (the kernel reads the image) | no (the resume files are plain files in the test) | not yet; the kernel's own `test_resume` passed on the Note Air (2026-10-27) |
| OpenRC: keeps the pre-mounted `/run`; shutdown-runlevel order; which mounts remain at the hook | no (assumed from OpenRC's design) | not yet |
| the initramfs's extra tools run on arm64 | ✅ (arm64 container) | not yet |
| the device kernel (mainline 7.3, SDM636) | no: tests run on the host kernel | not yet |

What the host can't prove: the device kernel's overlayfs and btrfs behaviour, the real
init system, timing under the hardware watchdog, and a real resume. An end-to-end
QEMU (arm64) boot test would cover all but the device kernel, and is planned.
