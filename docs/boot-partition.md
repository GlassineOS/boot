# The boot partition of a UEFI PC

Status: **agreed design; not built in this repository.** Nothing here has run on a real
PC. This page is the contract between the three programs that read or write a PC's boot
partition: the loader, the installer, and the running system's tools (`glassine-bootimg`,
`glassine-deploy`, the boot-success step, the recovery). What they do and why is
[specs/010](../specs/010-uefi-deployments/spec.md) and
[specs/011](../specs/011-boot-splash/spec.md); this page gives the paths and the bytes.
Changes go through this repository first.

The boot partition is `glassine-boot`: one FAT32 file system, volume label `GLASSINE`,
created by the installer and owned whole by GlassineOS. The loader reads only the
partition it was started from.

## Layout

```
\EFI\glassine\loader.efi          the loader (our firmware entry names this path)
\EFI\BOOT\BOOTX64.EFI             the same bytes, at the removable-media path
\glassine\loader.a                the loader record, slot a
\glassine\loader.b                the loader record, slot b
\glassine\sets\<id>\              one kernel set
    vmlinuz                       the kernel image (an EFI stub)
    initrd                        its initramfs, assembled (below)
    set.rec                       its record
\glassine\recovery\<id>\          one recovery image, in the form of a kernel set
    vmlinuz
    initrd                        absent when the image carries its own initramfs
    set.rec
\glassine\splash\default.gspl     the release's splash
\glassine\splash\splash.gspl      the splash the system set
\glassine\splash\override.gspl    the one-time override
```

- Names are written as shown, in lower case apart from the firmware's `EFI` and `BOOT`.
  `<id>` is 16 hex digits (below).
- The file system uses FAT long names (VFAT): a 16-digit id and `default.gspl` don't
  fit a short 8.3 name. Every writer writes long-name entries, and every reader,
  the loader's file-system access included, reads them (UEFI's FAT driver does).
- The partition holds the default set, the previous set when there is one, at most one
  trial set, the recovery image and, during its update, the recovery's replacement.
- A name ending in `.new` is a file being written. No reader uses it.
- Everything under `\glassine\sets\` and `\glassine\recovery\` that neither slot of the
  loader record names, and every `.new` file, is left over from a cut write. A writer
  removes it before it writes (010 FR-028). The loader never removes it.
- Nothing else is on the partition: nothing of the person's, no secret, no copy of the
  deployment state.

## Records

Both records on the boot partition are text: `key=value`, one per line, each line ended
by a newline (0x0A), no carriage return, UTF-8. The first line is `format=1`. Unknown
keys are ignored, a missing key is empty, and a key appears once. A reader refuses a
format newer than it knows. The last line is the check:

```
check=<sha256, 64 hex digits, of every byte of the file before this line>
```

A record whose check line is missing or wrong, or that isn't text of this form, is not
valid, and nothing in it is used.

## The loader record

The loader record says what the loader starts. It is kept twice, in `loader.a` and
`loader.b`, because FAT can't replace a file in one step.

### Slots

- Each slot file is exactly 16384 bytes: the record, then newlines (0x0A) up to that
  size. Its size never changes, so a write allocates and frees nothing on the file
  system.
- `seq` is a decimal number that every write raises by one.
- **Reading.** A slot is valid when the record in it is valid and nothing but newlines
  follows its check line. The record in use is the valid slot with the higher `seq`;
  with equal `seq`, slot a. With no valid slot there is no loader record.
- **Writing.** A writer reads the record in use, changes the keys it owns (below), keeps
  every other key as it read it, unknown ones included, sets `seq` one higher, and
  overwrites the *other* slot: the one that is not valid, or has the lower `seq`. It
  then flushes the file and reads the slot back. The slot in use is never written.
- So a power cut at any byte of a write leaves the slot in use as it was and the other
  slot either not valid or whole: the next start reads the old record or the new one.
- **One valid slot.** When only one slot is valid, a write was cut, and the record in
  use may be the one that write was replacing. The loader then takes no request from it
  (010 FR-008): it starts as if `request` were empty, and its own write puts a record
  without the request in the other slot.
- **Before files are removed.** A writer that is about to remove a set or a recovery
  image first writes the record twice, so that both slots are valid and neither names
  what goes. Only then does it remove the files.

The system's writers hold `state/.lock` on the system partition for the whole of a
write; the loader runs when no system does.

### Keys

| Key | Value | Written by |
|---|---|---|
| `format` | `1` | every writer |
| `seq` | the write's number | every writer |
| `default` | id of the default set | the installer; `glassine-bootimg` (accept, rollback, promote's finishing step); the repair |
| `default_rec` | sha256 of that set's `set.rec` | with `default` |
| `previous`, `previous_rec` | the previous set, or both empty | with `default` |
| `trial`, `trial_rec` | the trial set, or both empty | `glassine-bootimg` (install sets them; accept, cancel and a failed trial clear them) |
| `recovery`, `recovery_rec` | the recovery image in `\glassine\recovery\` | the installer; the recovery's update; the repair |
| `request` | empty, `trial` or `recovery` | set by `glassine-bootimg reboot-test` (`trial`) and by `reboot recovery` (`recovery`); cleared by the loader before it acts on it; cleared by the running system when it finds one the loader left (a loader that can't write) |
| `unmarked` | the count of starts not marked healthy, decimal | the loader (one more, before it starts the default or the previous set); the boot-success step (`0`: the healthy mark); the shutdown step (one less, 010 FR-012); the recovery (`0`, 010 FR-014) |
| `started` | id of the set the loader started last | the loader, in the same write as the count or the cleared request |
| `started_why` | why: `default`, `limit` (the previous set, because the count reached the limit), `choice` (the previous kernel set, picked in the list), `request` (a trial) | the loader, with `started` |
| `deploys` | the number of entries in the deployment list, `0` to `32` | `glassine-deploy`, in the running system and in the recovery; the installer (`0`) |
| `deploy1` … `deploy<n>` | `<deployment id> <state> <label>`, separated by single spaces | with `deploys` |

- **The healthy mark** is the write of `unmarked=0`. The boot-success step makes it on
  every start that reaches the health conditions (010 FR-023), whichever set and
  deployment started.
- **The limit** is 3 in format 1. With no key pressed and no request, the loader starts,
  by the `unmarked` it reads: below 3 the default set; at 3 the previous set
  (`started_why=limit`); above 3, or at 3 with no previous set that checks, the recovery.
  A start of the recovery is not counted and writes nothing, apart from clearing a
  `request=recovery`.
- **A deployment picked in the list** leaves no mark in the record (010 FR-042): the
  set starts as it would have without the pick, with the same count and `started_why`.
- **The shutdown step** takes one off `unmarked`, never below 0, when the system shuts
  down or restarts in an orderly way, the running set is `started`, `started_why` is
  `default`, `limit` or `choice`, no healthy mark was written in this start, the start
  was no bare boot and no health check failed in it.
- **A request** is honoured only from a record read with both slots valid. The loader
  writes the record with `request` empty, and `started` and `started_why=request` for a
  trial, and only after that write is flushed and read back does it start the trial set
  or the recovery. A trial start is not counted.
- **The deployment list** holds the deployments the loader's list offers (010 FR-040):
  the previous one first, then the candidate, the last failed one and the kept ones,
  newest first. `<state>` is `previous`, `candidate`, `failed` or `kept`. `<label>` is
  the base's version and the deployment's date as `glassine-deploy list` prints them,
  in printable ASCII (0x20 to 0x7E), at most 64 bytes. Past 32 entries, the oldest kept
  ones are left out. The current deployment and a staged one are not in the list.
- A record must fit its slot with its check line. A writer whose record would not fit
  refuses and writes nothing.

### What the loader does with it

1. Reads both slots and takes the record in use.
2. Removes the override from the splash store and draws (below).
3. Waits for the recovery key; longer when `unmarked` isn't 0.
4. Picks: the person's choice from the list, else a request, else by the count.
5. With a request: writes the record with `request` empty, before it reads anything of
   the trial set or the recovery, so a set that can't even be read is asked for once.
6. Checks the set (below). A set that fails is not started, and the next choice is
   taken: the default set, then the previous set, then the recovery.
7. Writes the record for the set it starts (the count, `started`, `started_why`), then
   starts it. For a trial this is the write of step 5.

With no loader record, or when the recovery the record names fails its check, the loader
takes the recovery from `\glassine\recovery\` by itself: each directory there whose
`set.rec` is valid and whose files match it is a recovery image, and the loader starts
the first that checks, in descending byte order of the directory names. It never
starts a kernel set from `\glassine\sets\` without a record that names it.

A loader that can't write the partition starts the default set, counts nothing and
takes no request.

## A kernel set

A kernel set is the image of one kernel record
([kernel-artifacts.md](kernel-artifacts.md#kernel-records-trials-and-hand-off)) for the
`uefi` hand-off: a kernel, its initramfs and its command line.

### Files

- **`vmlinuz`**: the kernel image of `modules/<release>/`, byte for byte: an EFI stub.
- **`initrd`**: one file, the concatenation of these archives in this order, each
  starting at an offset that is a multiple of 4 (zero bytes between them):
  1. the CPU microcode archives of `modules/<release>/microcode/` (`*-ucode.img`), each
     a file of its own, in byte order of their file names without the directory
     (`amd-ucode.img` before `intel-ucode.img`), uncompressed as they are. Two with one
     name are refused. They come first because the kernel loads microcode only early,
     and only from an uncompressed archive at the start of its initramfs. A kernel tree
     without `microcode/` adds none.
  2. the GlassineOS initramfs, the file from `boot/initramfs/`, unchanged;
  3. the board archive (below), made from the machine's `board.conf`;
  4. the kernel's boot-modules archive ([boot.md](boot.md#boot-modules)), where the
     kernel has one.
- **`set.rec`**: the set's record.

The checksums cover the files as they are on the boot partition: the whole `initrd`,
not its parts. No zero bytes follow the last part.

### The board archive

The board archive is made by whoever assembles the set, so its bytes are fixed here:
every builder gets the same `initrd`, checksum and id from the same `board.conf`. It
is what `lib/glassine-bootimg-pack` puts behind the initramfs of a boot image.

It is an uncompressed cpio archive in the `newc` form with four entries, in this order:

| Entry | Name | Mode | Data |
|---|---|---|---|
| 1 | `etc` | `000041ED` (a directory, 0755) | none |
| 2 | `etc/glassine-boot` | `000041ED` | none |
| 3 | `etc/glassine-boot/board.conf` | `000081A4` (a file, 0644) | the bytes of `board.conf`, unchanged |
| 4 | `TRAILER!!!` | `00000000` | none |

Each entry is the six bytes `070701`, then thirteen fields of 8 upper-case hex digits
each, then the name with one zero byte after it, zero bytes up to the next offset in
the archive that is a multiple of 4, the data, and zero bytes again up to a multiple
of 4. The fields, in order:

| Field | Value |
|---|---|
| inode | the entry's number, 1 to 4 (the trailer has 4) |
| mode | as in the table |
| user id, group id | 0, 0 |
| link count | 1, for every entry |
| modification time | 0 |
| file size | the length of the data; 0 without data |
| device major, minor; rdev major, minor | 0, 0, 0, 0 |
| name size | the length of the name with its zero byte |
| checksum | 0 |

Nothing follows the trailer's padding: the archive is not padded to a block size.

`board.conf` is the machine's board configuration: in the booted system
`/etc/glassine-bootimg/board.conf`, in a release the file of the manifest role `board`.
The two are the same file of the same release.

### `set.rec`

| Key | Value |
|---|---|
| `format` | `1` |
| `id` | the set's id |
| `release` | the kernel's release |
| `kernel_sha256`, `kernel_size` | of `vmlinuz`; the size in bytes, decimal |
| `initrd_sha256`, `initrd_size` | of `initrd`; both empty where a recovery image has none |
| `cmdline` | the whole command line the kernel is started with (below) |
| `initramfs` | the identity of the initramfs file in the `initrd` (`<commit12>@<id>`); informative. Empty when the builder doesn't know it (a release that names none, an `initrd` handed over assembled, a recovery image); no reader depends on it |
| `check` | as for every record |

The file names are fixed, so the record names no paths.

### The id

The id of a set is the first 16 hex digits of the sha256 of these three lines, each
ended by a newline: `kernel_sha256`'s value, `initrd_sha256`'s value (an empty line
where there is no `initrd`), and the base command line. It is the value of
`glassine.img=` on the set's command line and the id of its image record. A set's
directory is named by its id, so a set once written never changes.

### The command line

`cmdline` is, separated by single spaces:

1. the base command line: the value of `CMDLINE` in the set's `board.conf`, and nothing
   else. A release names no second command line for a kernel set: where its manifest
   gives the kernel a `cmdline` too, it must be the same text, and a release in which
   the two differ is refused before anything is written;
2. `glassine.system=PARTUUID=<uuid>` and `glassine.userdata=PARTUUID=<uuid>`: the GPT
   unique partition identities of this installation's system partition and userdata, in
   lower case ([boot.md](boot.md#command-line-keys); 010 FR-005);
3. `glassine.img=<id>`.

The base command line is words of printable characters separated by single spaces:
no space at its start or end, no two spaces in a row, no control character. It holds
none of `glassine.system=`, `glassine.userdata=`, `glassine.img=` and
`glassine.deploy.once=`. A base that breaks one of these is refused, never repaired,
since the id is made from its bytes. It may be empty; the command line then starts
with `glassine.system=`. `CMDLINE` is one line of `board.conf`, `CMDLINE="<text>"` or `CMDLINE=<word>`: the
text between one pair of double quotes, or a bare word, with no backslash, `$`,
backtick or further quote in it. Every reader of `board.conf` gets the same value from
that form; a `CMDLINE` in another form is refused for a kernel set.

The whole command line is at most 1920 bytes, so that the one key the loader may add (the one-shot
deployment request, `glassine.deploy.once=<deployment id>`, 010 FR-042) fits the
kernel's limit. A set whose command line lacks one of the three keys is not written
and not started.

### How the loader checks and starts a set

1. `set.rec` is read, and its sha256 compared with the `_rec` value the loader record
   names. Then the record must be valid and its `id` the directory's name.
2. `vmlinuz` and `initrd` are read whole into memory. Their sizes and sha256 must be the
   record's.
3. The kernel is started from that memory, with `cmdline` (and the one-shot deployment
   request, when the person picked one) as its load options, and the initramfs is handed
   over from that memory through the Linux initrd media device path (`LoadFile2`). The
   kernel reads nothing from the boot partition, so what was checked is what runs.

### Who assembles a set

- **The installer, at install**, from the release's files. The release's manifest names
  the parts by role: `microcode` and `microcode-<name>` (one role a file), the
  `initramfs`, `board` (the `board.conf`), `boot-modules`. A release may hand the
  `initrd` over assembled instead: its `initramfs` then has the kind
  `kernel-set-initrd`, is written as the `initrd` byte for byte, and the release names
  no `microcode` and no `boot-modules`; one that names them too is refused. `board` is
  named in both cases, since the base command line comes from it; with an assembled
  `initrd` the release answers for that file being the one inside. The installer
  assembles `initrd` in the order above, adds the identities of the partitions it made to the command line, and
  writes the set, both slots of the loader record (the same record, `seq=1`: the set as
  `default`, no previous set, no trial, no request, `unmarked=0`, `deploys=0`), the
  recovery image, the loader at its two paths and the default splash.
- **The running system, when a kernel is installed** (`glassine-bootimg install` with
  `HANDOFF=uefi`). It:
  1. assembles the candidate's `initrd` and keeps it on the system partition as the
     image of the record (`state/bootimg/<id>.img`, with the record's manifest), so the
     boot partition can be made again from the system partition with no tool but a copy;
  2. checks the free space on the boot partition (010 FR-028) and removes what a cut
     write left;
  3. writes the set's directory: each file written, synced and read back against its
     checksum. A directory of that id whose files already match is kept as it is;
  4. writes the loader record with `trial` and `trial_rec`, and leaves `request` alone.

  `reboot-test` writes `request=trial`. Accept makes the trial set the default set and
  the default set the previous one; rollback swaps the default and the previous set;
  cancel and a failed trial clear `trial`. Each is one write of the loader record,
  under 004's rules for the default slot (`writing` is set first). A set no record names
  any more is removed as "Before files are removed" says.
- **The first start** of an installation records the installer's set on the system
  partition: when `state/kernel` has no `current_img`, the default set is checked as the
  loader checks it, its `initrd` is copied to `state/bootimg/<id>.img`, and its record
  becomes the image record of `current_img`, marked `seeded=1`, with `current` its
  release.
- **The repair** (the recovery's, and the installer's from removable media) writes the
  sets `state/kernel` names again, from `modules/<release>/` and `state/bootimg/`, and
  then the loader record. It assembles nothing.

## The recovery image

The recovery image has the form of a kernel set, in `\glassine\recovery\<id>\`, with the
same record, id and checks. What differs:

- **Its `initrd` is the release's file, whole.** Nobody assembles it: no microcode, no
  board archive and no boot modules are added on the way to the boot partition. What
  the recovery needs of them is in the image as the release built it. It may be absent
  (an image with its initramfs built in); `initrd_sha256` and `initrd_size` are then
  empty, and the id's second line is empty.
- **Its base command line is the release's for the recovery** (the `cmdline` of the
  manifest's `recovery` role, empty when it gives none), under the same rule for
  spaces. No `board.conf` takes part.
- **Its command line** is that base, the two identities and `glassine.img=<id>`, as
  for a kernel set, so the recovery works on this installation's partitions and its
  record's id is on its command line. No kernel record on the system partition has
  this id: the recovery is no kernel candidate, and `glassine.img=` of a recovery
  never starts a trial.
- **`release`** is the release of the recovery's kernel (its flavor,
  [kernel-artifacts.md](kernel-artifacts.md#kernel-release)); `initramfs` is empty.
- A recovery image and a kernel set never have the same id on one partition; a release
  in which they would is refused.

It is updated like a kernel
set: the new directory is written next to the old one and checked, the loader record is
written with the new `recovery` and `recovery_rec`, and the old directory is removed as
"Before files are removed" says. During the update two recovery images are on the
partition, and each of them starts.

## The splash store

On a PC the splash store of 011 is `\glassine\splash\`:

| File | What | Written by |
|---|---|---|
| `default.gspl` | the default splash of the release | the installer, the repair |
| `splash.gspl` | the splash the system set | the running system |
| `override.gspl` | the one-time override | the running system; removed by the loader |

- **Drawing.** If `override.gspl` exists, the loader reads it, removes it, flushes the
  volume and checks that it is gone, and only then draws it. If it can't be removed, it
  is not drawn. Without an override that is drawn, the loader draws `splash.gspl`, and
  `default.gspl` when that is missing or skipped, and nothing when both are.
- **Writing.** The image is written as `<name>.new`, synced and read back. Then the old
  file is removed and the new one renamed, each synced. A cut leaves the old image, no
  image or the new one, and a `.new` file the next writer removes. The loader reads no
  `.new` file.
- **Time.** Reading and checking one image takes at most one second; past that it is
  skipped.

### The image format (`format=1`)

The format is the same on every machine. One file holds one picture, or the instruction
to leave the screen. All numbers are little endian. The header is 64 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | the bytes `GLSPLASH` |
| 8 | 2 | format version: 1 |
| 10 | 2 | kind: 0 a picture, 1 leave the screen as it is |
| 12 | 4 | width of the picture, in pixels |
| 16 | 4 | height of the picture |
| 20 | 4 | width of the display mode the picture was made for |
| 24 | 4 | height of that mode |
| 28 | 4 | pixel layout: 1 = four bytes a pixel: blue, green, red, one unused |
| 32 | 4 | background colour, `0x00RRGGBB` |
| 36 | 4 | encoding of the payload: 0 raw, 1 run-length |
| 40 | 8 | length of the payload in bytes |
| 48 | 4 | CRC-32 of the payload |
| 52 | 4 | CRC-32 of the header's bytes 0 to 51 |
| 56 | 8 | unused: a writer writes zero, a reader ignores them (no check covers them) |

- **CRC-32** is the one of zlib and Ethernet: polynomial `0xEDB88320` (reflected),
  start value and final XOR `0xFFFFFFFF`.
- **The payload** follows the header and runs to the end of the file. Pixels go row by
  row from the top, left to right, as the panel scans them (011 FR-009). A pixel's
  unused byte is ignored.
  - Raw: width × height pixels.
  - Run-length: a sequence of runs. A control byte `c` below 128 is followed by `c`+1
    pixels as they are; a control byte of 128 or more is followed by one pixel that
    repeats `c`−126 times (2 to 129). The runs give exactly width × height pixels.
- **Limits.** Width and height are 1 to 16384, the decoded picture (width × height × 4)
  is at most 32 MiB, and the file at most 32 MiB plus the header.
- **Leave the screen** (kind 1) is valid only as the override. The header's other
  picture fields are zero and no payload follows. A splash of kind 1 is skipped.
- **A reader checks, in this order:** the length (64 bytes at least), the first 8 bytes,
  the header's CRC, the version, the kind, that the payload length is the file's length
  less 64, the limits, the pixel layout, the payload's CRC, and that the payload decodes
  to exactly the picture. An image that fails any of them is skipped (011 FR-005).
- **Drawing.** A picture made for the mode the loader is in is drawn pixel for pixel,
  centred on its background colour when it is smaller than the mode. A splash made for
  another mode is scaled to fit with its aspect ratio kept and centred on its background
  colour. An override made for another mode is not shown (011 FR-008).
- **Several displays.** A file holds one picture, so an override is made for one
  display. When the loader owns more than one, it draws the splash on each and shows no
  override; the override is still used up (011 FR-010, FR-013).

## What a power cut leaves

| Write | Cut during it | The next start |
|---|---|---|
| The loader counts a start | the other slot is not valid | reads the record without that count; one start is uncounted |
| The loader clears a request | the other slot is not valid | one valid slot: no request is taken, the default set starts; 004 fails the trial as never started |
| The healthy mark, the shutdown step | the other slot is not valid | the count stays; the limit absorbs it |
| A set's files (install, repair) | a directory no record names | starts as before; the next writer removes it |
| The record after a set was written (install, accept, rollback, cancel) | the other slot is not valid | the record as it was: the old default set |
| Removing an old set | both slots already name only what stays | the new default set; the next writer removes the rest |
| The recovery's update | as for a set | the old recovery; with no record, either of the two |
| A splash or an override | a `.new` file, or no image | the old image, the default or none |
| The override's removal by the loader | the override is still there, or gone | shown at that start, or never shown |
