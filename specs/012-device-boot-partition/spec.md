# Feature Specification: The boot partition on devices with their own bootloader (hand-back)

**Feature branch:** `boot-partition-forms`
**Created:** 2026-11-16 · **Status:** spec, for review; the running system's writer of the
raw form built and host-tested (FR-020 to FR-028: `glassine-boot-raw`, the raw
backend of `lib/glassine-bootpart.sh`, `glassine-loader-update`, `glassine-loader-mark
request` and `display-sync`, `glassine-reboot-clean`; `test/bootraw`, `test/reboot`); not
built: the installer's raw writer; nothing has run on a device
**Builds on:** [010-uefi-deployments](../010-uefi-deployments/spec.md),
[004-kernel-records](../004-kernel-records/spec.md),
[005-blocklist-handoff](../005-blocklist-handoff/spec.md) · **Interfaces:**
[docs/handback.md](../../docs/handback.md) (the start, the answer, the probe),
[docs/boot-partition.md](../../docs/boot-partition.md) (the boot partition, its two
forms, the loader record, the splash store), [docs/blocklist.md](../../docs/blocklist.md) (a kernel set the parent can read)
· **Ticket:** [hub#53](https://github.com/GlassineOS/hub/issues/53) (the selection
layer of the block-list hand-off)

## Summary

Some machines start a bootloader of their own that GlassineOS keeps: on the Boox
Note Air, Qualcomm's ABL in GlassineOS's build. Such a **parent bootloader** chooses
nothing for GlassineOS beyond its slot, so it has no trial, no count of failed starts and
no way into the recovery that the running system can ask for.

The hand-back gives it 010's choices without moving them into the parent. On the
GlassineOS slot, the parent starts the GlassineOS loader as a UEFI program, from the
machine's boot partition. The loader reads its record there, counts the start and picks the default,
previous or trial set, a one-shot request or the recovery, exactly as on a PC. It starts
no kernel: it hands its answer back through UEFI exit data, and the parent boots what the
answer names. When anything goes wrong, the parent boots what it boots today.

010 is the PC's spec and stays so. This spec adds a second way to run the same loader,
with the same record and the same decisions, for a machine whose firmware the loader
can't replace.

Every machine has one boot partition, `glassine-boot`, the same name and role as on a
PC: it holds everything one start leaves for the next and one system leaves for another
(the loader record, the splash store and its override, the probe report, the loader
where a parent reads it). It has two forms: FAT as on a PC where the firmware reads FAT,
and a raw form with a region table where it doesn't
([boot-partition.md](../../docs/boot-partition.md#two-forms)).

## Terms

| Term | Meaning |
|---|---|
| parent | the bootloader that starts the loader and acts on its answer |
| baseline | what the parent boots on its GlassineOS slot without the loader (on the Note Air, the boot partition of its GlassineOS slot) |
| boot partition | `glassine-boot`, in the FAT form or the raw form ([boot-partition.md](../../docs/boot-partition.md#two-forms)) |
| region | a named part of the raw form, found through its region table |
| answer | what the loader hands back: `baseline`, `recovery` or a kernel set by id |
| headless | the loader draws nothing, waits for no key and shows no list |

## User scenarios

### Scenario 1 – An ordinary start (P1)

**Given** a machine whose parent starts the loader, and a record with no request and a
count below the limit,
**When** it starts,
**Then** the loader counts the start and answers `baseline`, and the parent boots its
baseline. The start takes no longer than reading the loader and its record.

### Scenario 2 – Starts that never become healthy (P1)

**Given** three counted starts with no healthy mark,
**When** the machine starts again,
**Then** the loader answers the previous set when the parent can boot one, and the
recovery when it can't (010 FR-011); the parent takes its recovery path.

### Scenario 3 – The recovery on request (P1)

**Given** `reboot recovery` in the running system, which writes `request=recovery`,
**When** the machine restarts,
**Then** the loader clears the request durably and answers `recovery`, and the parent
starts its recovery once. The start after it is the ordinary one.

### Scenario 4 – A kernel trial (P2)

**Given** a trial set the parent can read (on the Note Air, a block-list set of 005) and
`request=trial`,
**When** the machine restarts,
**Then** the loader clears the request before it answers `set:<trial id>`, and the parent
boots that set once. A parent that can't read the set boots its baseline, and 004 fails
the trial.

### Scenario 5 – The loader can't help (P1)

**Given** a boot partition that is missing, never written, has no valid region table,
or holds a damaged loader, or a loader that fails, returns garbage or names an answer the parent doesn't
know,
**When** the machine starts,
**Then** the parent boots its baseline, as it did before the loader existed.

### Scenario 6 – What the firmware offers (P3)

**Given** `probe=1` in the record,
**When** the machine starts,
**Then** the loader writes a report of the firmware's protocols, displays, consoles and file
systems to the boot partition, reading only, and then answers as it would have without it.

## Requirements

### The parent

- **FR-001** The parent starts the loader only on its GlassineOS slot, and only where it
  would boot that slot's baseline: after its own ways into its own modes (on the Note
  Air: the fastboot key, the closed cover at power-on, a recovery request in `misc` or in
  the reboot reason), which keep working as before, whatever is on the boot partition.
- **FR-002** It reads the loader from the boot partition and starts it as
  [handback.md](../../docs/handback.md#starting-the-loader-the-parents-side) says: in
  the raw form through the region table (both copies tried, the table's and the entry's
  CRC checked), the region `loader`'s header and image checked; in the FAT form the file
  `\EFI\glassine\loader.efi`. Started from memory with the partition's device path,
  the partition's handle as
  `DeviceHandle`, the load option `glassine.handback=1`. A parent reads no other region
  or file.
- **FR-003** It acts only on an answer that passes every check of
  [handback.md](../../docs/handback.md#what-the-parent-does-with-it). Every other
  outcome is its baseline: no boot partition, no valid region table or no `loader`
  region, a form the parent can't read, a header or image that fails its CRC, `LoadImage` or `StartImage` failing, no exit data, an answer that fails its
  check, an answer it doesn't know, a set it can't boot or whose source fails its own
  checks. None of these ends in a hang, in a mode the person didn't ask for, or in a
  retry.
- **FR-004** The answer changes only which image the parent boots and, for
  `cmdline_add`, its command line. The parent's own state (slot attributes, its
  recovery request, its verified-boot steps) is handled as for a baseline boot.
- **FR-005** The parent writes nothing on the boot partition and keeps no state of the
  loader's.
- **FR-006** A parent with no display the firmware can draw on starts the loader without
  one: the loader runs headless. A parent never asks the loader to draw. The one display
  a loader under a parent may draw on is a panel the firmware refreshes through an
  extended graphics output, and only with `display=epd-fw` in the record
  ([handback.md](../../docs/handback.md#a-display-through-the-firmwares-refresh)).
- **FR-007** Where the parent can arm a watchdog through the firmware, it does so for the
  loader's run (handback.md, step 5), so a loader that hangs ends in a reset.

### The loader

- **FR-008** With `glassine.handback=1` in its load options, the loader runs in hand-back
  mode, on the partition of `DeviceHandle`. When the firmware offers a file system on
  that partition, it uses the FAT form, with the paths of boot-partition.md; else the raw
  form, through the block I/O and the region table, with no offset of its own. Without
  the option, the loader runs as on a PC (loader spec 001), unchanged.
- **FR-009** In hand-back mode it draws nothing, opens no display, waits for no key,
  shows no message, and calls no serial protocol unless the load options ask for it
  (`glassine.log=serial`). With the display of FR-006 it draws the picture of 011 (one
  full refresh, before it answers) and, when `request=menu` asks for it or the last
  start wasn't marked healthy, the start menu: 010's list, picked by touch (no menu without a tap
  source: the default at once), its picks answered as hand-back answers
  ([handback.md](../../docs/handback.md#the-start-menu)); no key line and no message. It
  draws only after a durable write has counted the start and set `drew=1`, and clears
  `drew` in one more write after its last refresh returned, before it answers; it draws
  only while the sticky `display_failed` is not set, and a start that finds `drew=1`
  with `unmarked` above 0 sets it; only the running system's `glassine-loader-mark
  display-retry` clears it. So a refresh that never returns can't stop the limit, and
  doesn't come back after every healthy boot
  ([handback.md](../../docs/handback.md#a-display-through-the-firmwares-refresh)).
- **FR-010** It decides as 010 and boot-partition.md say, with the record keys of
  [handback.md](../../docs/handback.md#the-loader-record-raw): a request taken only from
  a record read with both slots valid and cleared durably before the answer; the count
  raised before the answer for the default and the previous set; the recovery not
  counted. It makes the same writes it makes on a PC, and no others, apart from the
  probe report and the writes of FR-009's display (`drew` set and cleared, the menu
  write and the pick's write).
- **FR-011** It answers `baseline` for the default set when the record names none, and
  `set:<id>` with its `_rec` value when it names one. It answers the previous or trial
  set as `set:<id>`, and the recovery as `recovery`. It checks no set itself: the files
  of a set are the parent's to read and check.
- **FR-012** With no loader record (a partition never written, or both slots not valid),
  it answers `baseline` and writes nothing. A PC's loader starts the recovery in that
  case (010 FR-008); a parent has a baseline, which is the better floor.
- **FR-013** A record it can't write (010 FR-009) makes it answer `baseline`, uncounted,
  with no request taken.
- **FR-014** It ends with `Exit`, the answer in the exit data, every protocol it opened
  closed. A panic ends in `Exit` without exit data, which the parent reads as no
  answer.
- **FR-015** It opens every protocol with `GetProtocol`, never exclusively, so that no
  driver of the firmware is disconnected for the parent's later use.
- **FR-015a** In hand-back mode, headless, it reads and writes nothing of the splash store: the
  images and the override stay as they are for the stage of the machine that draws
  ([handback.md](../../docs/handback.md#the-splash-store-under-a-parent)). The store's
  code reads and writes the raw form too, for a loader that draws and for the running
  system's writer (011 FR-019, FR-020). With the display of FR-006 it uses the store as
  on a PC: the override removed durably before it is drawn.

### The probe

- **FR-016** With `probe=1` in the record in use, the loader writes the report of
  [handback.md](../../docs/handback.md#the-probe-report) (the region `probe`, or
  `\glassine\probe.txt`), before it answers, and only there. The report says whether
  the firmware offers a file system on the boot partition and on which handles it offers
  one at all, which decides the form a machine needs. Without it, it writes nothing there.
- **FR-017** The probe is read-only towards the firmware: listing handles and their
  protocols, the memory map and the loaded images, `GetVariable`, the graphics outputs
  read raw ([handback.md](../../docs/handback.md#graphics-outputs-read-raw): `QueryMode`,
  and `GetFrameBuffer` on an extended one), reading the text console's mode fields and
  the input devices' interfaces and Modes from memory (the absolute and simple pointers'
  ranges, the text inputs' identities). No mode is set, nothing is drawn or refreshed, no
  other protocol function is called (no input device's `Reset`, `GetState` or
  `ReadKeyStroke`), no hardware is touched.
- **FR-018** A probe that fails (the write, the report too large) is logged and changes
  nothing else: the answer is the one the loader would have given without it.
- **FR-019** The loader never changes `probe`; the running system clears it once it has
  read the report.

### The running system's side

- **FR-020** The writers of the loader record are those of boot-partition.md, writing the
  slots of the region `record` instead of files in the raw form, under the same rules. On a machine with a parent, the
  running system writes no record until the parent's recovery clears the count as 010
  FR-014 says: a recovery that doesn't would be started again at every start once the
  limit is reached.
- **FR-021** `reboot recovery` on such a machine writes `request=recovery` when a record
  exists, and uses the parent's own recovery request when none does.
- **FR-022** The board says where its loader record is: `BOOT_FORM=raw` in `board.conf`
  for the raw form, independent of `HANDOFF` (how kernels reach the parent). The
  record's writers (the healthy mark, `display-retry`, the shutdown step) then find the
  partition by its GPT name `glassine-boot` (`BOOT_PART`): on the system partition's
  disk when the command line names one, else the one partition of that name, and
  nothing is written with none or two. A board sets the key only once FR-020 holds.
- **FR-023** The running system formats a raw partition (`glassine-boot-raw init`):
  the region table of "Sizes" for the partition's size, the regions emptied first, the
  backup copy written, flushed and read back before the primary. It refuses where a
  valid table or a FAT boot sector is, unless forced, and a partition below 16 MiB. It
  makes no loader record.
- **FR-024** It writes the loader region (the header of handback.md, then the image)
  and the splash regions (format-2 images that pass the reader's checks) as "Writing a
  region" says, and refuses before the first write what is not valid or doesn't fit.
  A cut at any byte leaves the old item, no item or the new one.
- **FR-025** Every write of a region or a record slot holds an exclusive lock on the
  device, and the record's writers also the system partition's state lock.
- **FR-026** The running system installs and updates the loader (`glassine-loader-update`):
  the loader and default splash a package ships, pinned to a loader release, go into
  the regions `loader` and `splash-default` when they hold other bytes or nothing, the
  splash first, the loader last. Only with `BOOT_FORM=raw`, never with `HANDOFF=uefi`;
  only after the boot-success step's healthy mark succeeded in that start (written, or
  the count was 0 already), and on a
  candidate only once it is accepted, so a loader is armed only by a system that marks
  its starts healthy on the raw form. A region whose item has the same bytes is not
  written. Each write is read back; one that fails or doesn't read back leaves its
  region empty (the parent's baseline for `loader`), never part of an item, and nothing
  more is written. A partition without a valid table is reported and left as it is (no
  table is made); the tool that installs the loader ships in the same package as the
  record's raw writers, and the package with the loader depends on it.
- **FR-027** The running system's "reboot to the start menu" (`reboot menu`) writes
  `request=menu` into the record on a board with `BOOT_FORM=raw`, then reboots plainly;
  on any other board, or when the write doesn't read back with both slots valid, it
  refuses and doesn't reboot. A reboot that can't be started after the write takes the
  request back. The desktop offers it only where the board's loader takes it.
- **FR-028** A board whose loader draws through the firmware's refresh names the value in
  `board.conf` (`LOADER_DISPLAY=epd-fw`); after the loader update, the running system
  writes the record's `display` to it when it differs, and never writes `display_failed`
  or `drew` (only the person's retry clears them).

## Key entities

- **The boot partition**: `glassine-boot`, owned whole by GlassineOS; FAT as on a PC, or
  raw with a region table (`record`, `probe`, `loader`, `splash-default`, `splash`,
  `override`).
- **The answer**: `format`, `boot`, `set_rec`, `cmdline_add`, `why`, its CRC line; in
  UEFI exit data after a fixed UCS-2 prefix.
- **The probe report**: format, firmware identity, protocols with counts, graphics
  output modes, console handles, file systems, the loader's log; with its own check.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The boot partition's two forms and the region table | owned (new); consumed by the parent, the loader, the installer and the running system | `format=1` | `docs/boot-partition.md`, "Two forms", "The raw form" |
| The loader region's header | owned (new); written by the installer and the running system, read by the parent | `format=1` | `docs/handback.md`, "The loader region" |
| The load options and the answer in exit data | owned (new); between a parent and the loader | `format=1` | `docs/handback.md`, "Starting the loader", "The answer" |
| The probe report | owned (new); written by the loader, read by the running system and by people | `format=1` | `docs/handback.md`, "The probe report" |
| The loader record | owned (unchanged); files in the FAT form, the region `record` in the raw form | `format=1` | `docs/boot-partition.md` |
| A block-list set | consumed by the parent | format 1 | `docs/blocklist.md` |
| UEFI `LoadImage`, `StartImage`, `Exit` with exit data | consumed (firmware) | UEFI 2.x | the UEFI specification, "Image Services" |

## Device scope and risk

- **Writes:** the loader writes one record slot per start and, on request, the probe
  report, both on the boot partition. The parent writes nothing new.
- **Never written:** every other partition; firmware variables.
- **Escape:** every failure of the loader or its partition ends in the parent's baseline,
  which is the boot of today. The parent's own ways in (fastboot, its recovery) come
  before the loader and don't depend on it. A hang inside the loader is ended by the
  parent's watchdog where there is one; else it needs a long press, and the escapes that
  come before the loader still work at the next start.
- **Unverified on hardware:** that the firmware the parent runs on hands exit data back
  from `StartImage` as edk2 does. Until that is shown on the device, every answer may
  arrive as no answer, which is the baseline: safe, but the hand-back does nothing.

## Edge cases

- **A loader that answers `recovery` at every start** (a bug, or a record stuck at the
  limit): the parent's recovery starts each time; the recovery clears the count (FR-020)
  or writes the partition. The parent's own ways in still work.
- **A parent without a block-list reader:** `set:` answers boot the baseline; trials
  fail as never started (004), which the running system reports.
- **The boot partition removed or renamed, or its table damaged in both copies:** the
  baseline, every start.
- **A FAT-form partition under a parent without a FAT driver:** the baseline, every
  start; the installer writes the raw form for such a parent.
- **The GlassineOS slot not bootable in the parent's own slot logic:** the parent's slot
  fallback runs as before; the loader is only started on a start that boots the
  GlassineOS slot.
- **A probe at every start** (`probe=1` left set): one more write of at most 64 KiB per
  start, no other effect.

## Success criteria

- **SC-001** In QEMU with AAVMF, a stand-in parent that starts the loader as handback.md
  says gets the answers of Scenarios 1 to 4 from the records of each, and the loader
  record afterwards has the writes 010 names.
- **SC-002** In the same run, with the loader image missing, its CRC broken, a program in
  its place that returns garbage, one that returns an answer with a wrong CRC, and one
  that names an unknown `boot`: the stand-in parent boots its baseline each time.
- **SC-003** With `probe=1`, the boot partition holds a report whose check passes and
  that lists the graphics output modes QEMU offers and whether a file system was found;
  without it, nothing is written there.
- **SC-004** A host test cuts a raw slot write and a region write at every byte and reads
  the old item, no item or the new one back; a region table damaged at any byte is
  refused, and the backup copy is used.
- **SC-004a** In QEMU, the stand-in parent's cases pass with the raw form, and with the
  FAT form where the firmware offers a file system on the partition; the splash regions
  are byte-identical after a hand-back start.
- **SC-004b** A host test formats a partition and writes the loader and the splash
  regions with `glassine-boot-raw`: the table and the loader header are the bytes the
  loader's own code makes (golden files), the loader's reader (a port) reads every item
  back, and a cut at every byte of every write sequence (the table over nothing and
  over another table, the loader region over none, a larger and a smaller loader, an
  image, the override's removal, the healthy mark's slot) leaves the old item, none or
  the new one; the healthy mark, `display-retry` and the shutdown step on a raw board
  write what the loader reads, also on a baseline start under a parent (`default` and
  `started` empty).
- **SC-004c** A host test runs the loader update on a partition with no table (nothing
  written), with an empty loader region (the loader and the splash written and read
  back by the loader's reader), with the same loader (no block written), with a
  different loader (the new one), and with a write that doesn't read back in the writer
  or after it (exit 1, no loader for the parent); `HANDOFF=uefi`, no `BOOT_FORM` and no
  files write nothing; from the accept step it runs only after a healthy mark it wrote
  and after a candidate's accept.
- **SC-005** On the device, with the person's go and a gate written: a parent build with
  no `glassine-boot` partition on the table boots exactly as before (the floor), and with one,
  Scenarios 1, 3 and 5.

## Out of scope

- The block-list reader in the parent (005, hub#55).
- Writing the boot partition's raw form from the installer, and the partition-table
  change that adds it (the running system's writer is FR-022 to FR-025).
- A gesture at power-on that picks the recovery (`glassine.pick=recovery` is reserved).
- Drawing on displays the firmware can't drive (e-ink) other than through the firmware's
  own refresh (FR-006).
