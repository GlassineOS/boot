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
writes the file's storage blocks and its checksum into a small **record** near the end
of the default slot. `glassine-bootimg reboot-test` reboots with a reboot reason of its
own. On that one boot the bootloader reads the record, reads the blocks, checks the
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
  to. Online defrag (`EXT4_IOC_MOVE_EXT`) needs the file open for reading and writing
  (`fs/ext4/ioctl.c`, `linux@d476aaa`), and the VFS refuses to open an immutable file
  for writing. `resize2fs` and `e2fsck` are caught below.
- btrfs maps a file through its chunk tree, and a balance relocates chunks, no-COW
  files included. Nothing in btrfs guarantees that a file keeps its physical blocks.
- There's a precedent: the hibernate image is already read from userdata's raw blocks
  ([boot.md](boot.md#hibernation)).

The file is allocated (`fallocate`, which keeps it in few extents) and then written in
full. An extent left unwritten reads as zeros through ext4 but as old data on the raw
device, as with the swap file (`sbin/glassine-hibernate`). Then it is made immutable.
Its blocks are listed with `FIEMAP`, and the writer refuses any extent flagged
`UNWRITTEN`, `UNKNOWN`, `DELALLOC`, `ENCODED`, `DATA_ENCRYPTED`, `NOT_ALIGNED`,
`DATA_INLINE`, `DATA_TAIL` or `SHARED`. It also refuses a file system whose block size
isn't 4096, a userdata mounted with `data=journal` (data could still be in the journal),
a directory with encryption set, and more extents than the record holds. It doesn't
retry that last case: the same bytes would end up as fragmented.

**What can still break the file, and what happens then.** Every one of these ends in a
checksum mismatch and a boot of the default slot. None of them can make the bootloader
read outside userdata or boot a damaged image:

| Event | Effect |
|---|---|
| Android's Format Data, or a `mke2fs` of userdata | the file is gone; its blocks hold other data |
| Android full-disk encryption turned on | the blocks become ciphertext. On this device that also erases or locks `/home` (the Note Air page on docs.glassine.org, "Storage, slots and data"), so it isn't a supported state anyway |
| `resize2fs` shrinking userdata (from Android, a recovery or a host) | blocks may move |
| `e2fsck` cloning blocks that two files claim (the initramfs runs `e2fsck -p` on every boot, and Android runs its own) | that file's blocks change |
| someone with root runs `chattr -i` and rewrites or deletes it | anything |

`glassine-bootimg reboot-test` reads the image back through the raw device (below)
before it sets the reboot reason, so all of these are caught before the reboot, as long
as they happen before `reboot-test`. After it, the shutdown still writes userdata, but
not this file: its blocks are allocated and the file is immutable. On Android, the
immutable flag also keeps apps and the media scanner from deleting it.

Android's encryption (hub#54's question): this device's Android uses full-disk
encryption, which is turned off (2026-06-08,
[Dead ends](https://docs.glassine.org/dead-ends/#decrypting-stock-androids-data-from-recovery-or-another-os)).
If it were turned on, the case is the table's second row: the bootloader reads
ciphertext, the checksum fails, and the default slot boots.

## The record

**Where:** 4096 bytes at offset `size - 65536` of the default slot, where `size` is the
partition's real size (`blockdev --getsize64`) and the default slot is board key
`BLOCKLIST_RECORD_PART` (on the Note Air, the 64 MiB default slot). The last 64 KiB stay
untouched: Android verified boot keeps its footer at the very end of a partition, and
the record must not be confused with it or overwrite it. The bootloader already opens
this partition on every boot. A header v0 image ends where its sizes say it does, so
nothing should read past the image; #55 checks that this bootloader doesn't. Every
image these boards boot ends before the record: the packer's limit is
`PART_SIZE - 65536`.

Alternatives considered, and why not:

| Place | Why not |
|---|---|
| `misc` beyond Android's 64 KiB | Android and the bootloader keep the boot control block there (the stale recovery request in the Note Air page on docs.glassine.org, "Undoing each step"), and how the vendor's Android uses the rest isn't documented |
| userdata's last 16 KiB (outside the ext4 file system) | the room Android's encryption footer needs, and Android's to write |
| a new GPT partition | a partition-table change, on a layout that isn't final yet |
| a file on userdata | the bootloader would need a block list to find the block list |

Writing inside the default slot on every `install` and `cancel` is the cost of this
choice. The writer limits the risk:
- It writes only those 4096 bytes, at that offset.
- Before the first write, it parses the default slot's header and works out where the
  default image ends (header, then kernel and ramdisk, each padded to the page size).
  If the image reaches the record area, it refuses.
- It keeps a copy of the default image's bytes in RAM (`/run`), compares their sha256
  after the write, and writes the copy back on a mismatch.
- It never reads or writes the whole partition. Today's promote saves the whole default
  slot as `prev.img` (`sbin/glassine-bootimg`, `head -c $bsz`). With a record inside the
  slot, writing that copy back would bring back a stale record, so with this hand-off
  only the image's bytes are saved.

**Format 1** (binary, little-endian, so the bootloader's parser stays small):

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `GLBLKLST` |
| 8 | 4 | `format` = 1 |
| 12 | 4 | `extent_count`, 1 to 248 |
| 16 | 16 | image id, the `glassine.img=` value (16 ASCII hex digits) |
| 32 | 32 | partition name, ASCII, NUL-padded (`userdata`) |
| 64 | 8 | `image_size` in bytes, a multiple of 4096 (packed images always are) |
| 72 | 32 | sha256 of the image |
| 104 | 24 | zero |
| 128 | 16 each | extents: `first_block` (u64), `block_count` (u64), in 4096-byte blocks from the start of the partition |

Block size and page size are fixed at 4096 in format 1, and Linux refuses anything
else. The record has no checksum of its own. A torn or wrong record can only make the
bootloader read blocks inside the named partition, and the image's sha256 rejects
those. A record of all zeros is "no record". It is keyed on the image id, not the
release, because a new device tree or initramfs for the same release is a candidate
with its own id ([kernel-artifacts.md](kernel-artifacts.md)).

**The bootloader accepts a record only if** the magic and `format` match, bytes 104 to
127 are zero, `1 ≤ extent_count ≤ 248`, every extent lies inside the named partition
(checked without overflow), the extents add up to exactly `image_size / 4096` blocks,
and `image_size` is at most `PART_SIZE - 65536`.

## The one-shot

**Key: a reboot reason of its own,** `BLOCKLIST_REBOOT_REASON` (board key, `blocklist`),
written by the kernel's reboot-mode driver into the PMIC register that already carries
`recovery` (1) and `bootloader` (2)
(the Note Air page on docs.glassine.org, "Boot chain"). Its value is
a new `mode-blocklist` entry in the Note Air's device tree (`linux`). #55 picks the value
from the ones the bootloader doesn't already use. It can't be `recovery`: that reason
boots the recovery partition, which keeps the mainline recovery (decision 0010).

**Why it's entered once:** the bootloader clears the reason after reading it, as it
does for `recovery` today. Any later reset, whether a watchdog bite, a panic
(`panic=5`), a long press or a power loss, finds no reason and boots the default slot.
The bootloader clears the register **before** it reads the record, and on every boot
whatever the value is. So a hang inside the block-list path doesn't repeat it, and a
value an older bootloader left in place can't fire later. `reboot-test` refuses while a
trial is running, so the reason can't be set again from inside one.

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
candidate failed. A trial that reached the initramfs leaves `tries=0`. One that didn't
leaves `tries=1`: either the bootloader rejected the record, or the kernel died before
the initramfs. That's what kernel-artifacts.md's new generic `requested` key is for.
`reboot-test` sets it. At the next boot, `glassine-bootimg-promote` finds it set, with
`tries=1` and a boot that isn't the candidate's. It runs the record and read-back
checks again, and marks the candidate failed with reason `handoff` if they fail, or
`no-boot` if they pass (the kernel died early). Then it clears `requested`. If the
bootloader passes `glassine.handoff_err=` (optional, below), that decides it instead.

**Open: a hang before the watchdog is armed.** The Note Air page says a hang with no
armed watchdog needs a long press
(the Note Air page on docs.glassine.org, "Suspend and debugging").
Today the kernel arms it when its watchdog driver probes. A candidate that dies before
that (a bad device tree, an early panic with no console) waits for a long press, and
hub#57's "without manual steps" fails for it. #55 must answer whether the boot chain
leaves the SoC watchdog armed into Linux, or whether the bootloader can arm it through
a UEFI protocol, never by touching a raw register
(the Note Air page on docs.glassine.org, "Bricks"). If neither is
possible, the person decides whether a long press for this case is acceptable.

## What the bootloader has to do (for #55)

The build has about 16 bytes free (hub#53), so this is the smallest set that's safe.

**Required:**

1. On every boot, read the reason and clear the register, whatever its value. On
   `BLOCKLIST_REBOOT_REASON`, go on to 2; otherwise boot as today.
2. Read the record from the boot partition of the slot it would boot now (the active
   slot, not a partition by name, so a slot switch can't make it read the other slot's
   record) and check it (above).
3. Allocate a buffer through UEFI (no fixed address, nothing the UEFI memory map
   doesn't cover). Read the extents of the named partition with the block I/O it
   already uses for boot partitions, and compare the sha256.
4. Boot the buffer exactly as an image read from the default slot: the same header
   checks, the same device-tree selection, the same command-line additions.
5. On any failure in 2 to 4, boot the default slot as if there were no reason. No retry
   and no write to storage.

**Optional,** only if there's room: append `glassine.handoff_err=<step>` on a rejected
record, so Linux can tell a rejected record from an early crash without guessing.

Also for #55 to check, without building anything: a bootloader without this change
treats an unknown reason as no reason, and nothing in this bootloader reads the default
slot past the image (an AVB footer, for example).

**How Linux knows the bootloader can do it:** `install` refuses `HANDOFF=blocklist`
unless the sha256 of the `abl` partition (read-only) is one of the board key
`BLOCKLIST_ABL_SHA256` (space-separated, the builds known to read format 1). This
costs the bootloader nothing. An old bootloader can't be handed anything, and
`install` says so.

## The commands with `HANDOFF=blocklist`

Generic behaviour (the checks, `state/kernel`, defer, exit codes) is as
kernel-artifacts.md says. What is specific:

**`install <release>`:**

1. The checks of kernel-artifacts.md, plus:
   - the `abl` check above;
   - userdata passes the file-system checks above;
   - the default slot is at least `PART_SIZE`;
   - the default image ends before the record area.
2. Clear the record: write 4096 zero bytes and read them back, with the
   default-image check. A failed clear stops the install.
3. Pack the image (`lib/glassine-bootimg-pack`) into `<prefix>/kernel/.<id>.img.new` on
   userdata (allocated, then written in full). Then `fsync`, rename it to `<id>.img`,
   `fsync` the directory, `chattr +i`, `sync`. An existing `<id>.img` with the right
   sha256 is kept as it is.
4. Map it with `FIEMAP` and check the extents (above).
5. Read the image back through the raw partition at those extents with `O_DIRECT`, past
   the block device's cache, as the bootloader will, and compare the sha256. On a
   mismatch, remove the file, say so, and exit 1.
6. Write the record (`O_DIRECT`, `O_SYNC`), read it back, and check the default image's
   bytes are unchanged.
7. `state/kernel`: `candidate`, `candidate_img`, `tries=1` (`gs_write` under
   `state/.lock`).

The record goes before `state/kernel`, so a cut install leaves at worst a record and no
candidate. That's harmless, and the next `install` or `cancel` clears it.

**`reboot-test`:**
- It refuses during a trial, and below the shutdown switch's battery rule
  (`SWITCH_MIN_CAPACITY`, or the charger), so the trial, and an accept inside it,
  start with enough battery.
- The record must name `candidate_img`, and steps 4 and 5 must pass again. This catches
  a moved or changed file. If a check fails, it refuses and names `install`.
- Then `requested=<candidate_img>` goes into `state/kernel`, followed by the orderly
  reboot with `BLOCKLIST_REBOOT_REASON` (`glassine-reboot-clean`).

**accept** (`glassine-bootimg-promote`, in the trial, after the health check):

1. `state/kernel`: `accepting=<candidate_img>`.
2. Write the image (from `<id>.img`) to the default slot with `write_dev`: read-back,
   one retry. The image ends before the record area.
3. `state/kernel`: `current` ← the candidate, the old one to `previous`; the candidate
   keys, `requested` and `accepting` cleared.
4. Clear the record.

So a cold boot without the reason runs the accepted kernel (hub#54's last point): yes,
accept writes the default slot. Without that, the accepted kernel would run only on
trial boots.

If accept is cut between 2 and 3, the next boot runs the candidate from the default
slot, with `tries=0`. If it is cut during 2, nothing in the default slot is bootable
(see the table below). So the generic trial detection changes in kernel-artifacts.md:
a boot whose `glassine.img=` equals `accepting` finishes the accept (step 3 onwards)
instead of failing the candidate. That boot already passed the health check in the
trial.

**fail** (promote, when the candidate failed): clear the record, then the generic
failure. The file is kept for `retry`.

**`retry`:** for a failed candidate whose file is still there, steps 4 to 7 of
`install`: the extents and read-back again, the record again, then the candidate keys.

**`cancel`:** clear the record (with the default-image check), then the candidate keys
and `requested`. The default image isn't touched, and the file is kept for a later
`install`. From the recovery (`reset --now`, `rollback`), a failed record clear is
logged and doesn't stop the escape route: without the reason, the record is never read.

**`rollback`:** as kernel-artifacts.md says. It refuses below the battery rule. The
previous image is written to the default slot as in accept step 2, after the same
`accepting` guard. If `<previous_img>.img` is gone (userdata formatted), it's packed
again from `modules/<previous>/` and `boot/` on the system partition. The image file
only caches those.

**`repair`** (new, mostly for the recovery): writes a known-good image to the default
slot. It tries these in order: the `accepting` image (it passed the health check), the
`current_img` file, then a fresh pack of `current` from the system partition. Each
source is checked against its manifest's sha256 first.

**Files kept:** the images of `current_img`, `previous_img`, `candidate_img` and
`accepting`. Others are removed (`chattr -i`, then `rm`), never while a record names
them.

## Each step that touches the bootloader or a partition

The failure mode and escape route of each step, for the irreversible-operation gate of
#55. The gate's own text isn't in the organization yet
([hub#58](https://github.com/GlassineOS/hub/issues/58)), so this table may need recasting
in its form.

| Step | Writes | If it fails or is cut off | Escape |
|---|---|---|---|
| flash the changed bootloader (#55, once) | `abl` | the bootloader doesn't start: XBL drops to EDL if the signature is rejected; if it starts and crashes, only the drained-battery EDL route is left ([How to undo](https://docs.glassine.org/guides/qualcomm-boot-and-edl/#how-to-undo)) | write the last working `abl` over EDL; the cable tried on this device and the battery charged before the first flash |
| install, retry: the image file | userdata, through ext4 | an incomplete or missing file; no record names it yet | none needed: the next install writes it again |
| install, cancel, accept, fail, retry: the record | 4 KiB of the default slot, 64 KiB before its end | a torn record: the image's sha256 rejects it, and the default slot boots | none needed. A write that changed the default image's bytes (a bug) is caught by the before-and-after check, and the RAM copy is written back before the command exits |
| reboot-test: the reason | the PMIC register | an old bootloader ignores it (#55 checks this) | none needed |
| the bootloader's block-list read | nothing | the default slot boots | none needed |
| the trial kernel | nothing before its own health check | a reset, then the default slot; a long press for an early hang (open, above) | a long press |
| accept, rollback, repair: the default image | the default slot | **a cut write leaves no bootable default image.** The record still names the accepted image, but nothing can set the reason without a running Linux | cover closed at power-on → fastboot → `fastboot oem reboot-recovery` → the recovery runs `glassine-bootimg repair`. Last resort: write the default slot over EDL from a host |

The recovery has to carry what `repair` needs: `glassine-bootimg`, and for a fresh pack,
`lib/glassine-bootimg-pack` with its Python. Until it does, `repair` from the recovery
works only from a file that's still on userdata.

#55 also says what the bootloader does with a default image that fails its own checks.
If it could boot a valid record then, without the reason, the last row would recover by
itself. That is optional and isn't required for a go.

## Board keys

| Key | Note Air | Meaning |
|---|---|---|
| `HANDOFF` | `blocklist` | set only once this page, the writer (#56) and the bootloader side (#55) are all done |
| `BLOCKLIST_RECORD_PART` | its default slot | the default slot, which holds the record |
| `BLOCKLIST_REBOOT_REASON` | `blocklist` | the reason that requests the one-shot |
| `BLOCKLIST_ABL_SHA256` | the sha256 of the bootloader build(s) from #55 | the builds known to read format 1 |

The image partition is `USERDATA_PART`, and the directory is `<USERDATA_PREFIX>/kernel`.
No device constant goes into the tools (principle VI).

## When this is implemented

What changes with it:

- In this repository:
  - [kernel-artifacts.md](kernel-artifacts.md): the hand-off table links here; the
    generic `requested` and `accepting` keys, and the trial detection for `accepting`;
    `state/bootimg/<id>.img` isn't used with `blocklist`.
  - [boot.md](boot.md) and `conf/board.conf.example`: the board keys above.
  - `sbin/glassine-bootimg`: `install`, `reboot-test`, `retry`, `cancel`, `rollback`,
    `repair` for `blocklist`; no whole-slot copies.
  - `lib/glassine-blocklist` (new): the record's encoding and decoding, the `FIEMAP`
    mapping and checks, the default-image length from its header, and the raw
    read-back. The host tests and promote's `handoff` or `no-boot` verdict use the same
    reader.
  - `openrc/glassine-bootimg-promote`: accept with `accepting`, fail clears the record,
    the `requested` check.
  - `lib/glassine-bootimg-pack`: the `PART_SIZE - 65536` limit for these boards.
  - `test/bootimg`: host tests for `install`, `accept`, `cancel`, `rollback`, `retry`,
    `repair` and `reboot-test`. They cover:
    - a file whose blocks changed after `install`;
    - a torn record;
    - a default image that reaches the record area;
    - a cut accept between its steps;
    - too many extents;
    - unwritten extents;
    - `reboot-test` during a trial.
  - [testing.md](testing.md) and README.md (Kernel updates).
- Elsewhere:
  - the bootloader (its home: hub#58), with the steps above;
  - `linux`: `mode-blocklist` in the Note Air's reboot-mode node;
  - the recovery image: `glassine-bootimg repair` and what it needs;
  - the Note Air's device package: `HANDOFF=blocklist` and the keys above, last;
  - docs.glassine.org (Boot flow, the Note Air page), once hub#57 has passed on the
    device.

## Not covered here

- The bootloader patch itself (#55), the writer's code (#56) and the device test (#57).
- Other devices: a board with a spare slot uses `bootpart-test`.
