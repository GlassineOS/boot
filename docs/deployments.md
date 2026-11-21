# Deployments: on-disk format and the `glassine-deploy` interface

This page owns the interface. Consumers (the recovery's menu, packages, the image
builder) link here and do not copy it. The design behind it is in the GlassineOS docs:
[Root file system and deployments](https://docs.glassine.org/architecture/root-and-deployments/).

Status: built and host-tested (`make check`, see [testing.md](testing.md)); **not yet
run on hardware**.

## Terms

| Term | Meaning |
|---|---|
| system partition | The partition named by `SYSTEM_DEV` btrfs. Holds the read-only bases, the kernel modules and `state/`. |
| userdata | The partition named by `USERDATA_DEV`, ext4. Holds the deployments under `USERDATA_PREFIX`, the hibernate swap file, and the person's storage (home and Flatpak's system data), outside the deployments. |
| base | A read-only btrfs subvolume with a complete system (`bases/<id>/`). |
| deployment | One bootable root: a base plus its own layers on userdata (`deployments/<id>/`). |
| current | The deployment that boots normally. |
| candidate | A deployment under test: it boots instead of current while it has tries left. |
| previous | The deployment that was current before the last accept. |
| staged | A deployment that is prepared but not yet selected: the next switch carries state into it and makes it the candidate. |
| failed | The last candidate that ran out of tries or did not assemble (`state/deploy` `failed=`). |
| kept | Any other deployment. Nothing boots it; the next clean-up removes it ([Clean-up](#clean-up)). |

## On-disk layout

```
system partition (btrfs, top level)
├── bases/<base-id>/            read-only subvolume, one per base
├── modules/<kernel-release>/   read-only subvolume, bound on /lib/modules/<release>
└── state/
    ├── format                  version=<N>
    ├── deploy                  the deployment state (below)
    ├── kernel                  current=, previous= (kernel releases)
    ├── install                 the install marker: present until the first start is done
    └── .lock                   flock target; never contains data

userdata (ext4) under USERDATA_PREFIX (default media/glassine)
├── home/                       /home of every deployment (below), root:root 0755
├── flatpak/                    /var/lib/flatpak of every deployment, root:root 0755
├── devmode/                    the developer folder, root:root 0700: authorized_keys and
│                               the SSH host keys (README, "Developer mode")
├── deployments/<id>/
│   ├── meta                    key=value (below)
│   ├── build/                  the layer built for this deployment; read-only once it exists
│   ├── switch/                 the switch layer, then the live upper: every write of the
│   │                           running deployment lands here
│   └── work/                   overlayfs work directory
├── deployments.removing/<id>/  a deployment being removed (below); never a deployment
└── swap/
    ├── hibernate               the hibernate swap file
    └── hibernate.guard         written right before a hibernate (below)
```

The merged root of a deployment is the overlay
`lowerdir=build:bases/<base>, upperdir=switch, workdir=work`.

Locked (the default): `/` is a read-only bind of that overlay, and `/etc`, `/var`,
`/usr/local`, `/opt` are read-write binds of its own directories. So writes there go
through the overlay (copy-up, whiteouts), and the base never changes. The base's
`/etc/fstab` must list `/` with `bind,ro` ([boot.md](boot.md#deployments-layout)), or the
init system remounts it read-write.

### The person's storage

Home (`/home`) and Flatpak's system data (`/var/lib/flatpak`) are the directories
`home/` and `flatpak/` under `USERDATA_PREFIX`, outside the deployments, so every
deployment sees the same files and no reset touches them (`reset` and `reset --full`
keep them; no base or migrate list carries them). The same holds for the developer
folder `devmode/` (`root:root`, `0700`), which `glassine-devmode` reads and makes on its
first start with `glassine.devmode=usb` (README, "Developer mode"); nothing binds it.

- **Who binds them:** the initramfs, while it assembles the booted deployment's root
  (`gr_storage` in `lib/glassine-root.sh`, from `gr_boot`), before `switch_root`, so they
  are there before any service starts. `glassine-deploy`'s views of a deployment (the
  switch's carry, the package replay) never get them. Each directory is created on first
  use, `root:root`, `0755`.
- **What they hide:** files a deployment already holds in its own `/home` or
  `/var/lib/flatpak` are hidden by the bind, never moved or deleted. `status` reports a
  non-empty hidden directory (`home_hidden=yes`), read from the merged root without the
  binds (`/run/glassine/root`).
- **Failure:** a directory that can't be created, or a bind that fails, is logged; the
  boot goes on with the deployment's own directory in its place, nothing is written
  into the userdata directory, `status` reports it (`home=failed`, `home_error=…`), and
  the next boot tries again.
- **A bare boot** binds nothing from userdata: it keeps nothing, as before. An initramfs
  from before this (after a boot-image rollback) boots deployments with their own
  directories, and loses nothing on userdata.
- **`/var/tmp`** is a bind of itself made shared (on every boot of this layout, bare
  ones too), so the mount namespaces Flatpak makes from it see mounts made under it
  later. Its files stay in the deployment's `/var`.

The plain layout is unchanged.

## State files

All state files are `key=value`, one per line. The first match wins, and a missing key
is empty. Every write replaces the whole file atomically: a temp file in the same
directory, data synced, a rename, and a sync (`gs_write` in `lib/glassine-state.sh`).
Every writer takes `state/.lock` first (`flock -n`; busy = exit 6).

### `state/format`

`version=1`. A tool refuses to write a format newer than the one it supports. It still
reads the format and prints both numbers. **Compatibility rule:** a change that an older
reader would misread raises the version. Adding a key that older readers can ignore does
not.

### `state/deploy`

| Key | Value |
|---|---|
| `current` | deployment id, or empty |
| `previous` | deployment id, or empty |
| `candidate` | deployment id, or empty |
| `tries` | boots the candidate has left (0–2) |
| `staged` | deployment id waiting for the next switch, or empty |
| `failed` | the last candidate that ran out of tries or did not assemble |

How the boot picks (`gr_pick`):

1. A candidate (different from current) with tries left uses one try and boots.
2. A candidate with no tries left gets `failed=<id>`, the candidate is cleared, and
   current boots.
3. With no current, previous boots.
4. A deployment that does not assemble is skipped (a candidate is marked failed): next
   current, then previous, then a bare boot.

A staged deployment never boots.

### `state/install`

The install marker, `key=value`. `glassine-deploy init --install-marker` writes it into
a pool an installer will write to a device; [the first start](#the-first-start) acts on
it and removes it.

| Key | Value |
|---|---|
| `format` | `1` |
| `created` | UTC time of the `init` |
| `userdata` | the UUID of the userdata the first start formatted; set by the first start once the format is complete |

### `deployments/<id>/meta`

| Key | Value |
|---|---|
| `base` | the base id (required) |
| `kind` | `install` (`stage` with no current deployment: the first deployment), `reset`, `reset-full`, `update` (`stage`) |
| `carry` | `migrate` (the switch carries the migrate list) or `none` |
| `from` | the deployment it was made from |
| `created` | UTC time |
| `failed` | `1` once it failed (alternative to `state/deploy` `failed=`) |

Deployment ids match `[A-Za-z0-9._-]+` and never start with a dot. New ids are the UTC
time `YYYYMMDD-HHMMSS`, with a `-N` suffix if that one is taken.

### The hibernate guard

`swap/hibernate.guard`, `key=value`, written by the hibernate step with `gs_write`
before `echo disk`. Write the two userdata lines with `gs_guard_mounts`: it prints the
time in UTC and the C locale, so the running system and the initramfs see the same
string.

| Key | Value |
|---|---|
| `mount_count` | userdata's ext4 "Mount count" at the hibernate |
| `last_mount` | userdata's ext4 "Last mount time" at the hibernate |
| `deployment` | the running deployment (`/run/glassine/booted`) |
| `krel` | `uname -r` |
| `kver` | `uname -v` (the build string; arm64 resumes only into the same build) |

A missing key counts as a mismatch, and a mismatch means no resume. The rules are in
[boot.md](boot.md#hibernation).

### Migrate lists

`/usr/share/glassine/migrate.list` (shipped with the base),
`/usr/share/glassine/migrate.d/*.list` (each package names its own state there: its
settings in `/etc`, what it keeps in `/var/lib`; read from the running deployment and
from the new base, so a package new in the update counts too) and
`/etc/glassine/migrate.d/*.list` (the user's own). One absolute path per line. A
trailing `/` means a directory. `#` comments and blank lines are ignored, and so are
lines that are not absolute or that contain `..`. A switch copies each listed path from
the old deployment into the new one's switch layer, keeping modes and owners (`cp -a`;
parent directories get the source's mode and owner).

## `glassine-deploy`

```
glassine-deploy status [--porcelain] [--no-restart]
glassine-deploy list [--porcelain]
glassine-deploy select ID [--yes] [--discard-hibernation] [--restart]
glassine-deploy rollback [--yes] [--discard-hibernation] [--restart]
glassine-deploy hibernate-invalidate [--yes]
glassine-deploy reset [--full] [--now] [--yes] [--discard-hibernation] [--restart]
glassine-deploy stage BASE [--no-replay] [--without NAME]… [--accept-downgrades] [--now] [--yes] [--discard-hibernation] [--restart]
glassine-deploy restart [--check [--porcelain] | --soft | --cold] [--once ID]
glassine-deploy receive FILE|- [--modules] [--sha256 HEX] [--discard-hibernation]
glassine-deploy receive FILE --boot [--sha256 HEX] [--discard-hibernation]
glassine-deploy bases [--porcelain]
glassine-deploy bases remove BASE [--yes] [--discard-hibernation]
glassine-deploy remove ID [--yes] [--discard-hibernation]
glassine-deploy packages [ID] [--porcelain]
glassine-deploy switch [--discard-hibernation]
glassine-deploy accept ID
glassine-deploy publish
glassine-deploy init POOL_MOUNT [--install-marker]
```

| Command | Does |
|---|---|
| `status` | format (state and supported), the system file system, current/previous/candidate/staged/tries, the kernels, `hibernated=yes\|no\|unknown`, `twrp_keep`, the person's storage as this boot left it (`home`, `flatpak`: `bound`, `failed` with `<name>_error`, or empty on a bare boot or outside a deployments boot; `<name>_hidden`; `vartmp`: `shared` or `failed`), what a restart now would be (`restart=soft\|cold`, `restart_reason=`; without the switch's space check, which only `restart --check` makes) and how this start came (`last_start=cold\|soft`, [Restart](#restart)). `--no-restart` leaves out `restart` and `restart_reason`, which read the loader record: the shutdown switch and the boot-success step need only the state |
| `list` | one record per deployment: id, state (`current`, `candidate`, `staged`, `previous`, `failed`, `kept`), base, kernel, created, size |
| `select ID` | ID becomes the candidate with 2 tries; selecting current cancels a candidate. Never makes an untried deployment current. |
| `rollback` | `select` previous |
| `hibernate-invalidate` | turns a hibernate image back into a plain swap file (that session is lost) |
| `reset` | stages a new, empty deployment on current's base (`carry=migrate`; `--full`: `carry=none`). A new reset replaces a staged one. `--now` switches at once (for the recovery). Neither touches home, Flatpak's data or the developer folder (`home/`, `flatpak/`, `devmode/` above). |
| `stage BASE` | like `reset`, on another base under `bases/` (a base update): `kind=update`, `carry=migrate`. Refuses a base that is not there or has no `/etc/passwd`. Before the replay it checks the free space on userdata (below); too little is exit 5, nothing staged. With no current deployment (the first start, or after userdata was formatted) it stages the first deployment: only with `--no-replay` (refused otherwise), `kind=install`, `carry=none`. |
| `stage BASE` flags | `--no-replay` the bare base, `--without NAME` (repeatable) leaves NAME's change out (an added package, or the removal of the base's entry when the user changed it), `--accept-downgrades` takes lower versions (below the running deployment's or below the new base's). Exit 7: the replay needs one of these; nothing staged. An exact pin (`name=version`) that the new base has or exceeds is not replayed: the base's version and its own entry take over (said). |
| `receive FILE\|-` | `btrfs receive` of a send stream (full, or incremental onto a received base; `.zst` decompressed by its name) into `bases/` (`--modules`: `modules/`). Kept only if it is one read-only subvolume with a received UUID and a valid name; a cut stream, a name that exists or a missing parent leaves nothing. `--sha256` checks the file first. Into `bases/` it makes room by itself ([Unused bases](#unused-bases)); a stream that still doesn't fit is exit 5, with the space needed and free. Needs btrfs-progs (and zstd for `.zst`), see [Tools](#tools-each-command-needs). |
| `receive FILE --boot` | a device tree (`<device>@<id>.dtb`) or an initramfs (`<commit12>@<id>.cpio.gz`) with its manifest beside it into `boot/dtb/` or `boot/initramfs/`, its identity checked, written power-cut safe; an existing name with the same bytes is a no-op, with other bytes refused ([kernel-artifacts.md](kernel-artifacts.md#on-the-system-partition)). No btrfs-progs needed. |
| `packages [ID]` | how a deployment's packages (current by default) differ from its base's, derived each time (no bookkeeping): world entries `added` and `removed` (constraints and tags as written), packages installed in another version: `raised`/`lowered` (`apk version -t`; `changed` where apk is missing). A deployment that is not running needs userdata mounted. The replay input of a later base. |
| `bases` | one record per subvolume under `bases/` and `modules/`, with the deployments whose meta names it |
| `bases remove BASE` | deletes the subvolume and waits until its space is back. For a base some deployment still uses; the unused ones go by themselves ([Unused bases](#unused-bases)). Refuses the base of the booted, current, candidate or staged deployment. Other deployments on it stay on userdata but can no longer be selected (`list` shows `base_present=no`); it asks first (`--yes`), naming them and a lost rollback. Then it removes the `boot/` files no kernel record names ([kernel-artifacts.md](kernel-artifacts.md#on-the-system-partition)). Modules are not removed. |
| `switch` | for a staged deployment: clears its switch layer, carries the migrate list from current (unless `carry=none`), merges the accounts (below), syncs, then sets `candidate=<id> tries=2 staged=`, then the clean-up and the unused bases. Interrupted = nothing selected, redone in full next time. |
| `publish` | the loader record's deployment list (`deploys`, `deployN`: previous, candidate, failed, kept; boot-partition.md) written through `glassine-loader-mark deploys` where the board has a loader record, only when it differs. Run by every command that changes the deployments (select, switch, accept, remove, stage) and by the boot-success service on a start that accepts nothing; never fails the command. |
| `accept ID` | the boot-success service's step: the booted candidate becomes current, the old current becomes previous, then the clean-up and the unused bases (where userdata is mounted already). Refuses a non-candidate; accepting current is a no-op. |
| `init POOL_MOUNT` | lays out an empty btrfs that the caller made and mounted (the image builder, for the pool image an installer writes to the system partition): `bases/`, `modules/`, `state/` with `deploy` and `kernel` naming nothing, `.lock`; `--install-marker` adds `state/install`. `state/format` is written last, so a cut `init` reads as not migrated. Refuses a path that is not a mount point, a file system other than btrfs, a subvolume mount (not the top level) and a pool that is not empty. Needs no `deploy.conf` (`GLASSINE_DEPLOY_CONF=/dev/null` on a build host) and no btrfs-progs. The caller then receives the base and the kernel's modules into it. |
| `restart` | restarts: soft where the rules allow, else cold ([Restart](#restart)). `--check` reports which and why, writing nothing (exit 0 soft, 9 cold); `--soft` restarts only soft (exit 9 otherwise, nothing stopped); `--cold` always cold; `--once ID` starts ID for the incoming session only, by a soft restart. `--restart` on `select`, `rollback`, `reset` and `stage`: the command, then `restart`. |
| `remove ID` | deletes a deployment's layers from userdata, the way the clean-up does. Refuses the current, candidate, staged and booted deployment and a mounted one. The previous one: asks first (`--yes`), naming the lost rollback, and clears `previous=`; the last failed one: clears `failed=`. Then the unused bases. |

Where it reads and writes:

- It mounts the partitions itself (`SYSTEM_MNT`, `USERDATA_MNT`) and unmounts what it
  mounted. When userdata is already mounted somewhere else (a recovery's `/data`), it
  uses that mount. It never writes the raw device under a mounted file system.
- Reading while userdata is not mounted uses `debugfs` (no mount, no journal replay). The
  system partition is mounted `ro,rescue=nologreplay` for reading.
- No `e2fsck` of userdata in a system booted by the deployments initramfs, because
  userdata is in use behind the overlay there.

### Clean-up

Each deployment's layers take room on userdata, so deployments that nothing will boot
are removed by themselves:

- **When:** after a `switch` has set the candidate, after an `accept`, and before
  `reset` or `stage` makes a new deployment. Each point keeps everything the boot can
  fall back to (candidate, then current, then previous). A clean-up that fails is
  logged and never fails the command that ran it.
- **What stays:** current, previous, candidate, staged, the last failed one
  (`failed=`, for a look at what went wrong; an older failed one goes once a newer
  candidate fails) and the booted one (`/run/glassine/booted`). Every other
  deployment (`kept` in `list`) is removed.
- **Never:** a deployment that is mounted: a mount point in its directory, or an
  overlay with one of its layers (`/proc/self/mountinfo`). It stays `kept` until a
  later clean-up finds it unmounted. Nothing at all while the current deployment is
  not on userdata (an unreadable state or another userdata).
- **How:** the deployment's directory is renamed to `deployments.removing/<id>` (one
  step; from then on it is no deployment), then deleted. A cut delete leaves the rest
  there; the next clean-up or `remove` deletes it first. `remove` writes the state
  (`previous=`, `failed=`) before the rename, so the state never names a deployment
  that is gone.

**Free space for a replay.** `stage` with a replay needs the room for the user's
packages in the new build layer. Before it makes anything (and after the clean-up), it
compares userdata's free space with an estimate: what the current deployment's build
layer and the package directories of its switch layer (`/usr`, `/lib`, `/bin`,
`/sbin`, `/opt`) take, a quarter more for the downloads, and 16 MiB. Less is exit 5,
nothing staged. It is an estimate: a replay that still runs out of space removes what
it made.

**Hibernation gate.** A command that writes refuses (exit 4) while userdata holds a
hibernated session. With `--discard-hibernation` it asks first (`--yes` skips the
question), cancels the image, then goes on. Mounting either partition read-write would
make that session unsafe to resume.

**Running system vs. recovery.** In the running deployment
(`/run/glassine/booted` = current), `switch` reads a plain bind of the running `/`. In
a recovery it reads a read-only overlay of current's layers.

**Account merge** (every switch that carries; `lib/glassine-accounts.sh`): the new
deployment's `/etc/passwd`, `group` and `shadow` are its own lower's (build layer,
else base) plus, from current: users and groups with IDs 1000–65533 the new side
lacks (same ID when free, else the next free one from 1000; a kept user's primary
group follows by name), every password by name, group memberships of users that
exist afterwards, `subuid`/`subgid` ranges by name. They replace any carried copy.
`shadow` keeps the base's owner and mode. Carried files owned by an ID that moved
(same name, other ID, e.g. a system account renumbered by a new base) get the new
owner, modes kept. Accounts the new base has no row for are not carried; the switch
lists them.

### Unused bases

The system partition holds one base as received and the room for a few updates
(installer spec 002 FR-019a), so a base no deployment uses goes by itself:

- **When:** after a `switch` has set the candidate, after an `accept` (where userdata is
  mounted), after a `remove`, and after `reset` or `stage` has staged its deployment
  (`--now`: after the switch), each time after the clean-up of deployments; and in
  `receive` into `bases/` when the stream doesn't fit (below).
- **What stays:** every base that the meta of a deployment on userdata names, so the
  bases of the booted, current, previous, candidate, staged and last failed deployments
  and of any deployment the clean-up left (a mounted one). How many bases stay follows
  from the deployments; there is no separate number. A base that is mounted stays too.
  Modules are not removed. A received base that no deployment uses yet goes at the
  next of these points: stage it right after the receive.
- **Never:** nothing at all while the current deployment's meta can't be read or a
  deployment's meta names no base (unreadable must not read as unused), or while
  userdata may hold a hibernated session whose deployment's base can't be told; a
  hibernated session's base is kept and said. The command itself has passed the
  hibernation gate before (above), so a hibernate image is never discarded for a base.
- **How:** as `bases remove`: the subvolume is deleted, then the command waits until its
  space is back, then it removes the `boot/` files no kernel record names. One line per
  base, on stdout and in the kernel log (`glassine-deploy: base <name> removed: no
  deployment uses it`). It never fails the command that ran it; without btrfs-progs it
  does nothing.

**Room for a receive.** A stream from a file that is larger than the system partition's
free space (its size; for `.zst` the compressed size, a lower bound) makes `receive`
remove the unused bases first, all but the stream's parent (an incremental stream's
first command names it). A `btrfs receive` that runs out of space anyway removes what it
received, removes the unused bases (when it hadn't yet) and receives the stream once
more. A stream that still doesn't fit is exit 5: "not enough space on the system
partition", with the space needed (at least the stream's size) and free, nothing kept.
A stream on stdin can't be read twice: out of space is exit 5 with nothing removed.

## The root lock and the apk wrapper: `glassine`

```
glassine status | unlock | lock
glassine apk [APK ARGUMENTS…]      (also installed as /usr/sbin/apk)
```

In a system booted from a deployment (`/run/glassine/booted`), `/` is a read-only
bind; `/etc`, `/var`, `/usr/local`, `/opt` stay writable. `unlock` makes `/` writable
until `lock` or the next boot (marker `RUN_DIR/unlocked`); such edits stay in the
deployment but are not carried to a new base. `glassine apk` runs apk-tools
(`GLASSINE_APK`, default `/sbin/apk`, which `/usr/sbin/apk` precedes on PATH): a
command line with `add`, `del`, `fix`, `upgrade` or `cache` takes `RUN_DIR/apk.lock`
(a second one waits), makes `/` writable for that run and read-only again after it
(left writable when unlocked by hand). The first change asks once to acknowledge that
packages are replayed and manual edits are not (`/etc/glassine/apk-acknowledged`;
`GLASSINE_APK_ACK=1` for scripts, refused without a terminal otherwise). Other apk
commands, and every command outside a deployment, run apk-tools unchanged. Programs
that link libapk themselves (e.g. a package-manager daemon) do not go through it.

`apk update` changes no package but takes apk's lock under `/`, so it opens `/` too, without
the acknowledgement. A package from another repository (`name@tag`, `-X`) that would replace
installed ones is listed first and asked about (`GLASSINE_APK_MIX=1` for scripts). With
`/etc/apk/cache` present, packages stay in the cache and the wrapper cleans it after each
change; the replay uses that cache, so a base staged offline still gets the packages this
system has. After a change, it says when a staged deployment does not include it.

### Porcelain (format 1)

`--porcelain` prints `glassine-deploy 1` on the first line, then one record per line.
Records are tab-separated `key=value` fields, and the first field is `type=<record>`.
Keys may be added within a version, so readers ignore keys they don't know.

```
glassine-deploy 1
type=status	format=1	supported=1	system_fs=btrfs	migrated=yes	current=…	previous=…	candidate=…	staged=…	failed=…	tries=…	kernel_current=…	kernel_previous=…	hibernated=no	userdata_prefix=media/glassine	twrp_keep=yes	home=bound	home_hidden=no	flatpak=bound	flatpak_hidden=no	vartmp=shared	restart=soft	restart_reason=	last_start=cold	swapfile=…	guard=…
```

```
glassine-deploy 1
type=restart	restart=cold	restart_reason=not-healthy	restart_target=…	switch=no	switch_reason=nothing-staged
```

```
glassine-deploy 1
type=deployment	id=…	state=current	base=…	base_present=yes	version=…	kernel=…	created=…	size_kib=…
```

```
glassine-deploy 1
type=base	kind=base	name=…	used_by=<id>,<id>
type=base	kind=module	name=7.3.0-…	used_by=
```

```
glassine-deploy 1
type=package	change=added	entry=retroarch
type=package	change=raised	name=musl	version=1.2.5-r11	base_version=1.2.5-r10
```

`state` is one of current, candidate, staged, failed, previous, kept (the first that
applies, so a failed deployment that is also previous shows failed). A `kept` one is
there only until the next clean-up (one that was mounted, or left by an older tool). `base_present` is
`yes` when the deployment's base is a subvolume under the system partition's `bases/`,
`no` when it is not, empty when the system partition is not readable or the meta names
no base. `version` is the base's version: the image version of its base manifest
(`version` of `usr/share/glassine/base.manifest`, [kernel-artifacts.md](kernel-artifacts.md)),
else `VERSION_ID` of the base's `usr/lib/os-release` (else its `etc/os-release` when
that is a file, not a link), whichever comes first as only letters, digits and `._+~-`,
at most 32 characters; empty when the base is not there or holds none.
`status`'s `failed` is the last deployment that ran out of tries.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | error (message on stderr) |
| 2 | usage |
| 3 | the state format is newer than this tool (every command refuses; `status` still prints both versions) |
| 4 | a hibernated session on userdata, refused |
| 5 | not enough space: on userdata (`switch`: the deployment stays staged; `stage`: nothing staged), or on the system partition (`receive`: nothing kept) |
| 6 | busy (another writer holds the lock) |
| 7 | `stage`: the package replay stops: a package does not install or upgrade on the new base, or a version would go down (see `stage BASE` flags); nothing staged |
| 8 | `select`, `stage`, `reset`: a kernel candidate is set (`glassine-bootimg cancel` drops it; `rollback` and `reset --now` cancel it themselves); `restart --once ID`: the running kernel doesn't cover ID |
| 9 | `restart`: the restart would not be soft (`--check`), or `--soft`/`--once` refused for that reason; nothing stopped |

## Restart

`glassine-deploy restart` ends the session and starts the next one. **Soft** where the
rules below allow: PID 1 re-enters the kept initramfs assembly, which mounts, picks and
assembles as a cold start does and hands over to the new root's init, without the
firmware, the loader or a kernel start ([boot.md](boot.md#the-soft-start)). Otherwise
**cold**: the user's ordinary reboot. Both end the same way: a staged deployment is
switched by the shutdown (with the switch's own rules), the next start is the pick's,
and the incoming session sees the same state files and runtime keys a cold start would
leave (`kind=` in `/run/glassine/restart` aside).

The restart is cold, with this reason (`restart_reason`, first that applies), when:

| Reason | |
|---|---|
| `off` | `SOFT_RESTART=no` |
| `plain` | not a deployments boot, or userdata isn't mounted |
| `bare` | the running session is a bare boot |
| `first-start` | the first start hasn't finished (`state/install`) |
| `test-role`, `kernel-trial`, `bare`, `no-assembly` | this kernel run left no kept assembly (`kept.none`) |
| `kernel-trial` | the running start is a kernel trial or a finishing boot |
| `kernel` | the kernel step is writing an image |
| `kernel-candidate` | a kernel candidate waits for its test |
| `no-target` | no deployment the pick would start (the pick's, then current, then previous) has its meta and base |
| `modules`, `not-covered` | the running kernel has no modules subvolume, or doesn't provide what that deployment's base needs |
| `not-healthy` | this session hasn't reached its health conditions (no `/run/glassine/healthy`) |
| `loader-request`, `loader-default`, `loader-unreadable` | the loader has a request for the next start, a default other than the running kernel, or its record can't be read |
| `init` | PID 1 isn't busybox init with the `::restart:` line, or the launcher is missing |

A switch that the restart's shutdown will make counts too: the target is then the
staged deployment. `switch=yes|no` with `switch_reason` (`nothing-staged`, `once`,
`kernel-candidate`, `battery`, `space`) says whether it will. A soft restart that the
switch's space check would stop is refused (exit 5), the deployment stays staged.

- `--check` prints the decision (`type=restart` record) and writes nothing.
- `--once ID` starts ID for the incoming session only, as `glassine.deploy.once=` does
  at a cold start; refused (nothing stopped) for an id that isn't a deployment id (2), a
  deployment that isn't there or is staged or whose base is missing (1), and one the
  running kernel doesn't cover (8); `--cold --once` is a usage error.
- The hibernate step refuses while `restarting` exists (exit 4).
- If PID 1 doesn't begin within `RESTART_INIT_S` seconds, `restart` reboots cold and
  leaves `init` as the next session's `cold_reason`.
- A step of the soft start that fails turns it cold the same way, with the step's
  word (`processes`, `mounts`, `assembly`, …). It turns cold before it writes anything
  to the state, so no try is used.

Needs busybox init from Alpine 3.23 or later (3.22's ignores `SIGQUIT`) and the inittab
line `::restart:/usr/lib/glassine-boot/soft-start`, which the package adds.

## The shutdown switch

`glassine-switch-hook`, run by the OpenRC service `glassine-switch` in the `shutdown`
runlevel (after `killprocs`, before `mount-ro`). With a staged deployment it runs
`glassine-deploy switch` only when both of these hold:

- the shutdown was started by the user: the power menu runs
  `glassine-switch-hook --user-shutdown` right before it shuts down or reboots;
- a charger is online, or the battery is at `SWITCH_MIN_CAPACITY` percent or more
  (deploy.conf, default 30). A system without a battery counts as fine.

Otherwise the deployment stays staged for the next shutdown. The hook never stops a
shutdown. It writes what it did to `/run/glassine/switch-result` (`switch=yes|no`,
`switch_reason=` `not-user`, `battery`, `space` or `failed`), which a soft restart
carries into the incoming session's restart record. A hibernate never runs it, because the kernel powers off without the init
system's shutdown.

After it, the OpenRC service `glassine-mount-ro` (also in the `shutdown` runlevel, after
`mount-ro`) makes userdata and then the system partition read-only, with every mount and
bind of them (`gr_shutdown_ro` in `lib/glassine-root.sh`). OpenRC's own `mount-ro`
can't: by then `localmount`'s stop has taken `/run/glassine/*` out of the mount table,
while the root's overlay keeps both file systems alive, so userdata's ext4 journal would
need a replay at every boot. The service mounts each device again (the same live file
system), remounts that mount read-only and unmounts it. A file system that isn't alive
(a bare boot never mounted userdata) is left alone. It never stops a shutdown; a file
system it can't make read-only (still in use) is logged. Before that, where the shell's
shutdown screen left `/run/glassine/screen-keep`, it runs `glassine-splash-store override
--leave --wait 5` under a 15-second timeout (killed 2 s later if it doesn't end), so the next start leaves the screen as it is
(specs/011 FR-014); a failure is logged and the shutdown goes on. It skips both during a
soft restart.

## The first start

An installer writes a pool made by `init --install-marker` (one base, the kernel's
`modules/<release>`, the marker) to the system partition, and leaves userdata as it
found it (another system's data, or no file system). The initramfs finds no deployment
there and boots bare. `glassine-first-start`, run by the OpenRC service
`glassine-first-start` in the `boot` runlevel of that bare boot (never in the initramfs,
which mounts nothing read-write before the hibernation step), makes the system:

1. `state/kernel` `current=` the running kernel's release, when it is empty and
   `modules/<release>` is there.
2. The system partition's btrfs grown to its partition (`btrfs filesystem resize max`).
3. Userdata formatted: every mount of it unmounted first (the initramfs mounts any
   ext4 it finds; one that doesn't unmount stops the step), then ext4 with 4096-byte
   blocks (the hibernate step needs them) and without `orphan_file` (an older e2fsck,
   like the one of a second system on the machine, refuses it), `USERDATA_RESERVE_KIB`
   left free at its end.
   Its UUID goes into `state/install` (`userdata=`). A userdata with that UUID is not
   formatted again.
4. `glassine-deploy stage <the only base> --no-replay --now --yes`: the first
   deployment (`kind=install`, nothing carried), the candidate with 2 tries.
5. `state/install` removed, once `state/deploy` names a candidate with 2 tries.
6. A reboot (the orderly one). The candidate boots and is accepted as any candidate.

- **Only with the marker.** Without `state/install` it does nothing and writes nothing;
  a userdata is never formatted without it.
- **Power cuts.** Every step can run again, so a cut anywhere means the next boot runs
  the first start from the top: it finds the steps done and goes on. A cut after step 4
  boots the candidate: then userdata is the deployment's, and the first start only
  removes the marker (and reboots only from a bare boot).
- **Refusals** (logged, the marker kept, nothing written): the marker on a boot of a
  deployment while `state/deploy` selects none; no base or more than one under `bases/`;
  `btrfs`, `mke2fs` or `dumpe2fs` missing; userdata that doesn't unmount. Exit 1 (the
  next boot tries again), 3 a newer state format, 6 busy.
- **What it does not handle:** a first candidate that runs out of tries leaves the
  device booting bare with the marker gone; the recovery is the way on from there.
- Messages go to the kernel log, where the initramfs logs.

### Tools each command needs

The initramfs and every command except the two below run with busybox and e2fsprogs'
`e2fsck`, `dumpe2fs` and `debugfs` ([boot.md](boot.md#files-in-the-image)). `receive`
(but `receive --boot`) and `bases remove` need btrfs-progs (and zstd for a `.zst` stream), and the removal of
unused bases uses it where it is there (without it, nothing is removed); the first start needs
btrfs-progs (the resize) and e2fsprogs' `mke2fs`. `init` needs neither. So a base that
an installer ships must contain btrfs-progs and e2fsprogs.

## Accepting a candidate

`glassine-deploy-accept`, started by the OpenRC service `glassine-deploy-accept` in the
`default` runlevel (after every other service, as a background job). It runs on every
start of a deployment (not a bare boot, not a kernel trial): it waits until this session
has been up `ACCEPT_AFTER` seconds (default 120; counted from the session's start, the
`at=` of `/run/glassine/restart`, so a soft start waits its own time), then checks
health:

- no OpenRC service has crashed (`rc-status --crashed`);
- every executable in `ACCEPT_HEALTH_DIR` (default `/etc/glassine-bootimg/health.d`,
  the same checks as a kernel test boot) exits 0 within 60 seconds. The first output
  line of a failing check is the logged reason.

Healthy: it writes `/run/glassine/healthy` (`at=` the time on `/proc/uptime`), on every
board, also with nothing to accept or mark: a soft restart starts only from such a start
([Restart](#restart)). Then, when the booted deployment is the candidate and the start is
not one by request (`/run/glassine/deploy-once`, [boot.md](boot.md#command-line-keys)),
`glassine-deploy accept`. Unhealthy: it logs `<id> not accepted: <reason>` to the
kernel log and changes nothing, so the next boot uses the candidate's next try, and
after the last one the old deployment boots again.

**The boot slot** (dual-boot boards, `SLOT_TOOL` = the path of `glassine-slot`, see
[boot.md § Slots](boot.md#slots); empty = off): the same healthy boot also runs
`glassine-slot mark-successful` when the booted bootloader slot is not marked
successful yet, whichever deployment booted (the candidate, the current one or a
fallback), because the slot itself works. Without it the bootloader counts a try per
boot after a kernel update and in the end boots the other system. A bare boot does not
mark it. A failing `glassine-slot` is logged and does not stop the accept.

**The healthy mark** (`HANDOFF=uefi`, or `BOOT_FORM=raw`): the same healthy boot also writes `unmarked=0`
into the loader record on the boot partition
([boot-partition.md](boot-partition.md#keys)), whichever deployment booted and also when
there was no candidate, and also on a start by request (`deploy-once`: no deployment
accept, but the mark, 010 FR-044) and on a kernel finishing boot. A bare boot, a kernel
trial boot and a boot that fails a health check write none; the failure is noted in
`/run/glassine/health-failed` for the shutdown step. Without the mark the loader counts
the start as one that never became healthy. The write is `glassine-loader-mark healthy`
(`GLASSINE_LOADER_MARK` in tests), in its own process, before the deployment accept; a
failing write is logged and does not stop the accept. On a hand-off without a loader
record (`bootpart-test`, `blocklist`, empty) no mark is written. When the healthy start is the loader's
start of the previous kernel set for its limit (`glassine-loader-mark` leaves
`/run/glassine/limit-start`), the accept then runs `glassine-bootimg rollback --limit`
(010 FR-013, [boot-partition.md](boot-partition.md#keys)): that set becomes the default
kernel and the one that failed is listed as failed (`GLASSINE_BOOTIMG` in tests). It
runs once per kernel run: `/run/glassine/limit-done`, which a soft start carries, keeps
the next session's mark from running it again. Once
the mark succeeded in this start (written, or `unmarked` was 0 already; and a candidate
accepted), the accept runs the loader
update (`glassine-loader-update`, `GLASSINE_LOADER_UPDATE` in tests; with `BOOT_FORM=raw`
only, [boot-partition.md](boot-partition.md#the-running-systems-writer)): the packaged
loader and default splash are written where the boot partition holds other ones; a
failure is logged and does not change the accept's result.

**The recovery's keep marker:** every command that opens userdata read-write creates
`.twrp-keep` in the prefix's top-level media directory (`media/glassine/.twrp-keep`
for the default prefix). A recovery that honours it skips that directory when it wipes
internal storage. `status` reports `twrp_keep=yes|no` (empty while userdata is not
mounted or the prefix is not under `media/`).

## Configuration: `/etc/glassine/deploy.conf`

See [`conf/deploy.conf.example`](../conf/deploy.conf.example): `SYSTEM_DEV`,
`SYSTEM_MNT`, `USERDATA_DEV`, `USERDATA_MNT`, `USERDATA_PREFIX`, `RUN_DIR`,
`USERDATA_RESERVE_KIB` (default 0: the KiB the first start leaves free at the end of userdata), `SWITCH_MIN_CAPACITY`, `SOFT_RESTART` (default `yes`; `no`: every restart is cold), `RESTART_LIMIT_S` (default 20: each step of a soft start gives up after this many seconds and the restart turns cold), `RESTART_INIT_S` (default 60: how long `restart` waits for PID 1 to start the soft restart before it restarts cold), `ACCEPT_AFTER`, `ACCEPT_HEALTH_DIR`, `ACCEPT_BUSY_S` (default 600: how long the accept retries while the state is busy), `SLOT_TOOL` (default empty: no boot slot marking), `HIBERNATE_SIZE_MB`, `HIBERNATE_RESERVE_MB`. A recovery passes its own file with `GLASSINE_DEPLOY_CONF`.

## Runtime directory: `/run/glassine/`

| Path | Written by | Meaning |
|---|---|---|
| `booted` | initramfs | the deployment that booted, or `bare:<base>` |
| `storage` | initramfs | key=value: `home`, `flatpak` (`bound` or `failed`, with `<name>_error`), `vartmp` (`shared` or `failed`); a bare boot has only `vartmp` |
| `system/`, `userdata/`, `root/` | initramfs | the system partition, userdata and the merged overlay, moved there before `switch_root` |
| `switching` | `glassine-deploy switch` | a switch is running; the hibernate step refuses while it exists |
| `restart` | initramfs, soft start | how this start came: `kind=cold\|soft`, `from=` the outgoing deployment (soft), `count=` the soft starts in this kernel run, `at=` the start's time on `/proc/uptime`; after a soft restart `switch=`, `switch_reason=` (what its switch did); after a soft restart that turned cold `cold_reason=` once |
| `healthy` | `glassine-deploy-accept` | this start reached its health conditions (`at=`); a soft restart needs it |
| `restarting` | `glassine-deploy restart` | a soft restart runs (`from`, `once`, `count`, `sysdev`, `uddev`, `prefix`, `limit`); the hibernate step refuses (exit 4), the shutdown services skip what belongs to a cold shutdown |
| `kept/`, `kept.none` | initramfs, soft start | the kept assembly (`.complete` when whole), or the word why there is none (`test-role`, `kernel-trial`, `bare`, `no-assembly`) |
| `switch-result` | `glassine-switch-hook` | what the shutdown's switch did (above) |
| `limit-done` | `glassine-deploy-accept` | the rollback after the loader's limit ran in this kernel run |
| `user-shutdown` | the power menu, via `glassine-switch-hook --user-shutdown` | this shutdown may switch |
| `shutdown` | `reboot`, `poweroff`, `halt` (`/usr/sbin`), `glassine-reboot-clean`, `glassine-deploy restart` | the shutdown record: one line `next=<target>`, written atomically (`.new`, then renamed) before init is asked to shut down: `restart`, `poweroff`, or a reboot reason (`menu`, `recovery`, `bootloader`, …); other writers may name `other`. `reboot` without a reason, `poweroff` and `halt` write it only when none is there (a caller that named its target first wins); `glassine-reboot-clean` writes its reason over one that is there, never when it refuses (exit 2, 3, or 1 before the reboot), and removes it when the reboot doesn't start; `glassine-deploy restart` (soft or cold, `--cold`, the `--restart` forms) writes `next=restart` once its checks passed, before anything stops. A record that can't be written never stops a shutdown. Read by GlassineOS/shell's `glassine-shutdown-screen`, and by power daemons: no suspend once a shutdown has started (shell 009 FR-013). Per start: gone with the outgoing session, a soft restart doesn't carry it |
| `screen-keep` | GlassineOS/shell's `glassine-shutdown-screen` | the shutdown screen is on a bistable panel and should stay through the next start: the cold shutdown (`glassine-mount-ro`) writes the splash store's override "leave the screen" (`glassine-splash-store`, [boot.md](boot.md#the-splash-store)). A soft restart neither carries it nor writes an override |
