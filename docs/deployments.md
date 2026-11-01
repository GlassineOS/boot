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
| userdata | The partition named by `USERDATA_DEV`, ext4. Holds the deployments under `USERDATA_PREFIX`, and the hibernate swap file. Home lives here as well, outside the deployments. |
| base | A read-only btrfs subvolume with a complete system (`bases/<id>/`). |
| deployment | One bootable root: a base plus its own layers on userdata (`deployments/<id>/`). |
| current | The deployment that boots normally. |
| candidate | A deployment under test: it boots instead of current while it has tries left. |
| previous | The deployment that was current before the last accept. |
| staged | A deployment that is prepared but not yet selected: the next switch carries state into it and makes it the candidate. |

## On-disk layout

```
system partition (btrfs, top level)
├── bases/<base-id>/            read-only subvolume, one per base
├── modules/<kernel-release>/   read-only subvolume, bound on /lib/modules/<release>
└── state/
    ├── format                  version=<N>
    ├── deploy                  the deployment state (below)
    ├── kernel                  current=, previous= (kernel releases)
    └── .lock                   flock target; never contains data

userdata (ext4) under USERDATA_PREFIX (default media/glassine)
├── deployments/<id>/
│   ├── meta                    key=value (below)
│   ├── build/                  the layer built for this deployment; read-only once it exists
│   ├── switch/                 the switch layer, then the live upper: every write of the
│   │                           running deployment lands here
│   └── work/                   overlayfs work directory
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

### `deployments/<id>/meta`

| Key | Value |
|---|---|
| `base` | the base id (required) |
| `kind` | `install`, `reset`, `reset-full`, `update` (`stage`) |
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

`/usr/share/glassine/migrate.list` (shipped with the base) and
`/etc/glassine/migrate.d/*.list` (the user's own). One absolute path per line. A
trailing `/` means a directory. `#` comments and blank lines are ignored, and so are
lines that are not absolute or that contain `..`. A switch copies each listed path from
the old deployment into the new one's switch layer, keeping modes and owners (`cp -a`;
parent directories get the source's mode and owner).

## `glassine-deploy`

```
glassine-deploy status [--porcelain]
glassine-deploy list [--porcelain]
glassine-deploy select ID [--yes] [--discard-hibernation]
glassine-deploy rollback [--yes] [--discard-hibernation]
glassine-deploy hibernate-invalidate [--yes]
glassine-deploy reset [--full] [--now] [--yes] [--discard-hibernation]
glassine-deploy stage BASE [--now] [--yes] [--discard-hibernation]
glassine-deploy receive FILE|- [--modules] [--sha256 HEX] [--discard-hibernation]
glassine-deploy bases [--porcelain]
glassine-deploy bases remove BASE [--yes] [--discard-hibernation]
glassine-deploy packages [ID] [--porcelain]
glassine-deploy switch [--discard-hibernation]
glassine-deploy accept ID
```

| Command | Does |
|---|---|
| `status` | format (state and supported), the system file system, current/previous/candidate/staged/tries, the kernels, `hibernated=yes\|no\|unknown`, `twrp_keep` |
| `list` | one record per deployment: id, state (`current`, `candidate`, `staged`, `previous`, `failed`, `kept`), base, kernel, created, size |
| `select ID` | ID becomes the candidate with 2 tries; selecting current cancels a candidate. Never makes an untried deployment current. |
| `rollback` | `select` previous |
| `hibernate-invalidate` | turns a hibernate image back into a plain swap file (that session is lost) |
| `reset` | stages a new, empty deployment on current's base (`carry=migrate`; `--full`: `carry=none`). A new reset replaces a staged one. `--now` switches at once (for the recovery). Home is never touched. |
| `stage BASE` | like `reset`, on another base under `bases/` (a base update): `kind=update`, `carry=migrate`. Refuses a base that is not there or has no `/etc/passwd`. |
| `receive FILE\|-` | `btrfs receive` of a send stream (full, or incremental onto a received base; `.zst` decompressed by its name) into `bases/` (`--modules`: `modules/`). Kept only if it is one read-only subvolume with a received UUID and a valid name; a cut stream, a name that exists or a missing parent leaves nothing. `--sha256` checks the file first. The only verb that needs btrfs-progs (and zstd for `.zst`). |
| `packages [ID]` | how a deployment's packages (current by default) differ from its base's, derived each time (no bookkeeping): world entries `added` and `removed` (constraints and tags as written), packages installed in another version: `raised`/`lowered` (`apk version -t`; `changed` where apk is missing). A deployment that is not running needs userdata mounted. The replay input of a later base. |
| `bases` | one record per subvolume under `bases/` and `modules/`, with the deployments whose meta names it |
| `bases remove BASE` | deletes the subvolume and waits until its space is back. Refuses the base of the booted, current, candidate or staged deployment. Other deployments on it stay on userdata but can no longer be selected (`list` shows `base_present=no`); it asks first (`--yes`), naming them and a lost rollback. Modules are not removed. |
| `switch` | for a staged deployment: clears its switch layer, carries the migrate list from current (unless `carry=none`), merges the accounts (below), syncs, then sets `candidate=<id> tries=2 staged=`. Interrupted = nothing selected, redone in full next time. |
| `accept ID` | the boot-success service's step: the booted candidate becomes current, the old current becomes previous. Refuses a non-candidate; accepting current is a no-op. |

Where it reads and writes:

- It mounts the partitions itself (`SYSTEM_MNT`, `USERDATA_MNT`) and unmounts what it
  mounted. When userdata is already mounted somewhere else (a recovery's `/data`), it
  uses that mount. It never writes the raw device under a mounted file system.
- Reading while userdata is not mounted uses `debugfs` (no mount, no journal replay). The
  system partition is mounted `ro,rescue=nologreplay` for reading.
- No `e2fsck` of userdata in a system booted by the deployments initramfs, because
  userdata is in use behind the overlay there.

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

### Porcelain (format 1)

`--porcelain` prints `glassine-deploy 1` on the first line, then one record per line.
Records are tab-separated `key=value` fields, and the first field is `type=<record>`.
Keys may be added within a version, so readers ignore keys they don't know.

```
glassine-deploy 1
type=status	format=1	supported=1	system_fs=btrfs	migrated=yes	current=…	previous=…	candidate=…	staged=…	failed=…	tries=…	kernel_current=…	kernel_previous=…	hibernated=no	userdata_prefix=media/glassine	twrp_keep=yes	swapfile=…	guard=…
```

```
glassine-deploy 1
type=deployment	id=…	state=current	base=…	base_present=yes	kernel=…	created=…	size_kib=…
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
applies, so a failed deployment that is also previous shows failed). `base_present` is
`yes` when the deployment's base is a subvolume under the system partition's `bases/`,
`no` when it is not, empty when the system partition is not readable or the meta names
no base. `status`'s `failed` is the last deployment that ran out of tries.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | error (message on stderr) |
| 2 | usage |
| 3 | the state format is newer than this tool (every command refuses; `status` still prints both versions) |
| 4 | a hibernated session on userdata, refused |
| 5 | not enough space on userdata (the deployment stays staged) |
| 6 | busy (another writer holds the lock) |

## The shutdown switch

`glassine-switch-hook`, run by the OpenRC service `glassine-switch` in the `shutdown`
runlevel (after `killprocs`, before `mount-ro`). With a staged deployment it runs
`glassine-deploy switch` only when both of these hold:

- the shutdown was started by the user: the power menu runs
  `glassine-switch-hook --user-shutdown` right before it shuts down or reboots;
- a charger is online, or the battery is at `SWITCH_MIN_CAPACITY` percent or more
  (deploy.conf, default 30). A system without a battery counts as fine.

Otherwise the deployment stays staged for the next shutdown. The hook never stops a
shutdown. A hibernate never runs it, because the kernel powers off without the init
system's shutdown.

## Accepting a candidate

`glassine-deploy-accept`, started by the OpenRC service `glassine-deploy-accept` in the
`default` runlevel (after every other service, as a background job). It acts only when
the booted deployment is the candidate. It waits until the system has been up
`ACCEPT_AFTER` seconds (default 120), then checks health:

- no OpenRC service has crashed (`rc-status --crashed`);
- every executable in `ACCEPT_HEALTH_DIR` (default `/etc/glassine-bootimg/health.d`,
  the same checks as a kernel test boot) exits 0 within 60 seconds. The first output
  line of a failing check is the logged reason.

Healthy: `glassine-deploy accept`. Otherwise it logs `<id> not accepted: <reason>` to
the kernel log and changes nothing, so the next boot uses the candidate's next try, and
after the last one the old deployment boots again.

**The boot slot** (dual-boot boards, `SLOT_TOOL` = the path of `glassine-slot`, see
[boot.md § Slots](boot.md#slots); empty = off): the same healthy boot also runs
`glassine-slot mark-successful` when the booted bootloader slot is not marked
successful yet, whichever deployment booted (the candidate, the current one or a
fallback), because the slot itself works. Without it the bootloader counts a try per
boot after a kernel update and in the end boots the other system. A bare boot does not
mark it. A failing `glassine-slot` is logged and does not stop the accept.

**The recovery's keep marker:** every command that opens userdata read-write creates
`.twrp-keep` in the prefix's top-level media directory (`media/glassine/.twrp-keep`
for the default prefix). A recovery that honours it skips that directory when it wipes
internal storage. `status` reports `twrp_keep=yes|no` (empty while userdata is not
mounted or the prefix is not under `media/`).

## Configuration: `/etc/glassine/deploy.conf`

See [`conf/deploy.conf.example`](../conf/deploy.conf.example): `SYSTEM_DEV`,
`SYSTEM_MNT`, `USERDATA_DEV`, `USERDATA_MNT`, `USERDATA_PREFIX`, `RUN_DIR`,
`SWITCH_MIN_CAPACITY`, `ACCEPT_AFTER`, `ACCEPT_HEALTH_DIR`, `ACCEPT_BUSY_S` (default 600: how long the accept retries while the state is busy), `SLOT_TOOL` (default empty: no boot slot marking), `HIBERNATE_SIZE_MB`, `HIBERNATE_RESERVE_MB`. A recovery passes its own file with `GLASSINE_DEPLOY_CONF`.

## Runtime directory: `/run/glassine/`

| Path | Written by | Meaning |
|---|---|---|
| `booted` | initramfs | the deployment that booted, or `bare:<base>` |
| `system/`, `userdata/`, `root/` | initramfs | the system partition, userdata and the merged overlay, moved there before `switch_root` |
| `switching` | `glassine-deploy switch` | a switch is running; the hibernate step refuses while it exists |
| `user-shutdown` | the power menu, via `glassine-switch-hook --user-shutdown` | this shutdown may switch |
