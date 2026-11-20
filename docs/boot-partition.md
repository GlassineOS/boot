# The boot partition of a UEFI PC

Status: **agreed design; the running system's kernel side built.** `glassine-bootimg`
with `HANDOFF=uefi` (install, reboot-test, accept, rollback, cancel, a failed trial,
retry, promote's finishing step, the first start's record of the installer's set) and
its library `lib/glassine-bootpart.sh` are built and host-tested against the installer's
golden bytes and a port of the loader's reader (`test/bootpart`); nothing has run on a
real PC. The healthy mark and the shutdown step (`unmarked`) are built too
(`glassine-loader-mark`, run by `glassine-deploy-accept`, its service's stop and
`glassine-hibernate`; host-tested in `test/bootpart`), and so is the rollback after a
healthy limit start (`glassine-bootimg rollback --limit`, 010 FR-013), and the running
system's requests (`glassine-loader-mark request`, run by `glassine-reboot-clean`:
`reboot recovery` writes `request=recovery`, `reboot menu` writes `request=menu` under a
parent; host-tested in `test/bootpart`, `test/bootraw` and `test/reboot`). Not built here:
the deployment list (`deploys`), the recovery's update, the repair, the splash store's
writer on FAT, the clearing of a request a loader that can't write left. The raw form's writer is built too
(`glassine-boot-raw`: the region table, the loader region, the splash regions; the
loader record by slots through `glassine-loader-mark` with `BOOT_FORM=raw`), host-tested
in `test/bootraw` against the loader's golden bytes and a port of its reader, and so is
the running system's loader update (`glassine-loader-update`, run by the accept step
after its healthy mark); nothing
has run on a device ("The running system's writer", below). This page is the contract between the three programs that read or write a PC's boot
partition: the loader, the installer, and the running system's tools (`glassine-bootimg`,
`glassine-deploy`, the boot-success step, the recovery). What they do and why is
[specs/010](../specs/010-uefi-deployments/spec.md) and
[specs/011](../specs/011-boot-splash/spec.md); this page gives the paths and the bytes.
Changes go through this repository first.

The boot partition is `glassine-boot`: one FAT32 file system, volume label `GLASSINE`,
created by the installer and owned whole by GlassineOS. The loader reads only the
partition it was started from.

## One rule, every device

Every machine GlassineOS runs on has one boot partition, named `glassine-boot`, with this
role: **it holds everything one start leaves for the next, and everything one system
leaves for another.** That is:

- the loader record (below);
- the splash store with its one-time override (011), the hibernate preview being an
  override;
- the probe report of a loader run under a parent bootloader ([handback.md](handback.md));
- the loader image, where a parent bootloader loads it from there;
- the kernel sets and the recovery image, where the loader starts them itself (a PC).

The block-list record of [blocklist.md](blocklist.md) sits today at the end of the
GlassineOS slot's boot image partition, where that page puts it. It may move to a region
of this partition later; until blocklist.md says so, it stays where it is.

Nothing else goes there: nothing of the person's, no secret, no copy of the deployment
state. The partition is not named after Android's `misc` (the bootloader message of the
same dual-boot devices); the two are unrelated.

## Two forms

The partition has one of two forms. Both hold the same things, in the same formats; only
how they are found differs.

1. **The FAT form**, exactly as on a PC: the FAT32 file system and the layout below.
   It is used wherever the firmware that reads the partition offers
   `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` on it. It needs a partition large enough for FAT32
   with 512-byte sectors (65,525 clusters at least, about 33 MiB); the installer's FAT32
   writer refuses smaller volumes.
2. **The raw form**, for a machine whose firmware (or parent bootloader) has no FAT
   driver: no file system, a region table at the start, and one region per topic
   ([below](#the-raw-form)). A new topic gets a region of its own with no change of
   format.

The installer picks the form from the machine's description. A reader tells them apart
by the content: a FAT32 boot sector (the firmware then offers a file system on the
partition) is the FAT form; the region table's magic is the raw form; anything else is a
partition that holds nothing, which every reader treats as a partition never written.
A loader started on the partition uses the FAT form when the firmware offers a file
system on it, and the raw form otherwise. A PC is always the FAT form.

The sections from Layout to the splash store describe the FAT form. The formats they
define (the records, a kernel set, the image format) are the same in the raw form.

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
| `request` | empty, `trial`, `recovery` or `menu` | set by `glassine-bootimg reboot-test` (`trial`), by `reboot recovery` (`recovery`) and, on a machine whose loader shows the start menu under a parent, by the running system's "reboot to the start menu" (`reboot menu`, `menu`; [handback.md](handback.md#the-start-menu)); both through `glassine-loader-mark request` (below); cleared by the loader before it acts on it; cleared by the running system when it finds one the loader left (a loader that can't write). A PC's loader takes no `menu` request (its list opens with a key at power-on) |
| `unmarked` | the count of starts not marked healthy, decimal | the loader (one more, before it starts the default or the previous set); the boot-success step (`0`: the healthy mark); the shutdown step (one less, 010 FR-012); the recovery (`0`, 010 FR-014) |
| `started` | id of the set the loader started last | the loader, in the same write as the count or the cleared request |
| `started_why` | why: `default`, `limit` (the previous set, because the count reached the limit), `choice` (the previous kernel set, picked in the list), `request` (a trial) | the loader, with `started` |
| `deploys` | the number of entries in the deployment list, `0` to `32` | `glassine-deploy publish` (through `glassine-loader-mark deploys`), in the running system and in the recovery; the installer (`0`) |
| `deploy1` … `deploy<n>` | `<deployment id> <state> <label>`, separated by single spaces: the state `previous`, `candidate`, `failed` or `kept` (never the current or a staged one, never one whose base is gone), in that order, the kept ones by id; the label `<version> <created date>`: the base's version as `glassine-deploy list` reports it (`version`) and the deployment's created date, each left out when unknown (no label at all when both are), never the base id; at most 43 printable ASCII characters, within the 64 the loader takes | with `deploys` |

- **The healthy mark** is the write of `unmarked=0`. The boot-success step makes it on
  every start that reaches the health conditions (010 FR-023), whichever set and
  deployment started, also a start by request (010 FR-044), and again after a resume
  of a session that had it. It is `glassine-loader-mark healthy`; a mark already at
  `0` is not written again. It changes no other key: in particular it leaves the loader's
  `display_failed` ([handback.md](handback.md#a-display-through-the-firmwares-refresh)),
  which only `glassine-loader-mark display-retry` clears.
- **The limit** is 3 in format 1. With no key pressed and no request, the loader starts,
  by the `unmarked` it reads: below 3 the default set; at 3 the previous set
  (`started_why=limit`); above 3, or at 3 with no previous set that checks, the recovery.
  When that start of the previous set reaches the health conditions, the boot-success
  step makes it the default set by the kernel rollback (010 FR-013), after the healthy
  mark: `glassine-bootimg rollback --limit` writes `default` = that set and `previous` =
  the one that failed in one write of the record, lists the failed kernel as `failed` in
  `state/kernel` (so `retry` can give it a trial again), cancels a kernel candidate and
  leaves the notice for the next login. It acts only when the record's `started` is
  this boot's set, `started_why` is `limit`, and `state/kernel`'s `previous_img` is that
  set and its `current_img` the record's `default`.
  A start of the recovery is not counted and writes nothing, apart from clearing a
  `request=recovery`.
- **A deployment picked in the list** leaves no mark in the record (010 FR-042): the
  set starts as it would have without the pick, with the same count and `started_why`.
- **The shutdown step** takes one off `unmarked`, never below 0, when the system shuts
  down or restarts in an orderly way, the running set is `started`, `started_why` is
  `default`, `limit` or `choice`, no healthy mark was written in this start, the start
  was no bare boot and no health check failed in it. It is `glassine-loader-mark
  shutdown`, run by the stop of the `glassine-deploy-accept` service when OpenRC goes
  down (`RC_GOINGDOWN`), before `localmount` takes the system partition away. The
  running set is the one `glassine.img=` names on this boot's command line. Under a
  parent (the raw form), where the default set is the parent's baseline and the
  loader's count writes an empty `started` for it ([handback.md](handback.md#the-loader-record-under-a-parent)),
  an empty `started` with `started_why=default` is the running set when this boot runs
  no set that either slot names. What
  this start did is in `/run/glassine`: `loader-marked` (the mark was written) and
  `health-failed` (a health check failed, written by the boot-success step). Both
  writes hold the system partition's state lock, as `glassine-bootimg`'s do.
- **A request** is honoured only from a record read with both slots valid. The loader
  writes the record with `request` empty, and `started` and `started_why=request` for a
  trial, and only after that write is flushed and read back does it start the trial set
  or the recovery. A trial start is not counted.
- **The running system's requests** (`glassine-loader-mark request menu|recovery|clear`,
  run by `glassine-reboot-clean menu|recovery` before a plain reboot) are one write of the
  record that changes `request` alone, under the state lock, then a read of the record
  again: the request counts only when the record in use holds it and both slots are valid,
  the record the loader takes a request from. A request already there with both slots
  valid is not written again. A board without a loader record, for `menu` any board but
  the raw form, and on the raw form a partition whose region `loader` holds no valid loader
  (the parent would boot its baseline and leave the request for a later start) refuse
  with exit 3 before anything is written (`glassine-loader-mark
  can-request` asks the same with no write, for the desktop's entry). A `request=trial` is
  `glassine-bootimg`'s: never replaced or cleared by these. `reboot menu` writes nothing
  and doesn't reboot when the request isn't written, and takes the request back when the
  reboot can't be started after it. `reboot recovery` uses the parent's own recovery
  request (the reboot reason) where the board keeps no loader record or the write fails,
  never both: a parent that went to its recovery by its reason would leave the request
  for the next start.
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
that form; a `CMDLINE` in another form, a second `CMDLINE` line or no `CMDLINE` line is refused for a
kernel set (an empty base is written `CMDLINE=""`).

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

  It finds the boot partition as the partition named `BOOT_PART` (board key, default
  `glassine-boot`) on the disk of the system partition that this boot's
  `glassine.system=PARTUUID=` names, and refuses with none or two; it mounts it (vfat)
  for the time of the command and unmounts it again (010 FR-026). The identities in the
  new set's command line are the ones this boot was started with, and its base is
  `board.conf`'s `CMDLINE`, read by the installer's rules. "Removes what a cut write
  left" is the sets no slot names and the `.new` files; the recovery's directories are
  left to the recovery's update. A slot holding a NUL byte, which this shell code can't
  carry, makes it refuse before it writes anything.

  `reboot-test` writes `request=trial`. Accept makes the trial set the default set and
  the default set the previous one; rollback swaps the default and the previous set;
  cancel and a failed trial clear `trial`. Each is one write of the loader record,
  under 004's rules for the default slot (`writing` is set first). A set no record names
  any more is removed as "Before files are removed" says.
- **The first start** of an installation records the installer's set on the system
  partition (today `glassine-bootimg` does it, at the first `install`, accept or
  `rollback`, before it writes anything): when `state/kernel` has no `current_img`, the default set is checked as the
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

### The image format (`format=2`)

The format is the same on every machine. One file holds one picture, or the instruction
to leave the screen. All numbers are little endian. The header is 64 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | the bytes `GLSPLASH` |
| 8 | 2 | format version: 2 (1 is [format 1](#format-1), which readers still read) |
| 10 | 2 | kind: 0 a picture, 1 leave the screen as it is |
| 12 | 4 | width of the picture, in pixels |
| 16 | 4 | height of the picture |
| 20 | 4 | width of the display mode the picture was made for |
| 24 | 4 | height of that mode |
| 28 | 4 | pixel layout (below): 1 BGRx, 2 RGB888, 3 grey8 |
| 32 | 4 | background colour, `0x00RRGGBB` |
| 36 | 2 | compression of the payload (below): 0 none, 1 run-length, 2 LZ4 |
| 38 | 2 | filter (below): 0 none, 1 up |
| 40 | 8 | length of the payload in bytes |
| 48 | 4 | CRC-32 of the payload |
| 52 | 4 | CRC-32 of the header's bytes 0 to 51 |
| 56 | 8 | unused: a writer writes zero, a reader ignores them (no check covers them) |

- **CRC-32** is the one of zlib and Ethernet: polynomial `0xEDB88320` (reflected),
  start value and final XOR `0xFFFFFFFF`.
- **Pixel layouts.** The stored pixels go row by row from the top, left to right, as the
  panel scans them (011 FR-009), with no padding between rows.
  - 1, BGRx: four bytes a pixel: blue, green, red, one unused byte (ignored).
  - 2, RGB888: three bytes a pixel: red, green, blue.
  - 3, grey8: one byte a pixel, 0 black to 255 white; drawn as red = green = blue =
    that byte. A writer that converts colour to grey takes the integer luma
    `(77 × red + 150 × green + 29 × blue + 128) / 256`.
- **The payload** follows the header and runs to the end of the file. Undone in this
  order, it gives the stored pixels: first the compression, then the filter.
  - Compression 0, none: the stored bytes as they are, width × height × the layout's
    bytes a pixel.
  - Compression 1, run-length: a sequence of runs over pixels of the layout (1, 3 or 4
    bytes). A control byte `c` below 128 is followed by `c`+1 pixels as they are; a
    control byte of 128 or more is followed by one pixel that repeats `c`−126 times (2
    to 129). The runs give exactly width × height pixels.
  - Compression 2, LZ4: one LZ4 block ([the block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
    of LZ4 1.x), no frame and no size before it, whose output is exactly width ×
    height × the layout's bytes a pixel. Any LZ4 encoder's block is valid, a fast one
    or a high-compression one.
  - Filter 0, none: the decompressed bytes are the stored pixels.
  - Filter 1, up: each decompressed byte is the stored byte less the byte one row above
    it (row length = width × bytes a pixel), modulo 256; the first row is stored as
    it is. A reader adds the byte above, row by row from the top.
- **Limits.** Width and height are 1 to 16384, a picture has at most 8,388,608 pixels
  (width × height, in every layout: 32 MiB at four bytes a pixel), and the file is at
  most 32 MiB plus the header. A reader computes the decoded size from the header and
  checks these limits before it reserves memory for the picture.
- **Leave the screen** (kind 1) is valid only as the override. The header's other
  picture fields are zero and no payload follows. A splash of kind 1 is skipped.
- **A reader checks, in this order:** the length (64 bytes at least), the first 8 bytes,
  the header's CRC, the version (1 or 2), the kind, that the payload length is the
  file's length less 64, the limits, the pixel layout, that it knows the compression
  and the filter, the payload's CRC, and that the payload decodes to exactly the
  picture: a stream that ends early, runs past the picture or holds anything left over
  fails. An image that fails any of them is skipped (011 FR-005). A reader supports
  every layout with every compression and filter.
- **Writers** choose per picture: the layout for the display (grey8 for a grey panel,
  RGB888 or BGRx for a colour one), then the smallest payload among the compressions
  with and without the filter, and none when nothing is smaller. A writer that must be
  fast takes LZ4 without the filter: the hibernate preview (011 FR-022) does. Every
  writer writes format 2.
- **Drawing.** A picture made for the mode the loader is in is drawn pixel for pixel,
  centred on its background colour when it is smaller than the mode. A splash made for
  another mode is scaled to fit with its aspect ratio kept and centred on its background
  colour. An override made for another mode is not shown (011 FR-008).
- **Several displays.** A file holds one picture, so an override is made for one
  display. When the loader owns more than one, it draws the splash on each and shows no
  override; the override is still used up (011 FR-010, FR-013).

#### Format 1

Format 1 is format 2 with these differences, and readers read it as before:

- the version at offset 8 is 1;
- the pixel layout is 1 (BGRx) only;
- offsets 36 to 39 are one field of four bytes, the encoding: 0 raw (compression none),
  1 run-length; there is no filter. Read as format 2's two fields, that is the same
  compression and the filter 0;
- an image of another layout or encoding is skipped.

#### Sizes and speed

Measured on 21 test pictures (seven e-ink desktop and settings screenshots of a 1404×1872
panel and a page of dense text rendered at that size, a 1920×1080 colour desktop, two CC0
photographs, gradients and noise), on a
desktop x86-64 core with the loader's build settings (size-optimised). An estimate for an
in-order Arm Cortex-A53-class core at about 1.6 GHz is ten times these times: an assumed
factor, not measured. Size is the file's, as a share of the raw picture in that layout:

| Picture, layout | none | run-length | LZ4 | up + LZ4 |
|---|---|---|---|---|
| e-ink screenshots and the text page, grey8 (median / largest of 8; the largest is the text page, the screenshots stay at or below 0.033 with LZ4) | 1 | 0.030 / 0.210 | 0.019 / 0.081 | 0.013 / 0.074 |
| colour desktop 1920×1080, RGB888 | 1 | 0.155 | 0.073 | 0.096 |
| colour desktop 1920×1080, BGRx | 1 | 0.148 | 0.060 | 0.078 |
| photographs 1920×1080, RGB888 | 1 | 0.96 | 0.85 | 0.75 |
| photographs on the e-ink panel, grey8 | 1 | 1.05 | 0.91 | 0.82 |
| a gradient in both directions 1920×1080, RGB888 | 1 | 0.275 | 0.239 | 0.010 |
| noise | 1 | 1.01 | 1.004 | 1.004 |

- Writing an e-ink screenshot from the screen's 32-bit pixels (to grey8, LZ4, the CRC)
  takes about 4 ms (40 ms estimated on an A53-class core), and the result is 13 to
  86 KB for the screenshots and 212 KB for the text page, instead of 2.6 MB. Without compression, the CRC of the whole picture alone takes
  longer; LZ4 is the fast choice.
- Reading and checking one image (CRC, decoding, the filter, conversion to the
  display's 32-bit pixels) takes at most 22 ms on that core for every picture above,
  far below the reader's one second.

## The raw form

The partition's bytes, with no file system. All numbers are little endian, all offsets
are bytes from the partition's start, and CRC-32 is the one of the image format below
(the UEFI boot service `CalculateCrc32` gives the same value).

### The region table

The table is 4096 bytes, written twice: the primary copy at offset 0 and a backup in the
partition's last 4096 bytes. The two are identical.

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | the bytes `GLREGION` |
| 8 | 4 | format: 1 |
| 12 | 4 | the number of entries, 1 to 62 |
| 16 | 8 | the partition's size in bytes the table was made for |
| 24 | 40 | zero |
| 64 + 64 × i | 64 | entry i (below) |
| … | … | zero up to byte 4092 |
| 4092 | 4 | CRC-32 of bytes 0 to 4091 |

An entry:

| Offset | Size | Field |
|---|---|---|
| 0 | 32 | the region's name: 1 to 31 characters of `a`–`z`, `0`–`9` and `-`, then zero bytes |
| 32 | 8 | offset of the region |
| 40 | 8 | size of the region |
| 48 | 4 | flags: 0 |
| 52 | 4 | CRC-32 of the entry's bytes 0 to 51 |
| 56 | 8 | zero |

- **A table is valid** when its magic, format and CRC match, its size is the partition's
  size, and every entry is valid: the entry's CRC matches, the name is well formed and
  appears once, offset and size are multiples of 4096, the size is not zero, the region
  starts at 4096 or later and ends at or before the backup's start, and no two regions
  overlap. A table with one entry that isn't valid is not valid.
- **Which copy:** the primary when it is valid, else the backup when it is valid, else
  none: the partition holds nothing (as a partition never written). A reader that found
  only the backup valid uses it and writes nothing to the table.
- **A region's content** carries its own check (the record's check line, the loader
  header's CRC, an image's CRCs). The table holds no CRC of the content, so writing a
  region never writes the table. The entry's CRC covers the entry, not the region.
- **Names** a reader doesn't know are ignored, and so are regions with a flag it doesn't
  know.
- **Writing the table** (the installer; `glassine-boot-raw init`; a later release that
  adds a region): the backup
  first, flushed and read back, then the primary, flushed and read back. A cut leaves a
  valid primary (the old table) or a valid backup (the new one). Regions are added in
  space no region uses; a region is never moved or shrunk while it holds content.

### The regions

| Name | Size at least | Holds | Written by |
|---|---|---|---|
| `record` | 32 KiB | the loader record: slot a at the region's start, slot b at 16 KiB | the loader; the running system; the recovery; the installer |
| `probe` | 64 KiB | the probe report of [handback.md](handback.md#the-probe-report) | the loader, on request |
| `loader` | 8 KiB | the loader image header (4096 bytes), then the loader image ([handback.md](handback.md#the-loader-region)) | the installer; the running system's loader update (`glassine-loader-update`, by `glassine-boot-raw loader`) |
| `splash-default` | 64 KiB | the release's splash: one image of the format below | the installer, the repair, the running system's loader update (`glassine-boot-raw splash-default`) |
| `splash` | 64 KiB | the splash the system set | the running system (`glassine-boot-raw splash`) |
| `override` | 64 KiB | the one-time override | the running system (`glassine-boot-raw override`, `clear`); removed by the stage that draws it |

A region holds one item at its start. The bytes after the item's end (the end its own
header gives) are ignored: a writer needn't clear them.

**Writing a region** (all regions but `record`), with content of at most the region's
size:

1. write zero over the region's first 4096 bytes, flush, and read them back as zero;
2. write the content's bytes from 4096 to its end (rounded up to whole blocks), flush;
3. write the content's first 4096 bytes, flush;
4. read the content back and compare.

The first 4096 bytes hold every item's header, so between steps 1 and 3 the region holds
no item, and a cut at any byte leaves the old item (before step 1 ends), no item, or the
new one. A write that would not fit is refused before step 1. The record is written by
slots instead, as on FAT: one slot whole, flushed, read back.

**The splash store, raw.** The images of the regions `splash-default`, `splash` and
`override` are files of the image format below, written as the region's content. A
reader reads the 64-byte header first and takes the file's length from it (64 plus the
payload length), within the region; a region whose first 8 bytes aren't `GLSPLASH` holds
no image.

- **Drawing:** as on FAT. The override is removed by writing zero over the region's first
  4096 bytes, flushing and reading them back as zero; only then is it drawn. If that
  fails, it is not drawn.
- **Writing:** "Writing a region", above, for `.new`, sync and rename on FAT. An image
  larger than its region is refused, with a message (011 FR-020).

### The running system's writer

The raw form is written from the running system by `glassine-boot-raw` and
`lib/glassine-bootpart.sh` (busybox only; CRC-32 from gzip's trailer):

| Command | Writes |
|---|---|
| `glassine-boot-raw init [--force] DEV` | the table of "Sizes" for DEV's size (16 MiB or more, a multiple of 4096; a larger partition gets the same regions and more free space): every region emptied first (`record` whole, the others' first 4096 bytes), then the backup copy, flushed and read back, then the primary, flushed and read back. Refused where either copy of a valid table, or a FAT boot sector, is already there, unless `--force`; `--force` empties every region, the record included |
| `glassine-boot-raw loader DEV FILE` | the region `loader`: the header of [handback.md](handback.md#the-loader-region) and the image (1 to 3,141,632 bytes), by "Writing a region" |
| `glassine-boot-raw splash-default\|splash\|override DEV FILE` | that region: a format-2 image whose header, CRCs and (uncompressed) payload length pass the reader's checks; leave the screen only as the override; refused when larger than the region |
| `glassine-boot-raw clear DEV REGION` | the region's first 4096 bytes zero, read back (the override's removal by a running system, 011 FR-015) |
| `glassine-boot-raw table DEV`, `read DEV REGION`, `find [NAME]` | nothing: the table in use, a region's item as its reader takes it, the device of the partition of that GPT name |

Every refusal comes before the first write.

**The loader update** (`glassine-loader-update`, 012 FR-026) puts the loader and the
default splash a package ships (`/usr/share/glassine/loader/loader.efi` and
`splash-default.gspl`; a board's loader package fills the directory, pinned to a loader
release) into the regions `loader` and `splash-default`. It runs on a board with
`BOOT_FORM=raw` only, never with `HANDOFF=uefi` (a PC's installer owns its FAT), and the
accept step (`glassine-deploy-accept`) runs it only after its healthy mark succeeded in
that start (written, or the count was 0 already), and on a candidate only once the candidate is accepted: the system that arms
the loader is one that marks its starts healthy on the raw form, so `unmarked` can't
climb to the limit under it. For each region, the splash first and the loader last: the
item it holds, read as its reader takes it, is compared with the file; the same bytes:
nothing written. Else the file is written as "Writing a region" says, read back and
compared; a write that fails or doesn't read back leaves the region emptied (for
`loader` the parent's baseline) and nothing more is written. A partition with no valid
table, no partition of that name or two are reported and nothing is written: the update
never makes a table. A loader a later package brings is written at the next healthy
start. It is never run from a package's install script (an image build runs those on the
build host).

`init` makes no loader record: an empty
`record` region holds none, and the running system's writers never make one (012
FR-020); the installer writes the first.

**The loader record** in the raw form is written by the same code as on FAT
(`gp_write`): the slot not in use, its 16384 bytes at the slot's place in `record`,
flushed and read back (one retry). `glassine-loader-mark` (`healthy`, `display-retry`,
`shutdown`, `request`, `display-sync`, `deploys`) does so, and the initramfs when it takes a `deploy_once` (handback.md), on a board whose `board.conf` says `BOOT_FORM=raw`; the
partition is the one named `BOOT_PART` (default `glassine-boot`), found on the system
partition's disk when the command line names one (`glassine.system=PARTUUID=`), else as
the one partition of that name on any disk (a device with one disk). A slot whose last
byte is not a newline or whose first line is not `format=1` (a region never written,
a slot cut over zeros) is not valid, whatever else it holds.

`BOOT_FORM` (board key): empty, the FAT form when `HANDOFF=uefi` and no loader record
otherwise; `raw`, the raw form (not with `HANDOFF=uefi`: a PC is always FAT). It says
only where the loader record is; how kernels reach the parent stays `HANDOFF`'s. A board
sets it once the parent starts the loader and the parent's recovery clears the count
(012 FR-020).

`LOADER_DISPLAY` (board key, raw form only): the record's `display` for this board (`epd-fw`
on a board whose firmware has the extended graphics output of handback.md). The loader
update's last step (`glassine-loader-mark display-sync`, after the regions hold the
package's files) writes `display` to it when the record holds another value, by
`gp_write` with its read-back; it never writes `display_failed` or `drew`, so a sticky
`display_failed` stays until the person's `display-retry`. Empty or absent: `display` is
left as it is (the installer's).

`LOADER_TOUCH`, `LOADER_PARENT_CMDLINE`, `LOADER_PARENT_SETS` (board keys, raw form
only), written by the same step in the same write as `display`, each only when the
record holds another value: `LOADER_TOUCH=on` sets an empty `touch` to `on` (the
loader's touch driver in the start menu; a person's `probe` or `off` is kept);
`LOADER_PARENT_CMDLINE=no` and `LOADER_PARENT_SETS=no` set `parent_cmdline=no` and
`parent_sets=no`: the parent passes no command line, so a start menu's deployment pick
goes through the record's `deploy_once`, and it boots no kernel set, so the menu offers
no previous kernel (handback.md, "The start menu"). Empty or absent: left as they are.

The deployment list (`deploys`, `deploy1` …) is written by `glassine-deploy publish`
through `glassine-loader-mark deploys` (one write, only when it differs, `deployN` past
the new count cleared) after every command that changes which deployments exist or
what they are (switch, accept, select, rollback, remove, stage), and on every healthy
start that accepts nothing (010 FR-041). `deploy_once` is cleared by the initramfs
before it starts that deployment (handback.md).

`LOADER_OTHER` (board key, raw form only): the record's `other` for this board, the
parent's other system that the start menu may offer (handback.md, "The other system"):
`android` on a board whose parent keeps a stock Android it can start once. The same step
writes it, in the same write as `display` when both differ; a value outside
`[a-z0-9-]` is said and nothing is written. Empty or absent: `other` is left as it is.

Every write of `glassine-boot-raw` and of the record's writers holds an exclusive
lock (`flock`) on the device, so a region write and a record write never overlap; the
record's writers also hold the system partition's state lock, as on FAT.

### Sizes

The sizes are the table's: readers take them from it and assume none. For a 16 MiB
partition (the Boox Note Air's proposal, taken from the end of its user data), one table
that fits:

| Region | Offset | Size |
|---|---|---|
| (table) | 0 | 4 KiB |
| `record` | 64 KiB | 32 KiB |
| `probe` | 128 KiB | 64 KiB |
| `loader` | 1 MiB | 3 MiB |
| `splash-default` | 4 MiB | 3 MiB |
| `splash` | 7 MiB | 3 MiB |
| `override` | 10 MiB | 3 MiB |
| free for later regions | 13 MiB | 3 MiB less 4 KiB |
| (backup table) | 16 MiB less 4 KiB | 4 KiB |

What fits a 3 MiB image region (3,145,664 bytes of payload):

- **grey8, always:** up to 3,145,664 pixels uncompressed, so every full-panel picture of
  the Boox Note Air's 1404×1872 panel (2,628,352 bytes with its header) fits whatever it
  shows, noise included. Its screenshots take 13 to 86 KB with LZ4, a page of dense text
  212 KB.
- **RGB888 or BGRx:** uncompressed, up to 1,048,554 or 786,416 pixels (such as 1280×800
  or 1024×600). A full 1920×1080 or 1404×1872 colour picture fits only compressed to 3 MiB
  or less: desktops and flat pictures do (0.06 to 0.10 of raw with LZ4), photographs don't
  (0.75 and more with LZ4).

So the 16 MiB partition and its 3 MiB image regions hold every picture of a grey panel.
A colour device with the raw form and a 1920×1080 panel would need regions of 8 MiB
(an uncompressed BGRx picture and its header) to hold a photograph.

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
| A region (raw form) | a region whose first 4096 bytes are zero, or the old item | no item there (the default splash, no report, the parent's baseline for `loader`), or the old item |
| The region table (raw form) | a primary or a backup that isn't valid | the valid copy: the old table or the new one |
| The override's removal (raw form) | the header still there, or zero | shown at that start, or never shown |
