# GlassineOS/boot Constitution

This repository follows the GlassineOS organization principles (I–VIII). They come from
the `glassine` Spec Kit preset in `GlassineOS/.github` and are not edited per
repository. Repository-specific principles go in the last section.

## Organization principles

### I. Honest framing

GlassineOS is a hobby project, written largely with AI coding agents and not reviewed by
subsystem experts. Every README says so. Specs, plans and commit messages state what was
verified and how (host test, emulator, which device and date), and say "untested" where
it applies.

### II. Safety before features

Anything that flashes, partitions, touches the bootloader, recovery, updates or user data
states its failure mode and its escape route before it is implemented. If the escape route
depends on what the change could break, the change needs explicit maintainer approval.
Device-affecting steps never run without the maintainer's go.

### III. Nothing vendor-owned, nothing personal

No vendor firmware or binaries, device dumps, decompiler output, keys, serial numbers, MAC
addresses or local paths in any repository. Firmware comes from the user's own device at
install time. The safety scan must pass.

### IV. Contracts are owned and versioned

Every interface between repositories (protocols, file formats, configuration, D-Bus or
socket APIs) has one owning repository that specifies and versions it. Consumers pin the
version they support and adopt new versions through their own spec. Breaking changes
bump the major version.

### V. Test at the right level

Libraries and daemons test their own behaviour in their own repository (host tests, no
device needed where possible). End-to-end behaviour of the assembled system is specified
and tested only as product acceptance in the `images` repository, as high-level
behavioural scenarios on hardware, never repeating library unit tests.

### VI. Device-neutral by default

No device constants outside device packages and device configuration. Code reads device
facts from configuration so a second device needs no changes outside its own packages.

### VII. E-ink first

Every user-facing change considers refresh cost, ghosting and latency on e-ink. Animations
and continuous redraws need a reason. Latency or power trade-offs are checked by feel on
the device, not by benchmark alone.

### VIII. Upstream and licenses

Our code is GPL-2.0-or-later unless the repository says otherwise; fork commits use the
upstream license. Nothing is submitted upstream unsolicited. AI-assisted commits carry an
`Assisted-by:` or `Co-Authored-By:` trailer; agents never add `Signed-off-by`.

## Repository principles

### Contracts

- **Owned:** the `glassine-deploy` command interface (commands, `--porcelain` output,
  exit codes) and the `state/` format, both at format version 1, defined in
  `docs/deployments.md`. A change an old reader would misread raises the version; added
  keys an old reader can ignore don't. A tool refuses state newer than it knows (exit 3).
- **Owned:** `conf/board.conf` keys and the initramfs boot steps (`docs/boot.md`).
- **Consumed:** `/etc/glassine/deploy.conf` and `board.conf` from the device package;
  the kernel (btrfs, overlayfs) from `GlassineOS/linux`.

### Tests

Every change runs `make check` (host tests in Docker, real btrfs, ext4 and overlayfs on
the host kernel) and extends the tests for new behaviour. A change to a write path needs
a test of its failure case (cut write, read-back mismatch) before it merges.
`docs/testing.md` says what each test proves and what only hardware can show; nothing is
called hardware-proven without a device run.

### Releases and hardware

SemVer tags (`v0.x` until the deployments layout has run on hardware). These tools write
boot and system partitions; device runs happen outside this repository and are recorded
in `docs/testing.md`. `glassine.devmode=usb` is never on by default.
<!-- What is specific to this repository: its contracts (owned and consumed, with
     versions), its test strategy, its release cycle, hardware it may touch. -->

## Governance

The organization principles change only in `GlassineOS/.github` (preset version bump);
repositories pick changes up through their `.glassine/org` submodule. Repository
principles change by pull request in this repository. Cross-repository decisions are
recorded as decision records in `GlassineOS/docs`.

**Version**: 1.0.0 | **Ratified**: 2026-10-29 | **Last Amended**: 2026-10-29
