# Feature Specification: The GlassineOS recovery

**Feature branch:** `recovery`
**Status:** spec, for review; nothing built
**Builds on:** [001-deployments](../001-deployments/spec.md),
[006-device-data-storage-access](../006-device-data-storage-access/spec.md) · **Interfaces:**
[docs/deployments.md](../../docs/deployments.md) (`glassine-deploy`, resets),
GlassineOS/images `docs/ramenv.md` (the USB protocol), installer
[001](https://github.com/GlassineOS/installer/blob/main/specs/001-install-from-stock/spec.md) and
[002](https://github.com/GlassineOS/installer/blob/main/specs/002-device-description/spec.md) ·
**Decision:** [docs 0007](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0007-recovery-mainline-twrp.md)

## Summary

The GlassineOS recovery is one program, the same on every machine. It starts when
GlassineOS doesn't start (or the person asks for it), runs from memory, and repairs
GlassineOS with the same tools the running system uses (`glassine-deploy`): pick another
deployment, roll back, reset, repair the boot, collect what went wrong.

Its core runs without a screen. Three clients reach it: the installer over USB, a
console, and the touch screen. The USB interface is the RAM environment's protocol, so
the installer reads a whole device for its backup and writes an installation through the
recovery the same way it does through the RAM environment. On a device, the recovery is
what the installer leaves in the recovery partition; an installation is complete only
with it.

A machine that keeps a second system can hand over to that system's own recovery
(stock Android: TWRP), which then owns that system's work.

## User scenarios

### Scenario 1 – GlassineOS doesn't start (P1)

**Given** a deployment that fails to start (the boot's tries run out, or the person asks
for the recovery at start-up),
**When** the recovery starts,
**Then** it shows the deployments with which one failed and which one last started, and
the person picks the last good one (or rolls back) in one step; the next start uses it,
and nothing else changed.

### Scenario 2 – The installer repairs or reinstalls (P1)

**Given** a device in its recovery, connected to a computer,
**When** the installer connects,
**Then** it identifies the device and reads its disks for a backup, and, after the person
confirmed a plan on the computer, writes what the plan names. The recovery writes
nothing it wasn't asked to, and only into the ranges the installer named for that
session.

### Scenario 3 – Reset (P1)

**Given** a person who wants a clean system,
**When** they choose a reset and confirm it,
**Then** the reset is the one `glassine-deploy` offers (both levels), with the same
consequences it states; the person's storage is kept unless the full reset says
otherwise and the person confirmed exactly that.

### Scenario 4 – Diagnostics (P2)

**Given** a device that starts badly,
**When** the person or the installer asks for diagnostics,
**Then** the recovery collects the last start's logs, the kernel's crash log, the
deployment state and the device's identity into one file, readable on the computer over
USB, without writing the system's partitions.

### Scenario 5 – Hand-over to the other system's recovery (P2)

**Given** a machine whose description says another system's recovery is reachable,
**When** the person asks for it,
**Then** the recovery hands over and says what that recovery is for; on a machine
without one, the choice isn't offered.

### Scenario 6 – Nobody is there (P1)

**Given** the recovery started and nobody uses it,
**When** a time passes with no input from any client,
**Then** it restarts into the last good deployment without changing anything; a hang
of the device ends in a hardware reset.

## Requirements

### Start and identity

- **FR-001**: The recovery starts from memory: nothing of it is mounted read-write from
  the device's disks while it runs, and it needs no file from the installed system.
- **FR-002**: It starts on request from the running system (`reboot recovery`), from the
  boot loader's own way in where the device has one, and when the boot's tries run out
  where the boot loader falls back to it.
- **FR-003**: It identifies itself to every client with its version, the machine's
  identity, and the deployment state.

### Clients

- **FR-004**: The core holds every operation; a client only asks for one and shows the
  answer. The touch screen, the console and USB offer the same operations, with the same
  confirmations.
- **FR-005**: The USB interface is the RAM environment's protocol (read, hash, write in
  armed ranges, restart), plus operations for deployments, resets and diagnostics, so
  one installer client serves both.
- **FR-006**: The screen is readable on e-ink and reachable without a keyboard: the
  touch screen and the power key are enough.

### Operations

- **FR-007**: Deployments: list (with the last good and the failed one), select, pin,
  roll back, remove; each is `glassine-deploy`'s operation, with its checks.
- **FR-008**: Resets: both levels `glassine-deploy` defines, each confirmed by name.
- **FR-009**: Repair the boot: rewrite the boot partition from the selected
  deployment's kernel record and reset the slot flags the device's description names.
- **FR-010**: Diagnostics as in Scenario 4.
- **FR-011**: Writes from USB: only after the installer arms ranges for the session;
  outside them, every disk stays read-only; the device's boot areas are never written.

### Safety

- **FR-012**: An operation that can lose data names what it loses and needs a
  confirmation on the client that asked for it.
- **FR-013**: A watchdog resets the device when the recovery stops answering; it restarts
  into the last good deployment after a time with no client input.
- **FR-014**: The recovery's kernel is built from the system's kernel source with its own
  minimal configuration (storage, USB, display, touch, power key, battery, watchdog,
  crash log, dm-crypt, btrfs) and needs no vendor firmware.
- **FR-015**: It never holds a secret of the person's beyond the operation that needs it
  (an unlock of encrypted storage ends with that operation).

## Key entities

- **The recovery image**: the kernel and the program, as one image the device's boot
  path starts; versioned, with its own record.
- **A client session**: one client's connection, its armed ranges (USB), its
  confirmations.
- **The diagnostics file**: logs, crash log, state, identity, with checksums.

## Success criteria

- **SC-001**: A device whose current deployment fails is back on a working one in under
  two minutes, with no computer.
- **SC-002**: Over USB, the installer's backup and write tests pass against the recovery
  unchanged from the RAM environment.
- **SC-003**: Every data-losing operation, run from each client, shows its consequence
  and waits for its confirmation (tested per client).
- **SC-004**: Left alone, the recovery is back in the last good deployment within its
  idle time, with every disk unchanged.

## Assumptions

- `glassine-deploy` and its formats stay `boot`'s; the recovery adds no second interface.
- The RAM environment and the recovery share the USB daemon; the RAM environment is the
  recovery without its screen, deployments and resets.
- On a device with one recovery partition, the recovery takes it; such a device keeps
  no second recovery.
