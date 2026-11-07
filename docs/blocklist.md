# Block-list hand-off: a cold boot of a kernel file

Status: **proposed design, under review ([hub#54](https://github.com/GlassineOS/hub/issues/54));
nothing here is implemented.** It is the `HANDOFF=blocklist` row of
[kernel-artifacts.md](kernel-artifacts.md#kernel-records-trials-and-hand-off), for the
Note Air ([hub#53](https://github.com/GlassineOS/hub/issues/53)). The records, the trial
and accept are that page's; this page adds only how the bootloader gets the candidate's
image, and what each command does for it. The bootloader side is checked for feasibility
first ([hub#55](https://github.com/GlassineOS/hub/issues/55)); nothing is flashed before
this page is merged.

## The idea

Linux writes the candidate's packed boot image as an immutable file on userdata, and
writes the file's storage blocks and its checksum into a small **record** at the end of
the default slot. `glassine-bootimg reboot-test` reboots with a reboot reason of its own.
On that one boot the bootloader reads the record, reads the blocks, checks the
checksum and boots the image as if it came from the default slot. Without the reason,
or when any check fails, it boots the default slot as it does today.

Nothing the bootloader does in this path writes storage. The only writes are Linux's:
the file (through ext4), the record (4 KiB at a fixed place) and, on accept, the default
slot (as `bootpart-test` writes it today).

## Where the image file lives

**userdata** (decided 2026-11-07, hub#54): `<USERDATA_PREFIX>/kernel/<id>.img`, where
`<id>` is the image id (`glassine.img=`). It replaces `state/bootimg/<id>.img` for this
hand-off: the bootloader can't read btrfs, and the system partition's blocks aren't
stable. `state/bootimg/<id>.manifest` stays where kernel-artifacts.md puts it.

Why userdata (ext4) and not the system partition (btrfs):

- ext4 doesn't move a file's data blocks while the file exists, unless something asks it
  to. The two things that could are online defrag and an offline resize or fsck. Online
  defrag (`EXT4_IOC_MOVE_EXT`) needs the file open for writing, which an immutable file
  refuses (`fs/ext4/ioctl.c`, `linux@d476aaa`). The other two run only with userdata
  unmounted, and they are caught below.
- btrfs maps a file through its chunk tree, and a balance relocates chunks, no-COW
  files included. Nothing in btrfs guarantees that a file keeps its physical blocks.
- There's a precedent: the hibernate image is already read from userdata's raw blocks
  ([boot.md](boot.md#hibernation)).

The file is written in full and then made immutable: never preallocated and left
unwritten, because an unwritten extent reads as zeros through ext4 but as old data on
the raw device (as with the swap file, `sbin/glassine-hibernate`). Its blocks are listed
with `FIEMAP`, and the writer refuses any extent flagged `UNWRITTEN`, `UNKNOWN`,
`DELALLOC`, `ENCODED`, `DATA_ENCRYPTED`, `NOT_ALIGNED`, `DATA_INLINE`, `DATA_TAIL` or
`SHARED`. It also refuses a file system whose block size isn't 4096, a userdata mounted
with `data=journal` (data could still be in the journal), and a directory with
encryption set.

**What can still break the file, and what happens then.** Every one of these ends in a
checksum mismatch and a boot of the default slot. None of them can make the bootloader
read outside userdata or boot a damaged image:

| Event | Effect |
|---|---|
| Android's Format Data, or a `mke2fs` of userdata | the file is gone; its blocks hold other data |
| Android full-disk encryption turned on | the blocks become ciphertext. On this device that also erases or locks `/home` ([Storage, slots and data](https://docs.glassine.org/devices/onyx-noteair/#storage-slots-and-data)), so it isn't a supported state anyway |
| an offline `resize2fs` that shrinks userdata | blocks may move |
| `e2fsck` cloning blocks that two files claim | that file's blocks change |
| someone with root runs `chattr -i` and rewrites or deletes it | anything |

`glassine-bootimg reboot-test` reads the image back through the raw device (below)
before it sets the reboot reason, so all of these are caught before the reboot, as long
as they happen before `reboot-test`. Between `reboot-test` and the bootloader nothing
else runs. On Android, the immutable flag also keeps apps and the media scanner from
deleting the file.

Android's encryption (hub#54's question): this device's Android uses full-disk
encryption, which is turned off (2026-06-08,
[Dead ends](https://docs.glassine.org/dead-ends/#decrypting-stock-androids-data-from-recovery-or-another-os)).
If it were turned on, the case is the table's second row: the bootloader reads
ciphertext, the checksum fails, and the default slot boots.

## The record

**Where:** the last 4096 bytes of the default slot (board key `BLOCKLIST_RECORD_PART`,
on the Note Air `boot_b`, 64 MiB). The bootloader already opens that partition on every
boot. Nothing reads its tail today: a header v0 image ends where its sizes say it does.
The default image may not reach into the record area, so the packer's limit for these
boards is `PART_SIZE - 4096`.

Alternatives considered, and why not:

| Place | Why not |
|---|---|
| `misc` beyond Android's 64 KiB | Android and the bootloader keep the boot control block there (the stale recovery request in [Undoing each step](https://docs.glassine.org/devices/onyx-noteair/#undoing-each-step)), and how Onyx's Android uses the rest isn't documented |
| userdata's last 16 KiB (outside the ext4 file system) | the room Android's encryption footer needs, and Android's to write |
| a new GPT partition | a partition-table change, on a layout that isn't final yet |
| a file on userdata | the bootloader would need a block list to find the block list |

Writing the default slot's tail on every `install` and `cancel` is the cost of this
choice. The writer limits the risk: it writes only those 4096 bytes, at an offset worked
out from the partition's real size (`blockdev --getsize64`), not from `PART_SIZE` alone.
It checks the sha256 of the default image's bytes before and after the write, and the
two must match.

**Format 1** (binary, little-endian, so the bootloader's parser stays small):

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `GLBLKLST` |
| 8 | 4 | `format` = 1 |
| 12 | 4 | `extent_count`, 1 to 248 |
| 16 | 16 | image id, the `glassine.img=` value (16 ASCII hex digits) |
| 32 | 32 | partition name, ASCII, NUL-padded (`userdata`) |
| 64 | 4 | `block_size` in bytes (4096) |
| 68 | 4 | `flags` = 0 (a reader refuses any bit it doesn't know) |
| 72 | 8 | `image_size` in bytes |
| 80 | 32 | sha256 of the image's `image_size` bytes |
| 112 | 12 | zero |
| 124 | 4 | CRC-32 (IEEE, as zlib's `crc32` and UEFI's `CalculateCrc32`) over bytes 0 to `128 + 16 × extent_count`, with this field taken as 0 |
| 128 | 16 each | extents: `first_block` (u64, from the start of the partition, in `block_size` units), `block_count` (u64) |

A record of all zeros is "no record". `extent_count` above 248 doesn't fit, and the
writer refuses it (the image is packed again into a new file). The record is keyed on
the image id, not the release, because a new device tree or initramfs for the same
release is a candidate with its own id ([kernel-artifacts.md](kernel-artifacts.md)).

**The bootloader accepts a record only if** the magic and `format` match, the CRC is
right, `flags` is 0, `block_size` is a power of two from 512 to 65536,
`1 ≤ extent_count ≤ 248`, every extent lies inside the named partition (checked without
overflow), the extents add up to at least `image_size` and less than
`image_size + block_size`, and `image_size` is at most `PART_SIZE - 4096`.

## The one-shot

**Key: a reboot reason of its own,** `BLOCKLIST_REBOOT_REASON` (board key, `blocklist`),
written by the kernel's reboot-mode driver into the PMIC register that already carries
`recovery` (1) and `bootloader` (2)
([Boot chain](https://docs.glassine.org/devices/onyx-noteair/#boot-chain)). Its value is
a new `mode-blocklist` entry in the Note Air's device tree (`linux`). #55 picks the value
from the ones the bootloader doesn't already use. It can't be `recovery`: that reason
boots the recovery partition, which keeps the mainline recovery (decision 0010).

**Why it's entered once:** the bootloader clears the reason after reading it, as it
does for `recovery` today. Any later reset, whether a watchdog bite, a panic
(`panic=5`), a long press or a power loss, finds no reason and boots the default slot.
The bootloader clears the reason **before** it reads the record, so a hang or a reset
inside the block-list path doesn't repeat it either.

**Which role the image boots in:** the default role, as from the default slot (on the
Note Air, `skip_initramfs` is appended as on a normal boot). The initramfs knows a trial
from `glassine.img=` = `candidate_img` (kernel-artifacts.md, "A kernel trial"). Nothing
in the initramfs changes for this hand-off.

**What a failure looks like:**

| What fails | Next boot |
|---|---|
| no reason, or another reason | as today |
| the record is missing or rejected, a block can't be read, the sha256 doesn't match | the default slot, in this same boot |
| the candidate panics | a reset, then the default slot |
| the candidate hangs, with the watchdog armed | the watchdog resets, then the default slot |
| the candidate hangs before anything arms the watchdog | **a long press**, then the default slot (below) |
| the candidate boots but fails its health check, or ends before it | the default slot at the next boot |

In every row, the next boot is the previous kernel, and `state/kernel` marks the
candidate failed (kernel-artifacts.md: the try is taken at the trial, so `tries=0`).
When the bootloader rejected the record, the trial never happened and `tries` is still
1. So `reboot-test` records `requested=<candidate_img>` in `state/kernel`. At the next
boot, `glassine-bootimg-promote` finds `requested` set and a boot that isn't the
candidate's while `tries=1`, marks the candidate failed with reason `handoff`, and
clears `requested`. That key is added to kernel-artifacts.md's table (no format bump).

**Open: a hang before the watchdog is armed.** The Note Air page says a hang with no
armed watchdog needs a long press
([Suspend and debugging](https://docs.glassine.org/devices/onyx-noteair/#suspend-and-debugging)).
Today the kernel arms it when its watchdog driver probes. A candidate that dies before
that (a bad device tree, an early panic with no console) waits for a long press, and
hub#57's "without manual steps" fails for it. #55 must answer whether the boot chain
leaves the SoC watchdog armed into Linux, or whether the bootloader can arm it through
a UEFI protocol, never by touching a raw register
([Bricks](https://docs.glassine.org/devices/onyx-noteair/#bricks)). If neither is
possible, the person decides whether a long press for this case is acceptable.

## What the bootloader has to do (for #55)

1. Read the reason as today. On `BLOCKLIST_REBOOT_REASON`, clear it first.
2. Read the last 4096 bytes of the default slot and check the record (above).
3. Allocate a buffer through UEFI (no fixed address, nothing the UEFI memory map
   doesn't cover). Read the extents of the named partition with the block I/O it
   already uses for boot partitions, and compare the sha256.
4. Boot the buffer exactly as an image read from the default slot: the same header
   checks, the same device-tree selection, the same command-line additions.
5. On any failure in 2 to 4, boot the default slot as if there were no reason. No retry
   and no write to storage.
6. On every boot, append `glassine.handoff=blocklist1` to the command line (the formats
   it reads), and on a rejected record `glassine.handoff_err=<step>`, so Linux can log
   why. `glassine-bootimg install` refuses `HANDOFF=blocklist` unless the running
   bootloader announces format 1. Linux on an old bootloader can't hand anything off,
   and says so.
7. A bootloader without this change must treat the new reason as no reason (#55
   checks this), so a reboot reason sent to it boots the default slot.

## The commands with `HANDOFF=blocklist`

Generic behaviour (the checks, `state/kernel`, defer, exit codes) is as
kernel-artifacts.md says. What is specific:

**`install <release>`:**

1. The checks of kernel-artifacts.md. Also: `glassine.handoff=` on `/proc/cmdline` lists
   `blocklist1`, userdata passes the file-system checks above, and the default slot is at
   least `PART_SIZE` (its real size).
2. Clear the record: write 4096 zero bytes and read them back. A failed clear stops the
   install. A record left in place is harmless without the reason.
3. Pack the image (`lib/glassine-bootimg-pack`) into
   `<prefix>/kernel/.<id>.img.new` on userdata, `fsync`, rename to `<id>.img`, `fsync`
   the directory, `chattr +i`, `sync`. An existing `<id>.img` with the right sha256 is
   kept as it is.
4. Map it with `FIEMAP` and check the extents (above).
5. Read the image back through the raw partition at those extents with `O_DIRECT` (no
   cache), as the bootloader will, and compare the sha256. A mismatch: remove the file,
   say so, exit 1.
6. Write the record (`O_DIRECT`, `O_SYNC`), read it back, and check the default image's
   bytes are unchanged.
7. `state/kernel`: `candidate`, `candidate_img`, `tries=1` (`gs_write` under
   `state/.lock`).

The record goes before `state/kernel`, so a cut install leaves at worst a record and no
candidate. That's harmless, and the next `install` or `cancel` clears it.

**`reboot-test`:** the record names `candidate_img`, and steps 4 and 5 pass again (this
catches a moved or changed file). Then `requested=<candidate_img>` goes into
`state/kernel`, followed by the orderly reboot with `BLOCKLIST_REBOOT_REASON`
(`glassine-reboot-clean`). If a check fails, it refuses and names `install`.

**accept** (`glassine-bootimg-promote`, in the trial, after the health check):

1. The battery rule of the shutdown switch (`SWITCH_MIN_CAPACITY`, or the charger).
   Below it, accept waits while the trial runs and `status` says why. A trial that ends
   first isn't accepted (`reason` says so), and `retry` can run it again.
2. Write the image (from `<id>.img`) to the default slot with the existing
   `write_dev` (read-back, one retry). The image ends before the record area.
3. `state/kernel`: `current` ← the candidate, the old one to `previous`; the candidate
   keys cleared.
4. Clear the record.

So a cold boot without the reason runs the accepted kernel (hub#54's last point): yes,
accept writes the default slot. Without that, the accepted kernel would run only on
trial boots.

**`cancel`:** clear the record (with the default-image check), then the candidate keys
and `requested`. The default image isn't touched, and the file is kept for a later
`install`. From the recovery (`reset --now`, `rollback`), a failed record clear is
logged and doesn't stop the escape route: without the reason, the record is never read.

**`rollback`:** as kernel-artifacts.md says. The previous image is written to the
default slot as in accept, steps 1 and 2. If `<previous_img>.img` is gone (userdata
formatted), it's packed again from `modules/<previous>/` and `boot/` on the system
partition, which the image file only caches.

**Files kept:** the images of `current_img`, `previous_img` and `candidate_img`. Others
are removed (`chattr -i`, then `rm`), never while a record names them.

## Each step that touches the bootloader or a partition

The failure mode and escape route of each step, for the irreversible-operation gate of
#55. The gate's own text isn't in the organization yet
([hub#58](https://github.com/GlassineOS/hub/issues/58)), so this table may need recasting
in its form.

| Step | Writes | If it fails or is cut off | Escape |
|---|---|---|---|
| flash the changed bootloader (#55, once) | `abl` | the bootloader doesn't start: XBL drops to EDL if the signature is rejected; if it starts and crashes, only the drained-battery EDL route is left ([How to undo](https://docs.glassine.org/guides/qualcomm-boot-and-edl/#how-to-undo)) | write the last working `abl` over EDL; the cable tried on this device and the battery charged before the first flash |
| install: the image file | userdata, through ext4 | an incomplete or missing file; no record names it yet | none needed: the next install writes it again |
| install, cancel, accept: the record | the default slot's last 4 KiB | a torn record: its CRC fails, and the default slot boots | none needed. A write that changed the default image's bytes (a bug) is caught by the before-and-after check, and the image is written back from `<current_img>.img` before the command exits |
| reboot-test: the reason | the PMIC register | the old bootloader ignores it (#55 checks this) | none needed |
| the bootloader's block-list read | nothing | the default slot boots | none needed |
| the trial kernel | nothing before its own health check | a reset, then the default slot; a long press for an early hang (open, above) | a long press |
| accept, rollback: the default image | the default slot | **a cut write leaves no bootable default image.** The record still names the accepted image, but nothing can set the reason without a running Linux | cover closed at power-on → fastboot → `fastboot oem reboot-recovery` → the recovery writes `<current_img>.img` to the default slot (`glassine-bootimg repair`, new). Last resort: write the default slot over EDL from a host |

#55 also says what the bootloader does with a default image that fails its own checks.
If it can boot a valid record then, without the reason, the last row would recover by
itself. That is optional and isn't required for a go.

## Board keys

| Key | Note Air | Meaning |
|---|---|---|
| `HANDOFF` | `blocklist` | set only once this page, the writer (#56) and the bootloader side (#55) are all done |
| `BLOCKLIST_RECORD_PART` | `boot_b` | the partition whose last 4096 bytes hold the record: the default slot |
| `BLOCKLIST_REBOOT_REASON` | `blocklist` | the reason that requests the one-shot |

The image partition is `USERDATA_PART`, and the directory is `<USERDATA_PREFIX>/kernel`.
No device constant goes into the tools (principle VI).

## When this is implemented

What changes with it:

- In this repository:
  - [kernel-artifacts.md](kernel-artifacts.md): the hand-off table links here; the
    `requested` key; `state/bootimg/<id>.img` isn't used with `blocklist`.
  - [boot.md](boot.md) and `conf/board.conf.example`: the board keys above.
  - `sbin/glassine-bootimg`: `install`, `reboot-test`, `cancel`, `rollback`, `repair` for
    `blocklist`.
  - `lib/glassine-blocklist` (new): the record's encoding and decoding, the `FIEMAP`
    mapping and checks, and the raw read-back. The host tests use the same reader.
  - `openrc/glassine-bootimg-promote`: the `requested` check, and accept's battery rule.
  - `lib/glassine-bootimg-pack`: the `PART_SIZE - 4096` limit for these boards.
  - `test/bootimg`: host tests for `install`, `accept`, `cancel`, `rollback` and
    `reboot-test`. They cover a file whose blocks changed after `install`, a torn
    record, a cut accept write, an `extent_count` too large, and unwritten extents.
  - [testing.md](testing.md) and README.md (Kernel updates).
- Elsewhere:
  - the bootloader (its home: hub#58), with the steps above;
  - `linux`: `mode-blocklist` in the Note Air's reboot-mode node;
  - the Note Air's device package: `HANDOFF=blocklist` and the keys above, last;
  - docs.glassine.org (Boot flow, the Note Air page), once hub#57 has passed on the
    device.

## Not covered here

- The bootloader patch itself (#55), the writer's code (#56) and the device test (#57).
- Other devices: a board with a spare slot uses `bootpart-test`.
