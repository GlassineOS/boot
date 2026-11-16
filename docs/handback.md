# The loader under a parent bootloader (hand-back)

Status: **agreed design; nothing has run on a device.** This page is the contract between
the GlassineOS loader and a **parent bootloader**: a bootloader that a machine's firmware
starts and that can't be replaced by the loader, but can start a UEFI program and act on
its answer. What both sides do and why is [specs/012](../specs/012-device-boot-partition/spec.md);
this page gives the bytes. Changes go through this repository first.

The first parent is the Boox Note Air's ABL
([GlassineOS/abl](https://github.com/GlassineOS/abl)), which starts the loader on the
GlassineOS slot only. Nothing on this page depends on that device.

In short: the parent reads the loader from the boot partition, starts it from memory with
one load option, and gets an answer back through UEFI exit data. The loader keeps its
record on the same partition, decides as 010 and [boot-partition.md](boot-partition.md)
say, and starts no kernel. The parent boots what the answer names, and when anything goes
wrong it boots what it boots today: its **baseline**.

## The boot partition under a parent

The partition is the machine's boot partition, `glassine-boot`, in either form of
[boot-partition.md](boot-partition.md#two-forms). How the parent finds it is the
parent's; a parent that finds it by GPT name uses `glassine-boot`. Where each item is:

| Item | FAT form | Raw form (region) |
|---|---|---|
| the loader record | `\glassine\loader.a`, `\glassine\loader.b` | `record` |
| the probe report | `\glassine\probe.txt` | `probe` |
| the loader | `\EFI\glassine\loader.efi` | `loader`: header, then image ([below](#the-loader-region)) |
| the splash store | `\glassine\splash\` | `splash-default`, `splash`, `override` |

A parent reads only the loader. A parent that has no FAT driver reads only the raw form,
and on a partition in the FAT form it boots its baseline; a machine whose parent is such
a one gets the raw form from the installer.

### The loader record under a parent

Each slot holds the same 16384 bytes a slot file holds on a PC
([boot-partition.md](boot-partition.md#slots)): the record, then newlines up to 16384
bytes. The rules for valid slots, the record in use, writing the other slot and one valid
slot are that page's, word for word. In the raw form:

- A slot that is not a valid record (all zeros, an older image's bytes, a cut write) is
  not valid. A partition never written, or one whose region table isn't valid, holds no
  loader record.
- A write is one write of the 16384 bytes of the slot not in use, then a flush of the
  block device, then a read of the slot back. The write counts only when the bytes read
  back are the bytes written. A block size that doesn't divide 4096, a medium that is
  read-only or a failed step is a loader that can't write (010 FR-009: it counts nothing
  and takes no request).
- A power cut at any byte of a write leaves the slot in use as it was, and the other slot
  either whole or not valid, as on FAT.

The keys are those of [boot-partition.md](boot-partition.md#keys), with these
differences:

| Key | Under a parent |
|---|---|
| `default`, `default_rec` | empty: the default set is the parent's baseline. When `default` names a set, the loader answers it (below) and a parent that can't boot it boots its baseline |
| `previous`, `previous_rec` | the previous set, only when the parent can boot it (on the Note Air, a block-list set); else both empty, and the limit leads straight to the recovery (010 FR-011) |
| `trial`, `trial_rec` | the trial set, as on a PC |
| `recovery`, `recovery_rec` | not used: the recovery is the parent's own |
| `probe` | `1`: write the probe report at this start; anything else, or empty: don't. Set and cleared by the running system; the loader never changes it |
| `deploys`, `deploy1` … | kept as read; a headless loader offers no list |

The other keys (`format`, `seq`, `request`, `unmarked`, `started`, `started_why`) are
the same, with the same writers.

### The splash store under a parent

A loader that runs headless (below) reads and writes nothing of the splash store: the
images and the override stay as they are, for the stage of the machine that draws
(named by the machine's own spec). Where no stage draws, the running system removes an
override at its start (011 FR-015).

## The loader region

In the raw form, the region `loader` holds a 4096-byte header and, directly after it, the
loader image (`loader.efi`, a PE32+ UEFI application for the parent's processor).
Numbers are little endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | the bytes `GLLOADER` |
| 8 | 4 | format: 1 |
| 12 | 4 | flags: 0 |
| 16 | 8 | the image's size in bytes, 1 to 3141632 (3 MiB less 4096), and at most the region's size less 4096 |
| 24 | 4 | CRC-32 of the image |
| 28 | 4 | CRC-32 of bytes 0 to 27 of the header |
| 32 | 4064 | zero; a reader ignores them |

CRC-32 is the one of zlib and Ethernet (the UEFI boot service `CalculateCrc32` gives the
same value). The check is against a cut or partial write, not against an attacker.

**Writing a new loader:** as any region ([boot-partition.md](boot-partition.md#the-regions)):
the header zeroed first, then the image, then the header. A cut leaves no valid header,
or the old one: the parent boots its baseline until the next write, or starts the old
loader.

## Starting the loader (the parent's side)

1. Find the loader. **Raw form:** read the region table (the primary, else the backup;
   [boot-partition.md](boot-partition.md#the-region-table)), take the region `loader`,
   and read its header. The header is accepted only when the magic, the format and the
   flags match, the size is within its limits and inside the region, and the header's
   CRC matches. Read the image into memory it allocated from the firmware and compare its
   CRC-32. **FAT form:** read `\EFI\glassine\loader.efi` whole, at most 3 MiB less
   4096 bytes, into memory it allocated.
2. `LoadImage` from that memory, with no device path (`BootPolicy` false). If
   `LoadImage` returns a handle with an error (`EFI_SECURITY_VIOLATION`), unload it.
3. In the child's `EFI_LOADED_IMAGE_PROTOCOL`: set `DeviceHandle` to the boot
   partition's handle (the one with its `EFI_BLOCK_IO_PROTOCOL`) and `LoadOptions` to
   the UCS-2 text `glassine.handback=1`, with its terminating zero counted in
   `LoadOptionsSize`.
4. If the parent can, arm the firmware's watchdog (`SetWatchdogTimer`) for 30 seconds
   before `StartImage`, and disarm it when `StartImage` returns.
5. `StartImage`, with both exit-data arguments. Read the answer (below), then free the
   exit data with `FreePool`.

Any failure on the way is the baseline: no table, no `loader` region, a header or image
that fails its check, a file that is missing or too large.

**Load options.** Words separated by single spaces. `glassine.handback=1` is required and
puts the loader in hand-back mode; without it the loader runs as on a PC. A loader
ignores words it doesn't know. Defined now:

| Word | Meaning |
|---|---|
| `glassine.handback=1` | hand-back mode, the record on the partition of `DeviceHandle` |
| `glassine.log=serial` | the loader also writes its log through the firmware's serial I/O protocol. A parent whose serial line nobody reads leaves it out, and the loader then calls no serial protocol |
| `glassine.pick=recovery` | *proposed, not built:* the person asked for the recovery at power-on (on the Note Air, a cover gesture). The loader treats it as the recovery picked in the list (boot-partition.md, 010 FR-032) |

The parent passes no other state. It never writes the boot partition.

## The answer

The loader ends with `Exit` and status `EFI_ABORTED` (it started nothing itself). UEFI
gives exit data only with a status other than `EFI_SUCCESS`, so the parent doesn't look
at the status: an answer is the exit data, or nothing.

The exit data is one buffer from `AllocatePool`:

1. the UCS-2 text `GLASSINE-HANDBACK` and its terminating zero: 36 bytes (the string the
   specification wants at the start of exit data);
2. directly after it, the answer: text, UTF-8, at most 4096 bytes.

`ExitDataSize` counts both. The answer is a record of the same form as the others
(`key=value` lines, each ended by a newline, no carriage return, the first line
`format=1`, a key at most once, unknown keys ignored), except its last line, which is

```
crc32=<CRC-32 of every byte of the answer before this line, 8 lower-case hex digits>
```

(not a sha256, so that a parent needs nothing but the boot services to check it). Nothing
follows that line.

| Key | Value |
|---|---|
| `format` | `1` |
| `boot` | `baseline`: the parent boots what it boots today · `recovery`: the parent's recovery path · `set:<id>`: the kernel set of that id (16 lower-case hex digits) |
| `set_rec` | with `set:`, the `_rec` value the record names for the set (64 hex digits), or empty; the parent may use it to check its source |
| `cmdline_add` | optional: words the parent adds to the kernel's command line at this start, separated from it by one space. Only `glassine.deploy.once=<deployment id>` (010 FR-042) is allowed. A parent that can't add it ignores it: it is a one-shot request, and the ordinary pick is never wrong |
| `why` | informative: `default`, `limit`, `request`, `choice`, `no-record`, `not-written` |

The record in use already carries the loader's own writes for this start (the count,
`started`, `started_why`, a cleared request) when the answer is given.

### What the parent does with it

| Answer | The parent |
|---|---|
| exit data missing, shorter than 36 bytes or longer than 36 + 4096 bytes, or a prefix other than `GLASSINE-HANDBACK` | boots its baseline |
| an answer whose CRC line is missing or wrong, whose first line isn't `format=1`, or whose `boot` is missing, repeated or not one of the three forms | boots its baseline |
| `format` newer than it knows | boots its baseline |
| `boot=baseline` | boots its baseline |
| `boot=recovery` | takes its recovery path, as if its own recovery request were set |
| `boot=set:<id>` | boots the set if it has a source for that id whose own checks pass (on the Note Air, the block-list record of [blocklist.md](blocklist.md) naming that image id); else, and on any failure on the way, its baseline |

A parent checks at least what the table names. It may also refuse an answer that breaks
the record's other rules (a key twice, a line without `=`); it need not check the keys
it doesn't use. The loader never writes such an answer.

The parent's baseline is the floor: no failure of the loader, its partition or its answer
leads to anything but the boot the machine had before the loader existed. A parent never
ends in a hang or in a mode the person didn't ask for because of the loader. A hang
inside the loader itself is the one case the parent can't catch; the watchdog of step 4,
where the parent has one, ends it in a reset, and the parent's own escapes that run before
the loader (on the Note Air, the cover at power-on) still work.

## The probe report

When the record in use has `probe=1`, the loader writes, before it answers, a report of
what the firmware offers it: the file `\glassine\probe.txt` in the FAT form, the region
`probe` in the raw form. It writes nothing else for the probe, and it makes no firmware
call for it beyond listing handles and their protocols, reading the graphics output's
modes (`QueryMode`) and reading the console's mode fields. It never sets a mode, draws,
or touches hardware.

The report is a text record of the same form as the loader record, its last line
`check=<sha256>` over the bytes before it, at most 65536 bytes. In the raw form it is
written as the region's content (boot-partition.md, "Writing a region"); on FAT as a
file, written whole and flushed. A cut write leaves no report or one whose check fails,
which a reader treats as no report.

| Key | Value |
|---|---|
| `format` | `1` |
| `loader` | the loader's version |
| `firmware` | the firmware's vendor and revision (`<vendor> 0x<revision>`), from the system table |
| `uefi` | the system table's revision, `<major>.<minor>` |
| `handles` | the number of handles in the handle database |
| `protocols` | the number of distinct protocol GUIDs on them |
| `proto<n>` | `<guid> <handles> <name>`: one protocol GUID, on how many handles, and its name when the loader knows it (else `-`); in byte order of the GUID text |
| `gops` | the number of handles with the graphics output protocol |
| `gop<n>` | `handle=<index> modes=<max> current=<mode> fb=0x<base> size=<bytes>` |
| `gop<n>.mode<m>` | `<width>x<height> <format> stride=<pixels>`, the format one of `rgb`, `bgr`, `bitmask`, `blt-only` |
| `conin`, `conout`, `stderr` | `handle=<index or none> <guid> …`: the console handles of the system table and their protocols |
| `conout.modes` | `max=<max> current=<mode>` of the text output, when there is one |
| `boot_fs` | `1` when the firmware offers a file system (`EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`) on the boot partition, so the loader uses the FAT form; `0` when not |
| `fs_handles` | the number of handles with a file system, on any device: `0` means the firmware has no file system driver it has used, which decides that the machine needs the raw form |
| `fs<n>` | `handle=<index> part=<GPT partition GUID or -> <partition number or ->`, one per handle with a file system |
| `log<n>` | the loader's own log lines of this start, as far as room is left |

A handle's index is its position in the handle database's list at that start; it is
stable only within one report. Lines that don't fit are left out: `log` lines first, then
`gop<n>.mode<m>` lines past the current mode, then `proto` lines (the `fs` lines are always kept); `truncated=1` says so.

The loader knows these names: the protocols of the UEFI specification it uses or reports
(graphics output, block I/O, disk I/O, device path, loaded image, simple text in and out,
simple file system, serial I/O, partition info, EDID, absolute and simple pointer) and the
protocol GUIDs Qualcomm's public bootloader source declares (`QcomModulePkg.dec` of the
ABL tree: chip and platform info, PMIC version and power-on, the charger, display
utilities, verified boot, reset reason, RNG, SCM, QSEECOM, USB, RAM partitions, erase
block, limits, MDTP).

## What a power cut leaves

| Write | Cut during it | The next start |
|---|---|---|
| The loader counts a start or clears a request | the other slot is not valid | as boot-partition.md says for the same write |
| The running system writes the record | the other slot is not valid | the record as it was |
| The probe report | no report, or a report whose check fails | no report; the start is unchanged |
| A new loader (raw form) | a header zeroed or not valid | the parent's baseline, until the next write |
| A new loader (FAT form) | as a file on FAT (boot-partition.md) | the old loader, or the baseline |
