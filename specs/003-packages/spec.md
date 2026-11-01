# Feature Specification: Packages on a locked root

**Feature branch:** `deploy-0.3-packages`
**Created:** 2026-10-31 · **Status:** built, host-tested, not yet run on hardware
**Builds on:** [001-deployments](../001-deployments/spec.md),
[002-stage-base](../002-stage-base/spec.md) · **Interface:**
[docs/deployments.md](../../docs/deployments.md)

## Summary

The root stays read-only, and `apk` keeps working: a package change makes the root
writable for its own run only. What the user changed is never written down separately:
it is derived on demand from the world file and the installed database against the
base's, which is the input a later base replays. Arbitrary edits need an explicit,
visible unlock.

## User scenarios and testing

### Story 1: install a package on the running system (P1)

1. **Given** a booted deployment, **when** the user runs `apk add PKG`, **then** the
   package installs, lands in the deployment's own layer, and `/` is read-only again
   afterwards; apk's exit code is the command's.
2. **Given** the first package change ever, **then** the user is asked once to
   acknowledge that packages are replayed on a new base and manual edits are not; a
   script without a terminal is refused unless `GLASSINE_APK_ACK=1`.
3. **Given** a read-only apk command (`search`, `info`, `list`…) or a system not booted
   from a deployment, **then** apk-tools runs unchanged.
4. **Given** two package changes at once, **then** the second waits for the first.

### Story 2: edit the system by hand (P2)

1. **Given** `glassine unlock`, **then** `/` stays writable until `glassine lock` or
   the next boot, package changes in between leave it writable, and `glassine status`
   says so.

### Story 3: see what I changed (P1)

1. **Given** a deployment, **when** `glassine-deploy packages` runs, **then** it lists
   world entries added and removed against the base, and packages installed in a newer
   (raised), older (lowered) or other (changed, without apk) version than the base's.

### Story 4: my packages come along to a new base (P1)

1. **Given** packages added or removed on the running deployment, **when** a new base
   is staged, **then** they are replayed into the new deployment's build layer, with
   apk from the new base in a chroot of it, and the running root is untouched.
2. **Given** a package upgraded above the old base's version, **then** the replay
   upgrades it on the new base; a base that already has that version or newer takes
   over.
3. **Given** a package that no longer resolves, or a package whose version would go
   down, **then** stage stops with exit 7, names it, and stages nothing;
   `--without NAME`, `--accept-downgrades` or `--no-replay` decide.
4. **Given** no network, **then** the replay uses the package lists and packages in the
   running deployment's apk cache.
5. **Given** a repository the user added, **then** it comes along with its keys; the old
   base's own repositories do not.

### Story 5: another repository replaces installed packages (P2)

1. **Given** `apk add name@tag` (or `-X`) that would replace installed packages, **then**
   the wrapper lists them and asks; a script without a terminal is refused unless
   `GLASSINE_APK_MIX=1`.

## Requirements

- **FR-001** The wrapper unlocks only for a command line naming `add`, `del`, `fix`,
  `upgrade` or `cache`, holds `RUN_DIR/apk.lock` for the run, and locks again after
  it, also when apk fails or the wrapper is interrupted (INT, TERM, HUP).
- **FR-002** The lists are derived, never stored: `packages` reads the base's and the
  deployment's `/etc/apk/world` and `/lib/apk/db/installed`.
- **FR-003** Busybox only, except `apk version -t` for raised/lowered (`changed`
  without it).
- **FR-004** The replay blocks service starts with an empty `/run` in the chroot: OpenRC
  refuses to start services on a system it did not boot. Package scripts run; only from
  the configured repositories.
- **FR-005** A failed replay leaves no mount, no deployment and no staged state.
- **FR-006** With `/etc/apk/cache` present, the wrapper runs `apk cache clean` after a
  package change, so the cache holds what the system has installed.

## Not in this feature (later)

- Programs that link libapk themselves (a package-manager daemon such as the one
  behind a software centre) bypass the wrapper; how they get the root writable is
  open.
- `glassine diff`, `glassine keep`.
- A17's "keep" answer beyond what still resolves, and setting aside kept files on a
  downgrade (`<file>.glassine-<version>`).
- The deferred upgrade scripts of the switch (A22 step 3).
- A change after staging is not in the staged deployment: the wrapper says so; stage
  again to include it.

## Success criteria

- **SC-001** `make check` passes with a check per acceptance scenario.
- **SC-002** On hardware: `apk add` of a small package on the running deployment
  succeeds, `/` is read-only after it, `glassine-deploy packages` lists it as added.
