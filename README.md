# GlassineOS/boot

Boot initramfs and kernel update tools for devices whose bootloader boots Android
boot images and offers two boot slots: a default slot it boots normally and a test
slot it boots once when asked. A new kernel is always tried in the test slot first
and only becomes the default after a healthy boot, so a package upgrade cannot leave
the device unbootable.

Everything specific to one device lives in a board configuration
(`conf/board.conf.example`), which the device package ships.

## Contents

| Path | What |
|---|---|
| `initramfs/init`, `build-initramfs.sh` | the boot initramfs and its reproducible build |
| `sbin/glassine-bootimg` | stages, tests, promotes and rolls back kernels |
| `lib/glassine-bootimg-pack` | packs a header-v0 Android boot image from the board config |
| `openrc/glassine-bootimg-promote` | gives the verdict on a test boot |
| `sbin/glassine-reboot-clean`, `src/glassine-reboot.c` | an orderly reboot with a reboot reason (the way into the test slot) |
| `conf/board.conf.example` | every board key, documented |
| `sbin/glassine-deploy`, `lib/glassine-state.sh` | root deployments and their recovery interface (`status`, `list`, `select`, `rollback`, `hibernate-invalidate`, `reset`, `accept`); the shared state and hibernate-guard helpers |
| `lib/glassine-root.sh` | assembling a deployment's root: btrfs base + build layer + live upper (overlayfs), `/` read-only with writable `/etc`, `/var`, `/usr/local`, `/opt`; the interim try counter (prototype, not used by the initramfs yet) |
| `conf/deploy.conf.example` | where the system partition and userdata are |
| `test/` | host tests in an Alpine container |

## Boot roles

The same initramfs runs in both slots. The board's `DEFAULT_ROLE_MATCH` (a pattern
on the kernel command line) tells the two apart.

- **Default role** (a normal boot): checks the root file system (`ROOT_PART`,
  `ROOT_FSTYPE`), mounts it read-write and starts its init. The previous boot's
  kernel log (pstore) is saved to `/var/log/pstore/`. The hardware watchdog stays
  armed, so a hung kernel resets the device.
- **Test role** (a one-shot boot of the test slot): when the image is the one
  `glassine-bootimg` staged, it runs the default boot as that image's test.
  Otherwise it runs the default boot too, and reboots to the default slot if that
  fails.

## Kernel updates

```
apk upgrade ──► glassine-bootimg install KVER ──► test slot      (default slot untouched)
reboot-test ──► test boot ──► glassine-bootimg-promote ──► healthy? ──► copy to default slot
                                                       └─► no / hang ──► old kernel stays
```

1. The kernel package runs `glassine-bootimg install KVER`. It builds the boot image
   from the board's `KERNEL`, `DTB`, `INITRAMFS` and `CMDLINE`, writes it to the test
   slot and reads it back.
2. The user reboots into it with `glassine-bootimg reboot-test`. Nothing reboots on
   its own.
3. Late in that boot, `glassine-bootimg-promote` checks its health: at least 90 s of
   uptime, the root file system read-write, no crashed services, and every executable
   in `/etc/glassine-bootimg/health.d/` (60 s timeout each). If all pass, the tested
   bytes are copied to the default slot and read back.
4. A failed or hung test boot leaves the default slot alone. The next boot is the
   old kernel, and the image is marked failed. There are no automatic retries.

Other commands: `status` (one line for settings apps), `retry`, `rollback` (the
default slot back to the image before the last promote, when there was room to keep
it). A kernel that arrives during a test boot is staged after the verdict.

Packages can hook in at `/etc/glassine-bootimg/post-promote.d/` and `post-fail.d/`.
Each hook gets `KEEP` (the kernel versions whose modules must stay) as environment
and arguments, which is how a kernel package cleans up old modules safely.

## Board configuration

`/etc/glassine-bootimg/board.conf` holds the partitions, role detection, reboot
reason, image header fields and kernel command line. `glassine-bootimg-pack` copies
it into every boot image (`/etc/glassine-boot/board.conf`), so the initramfs and the
tools always agree. The initramfs package itself stays board-independent.

## Developer mode

`glassine.devmode=usb` on the kernel command line turns on USB networking at the
board's `DEVMODE_ADDR`, with a root shell (telnet, no password) and HTTP endpoints
that let a host drive test boots. **Anyone with a USB cable gets root**, so it is
off by default and only for development. A board config for end users must never
put it in `CMDLINE`. Without it, nothing listens on USB.

In developer mode, image builders can extend the initramfs with hooks
(`build-initramfs.sh --hook FILE --extra DIR`). The hooks register for three stages:
`pre-switch-root`, `endpoints` and `wait`. The interface is documented at the top of
`initramfs/init`.

## Supporting a new device

1. Write its `board.conf`, starting from `conf/board.conf.example`. Take the header
   fields from a boot image the device's bootloader is known to boot.
2. Ship it in a device package, together with any device-specific `health.d`
   checks.
3. Make sure the bootloader boots the test slot once on the board's
   `TEST_REBOOT_REASON`, and boots the default slot otherwise.

## Building and testing

```
make && make DESTDIR=… install    # tools (needs a C compiler + linux-headers)
make initramfs                    # inside an arm64 Alpine, see build-initramfs.sh
make check                        # host tests (Docker)
```

CI runs the host tests, builds the initramfs twice to prove it reproducible, runs
shellcheck, and checks that no board-specific names appear outside the example board
config.

## License

GPL-2.0-or-later (`LICENSE`).
