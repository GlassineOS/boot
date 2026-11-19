# Feature Specification: Soft restart into a deployment under the running kernel

**Feature branch:** `soft-restart`
**Created:** 2026-11-19 · **Status:** spec, for review; nothing built, nothing run on a
device
**Builds on:** [001-deployments](../001-deployments/spec.md),
[004-kernel-records](../004-kernel-records/spec.md),
[010-uefi-deployments](../010-uefi-deployments/spec.md),
[011-boot-splash](../011-boot-splash/spec.md),
[012-device-boot-partition](../012-device-boot-partition/spec.md) · **Interfaces:**
[docs/deployments.md](../../docs/deployments.md) (`glassine-deploy`, the deployment
state, the runtime directory, acceptance), [docs/boot.md](../../docs/boot.md) (the boot
steps, hibernation), [docs/kernel-artifacts.md](../../docs/kernel-artifacts.md) (kernel
records, which combinations boot), [docs/boot-partition.md](../../docs/boot-partition.md)
(the loader record) · **Decisions:** docs
[0010](https://github.com/GlassineOS/docs/blob/main/docs/decisions/0010-root-and-deployments.md)

## Summary

The kernel is the device's, not the deployment's (0010): every deployment boots under the
kernel the device selects. So moving from one deployment to another (an update, a reset,
a rollback, a select) does not need a new kernel. A cold restart costs all of it:
the firmware, the bootloader, the kernel, every driver, every remote processor and every
firmware load, only so that the initramfs can assemble another root.

A **soft restart** keeps all of that running. It stops the session (every process of the
deployment that runs), unmounts its root, runs the same pick and assembly the
initramfs runs at a cold start, and starts the init system in the new root. To the
person it looks like a restart: apps close, the session starts again, in the new
deployment. Only it is faster, and the screen, the network devices and the radios don't
go through their power-on.

It applies only when the next cold start would run exactly the kernel image that runs
now. Otherwise, and whenever anything on the way doesn't go as planned, the restart is a
cold one. A soft restart never leaves a half-switched system: it ends in the new session
or in a cold restart.

The deployment model doesn't change: the same pick, the same tries, the same acceptance,
the same fallback. A soft start is one more way to start a deployment, and it counts
exactly as a cold start does.

## Terms

| Term | Meaning |
|---|---|
| cold start | a start through the firmware, the bootloader (and the loader, where there is one), the kernel and the initramfs |
| soft start | the start of a deployment by a soft restart: the kernel keeps running, only the session starts again |
| start | a cold start or a soft start. The deployment state counts both alike |
| kernel run | everything from one cold start to the next power-off or reset: one kernel, one loader start, any number of starts |
| session | everything the init system of one start runs, from its first process to its stop |
| running image | the kernel image this kernel run started from: its image record (`glassine.img=` on the command line, 004) or its kernel set (010) |
| assembly | the steps of the initramfs that pick the deployment, assemble its root, bind the person's storage and the modules, and hand over to its init system ([boot.md](../../docs/boot.md#deployments-layout), "Boot") |
| outgoing session, incoming session | the session a soft restart stops, and the one it starts |

## User scenarios

### Scenario 1 – An update applied by a soft restart (P1)

**Given** a staged update (a new base, 002) and a device whose kernel stays the same,
**When** the person chooses "Restart to update",
**Then** the apps close, the screen shows that the system restarts, and the session
starts again in the new deployment, as its candidate, with one try used. The kernel's
uptime goes on, and the network devices and remote processors were not restarted. After
120 seconds healthy, the candidate is accepted as after a cold start.

### Scenario 2 – A rollback by a soft restart (P1)

**Given** a current and a previous deployment under the same kernel,
**When** the person rolls back and restarts,
**Then** the previous deployment starts as the candidate in a soft restart, and is
accepted after its healthy time.

### Scenario 3 – A cold restart where a soft one can't be (P1)

**Given** a restart into a deployment while the next cold start would run another
kernel image than the running one (a kernel rollback, a kernel waiting for its trial, a
new device tree or initramfs for the same release),
**When** the person restarts,
**Then** the restart is a cold one, and the person was told so before they confirmed:
the restart's entry names which kind it will be.

### Scenario 4 – Something refuses to stop (P1)

**Given** a soft restart under way,
**When** a process of the outgoing session doesn't end, or its root doesn't unmount,
within the time allowed,
**Then** the restart becomes a cold one: the file systems are synced and made
read-only as far as they can be, and the device restarts through the firmware. The
deployment state is what it was before the restart, apart from the switch the restart
made (a staged deployment carried and selected). No deployment try was used.

### Scenario 5 – A soft-started candidate that fails (P1)

**Given** a candidate started by a soft restart,
**When** it doesn't reach the health conditions,
**Then** it isn't accepted, as after a cold start. The next restart, whatever the person
asks, is a cold one: the cold start takes the candidate's next try, or, with none left,
marks it failed and boots the current deployment. Without a restart the person keeps
the failed session, as after a cold start.

### Scenario 6 – A broken new deployment never strands the device (P1)

**Given** a soft restart into a candidate whose root doesn't assemble,
**When** the assembly fails,
**Then** the candidate is marked failed and the current deployment starts in the same
soft restart, exactly as a cold start falls back. **And given** a session whose first
process can't start at all, **then** the kernel restarts the device and the cold start
picks as the state says.

### Scenario 7 – Hibernation after a soft restart (P2)

**Given** a soft-started deployment that is current, or a candidate with a try left,
**When** the person hibernates and later switches the device on,
**Then** the session resumes into that deployment, as after a cold start.

### Scenario 8 – Another deployment for one session (P3)

**Given** a current and a kept deployment under the same kernel,
**When** the person starts the kept one "for this session only",
**Then** it starts by a soft restart, `state/deploy` is not written, nothing is
accepted, and the next restart, soft or cold, runs the ordinary pick again.

### Scenario 9 – A plain restart (P1)

**Given** a running deployment that has been healthy, with no deployment change
waiting,
**When** the person chooses "Restart",
**Then** the session restarts by a soft restart into the same deployment: the apps
close, the kernel keeps running. Where FR-001 doesn't allow a soft restart, "Restart"
is a cold one, and the entry said so before the person confirmed.

### Scenario 10 – Restart fully (P1)

**Given** a running system,
**When** the person chooses "Restart fully",
**Then** the device restarts cold, through the firmware, whatever FR-001 says. A
waiting deployment change is applied by the switch as at any user-started restart.

## Requirements

### When a restart is soft

- **FR-001** A restart into the deployments layout is soft only when every one of these
  holds at the moment it is decided:
  - nothing selects another kernel image for the next cold start: the kernel rule the
    hibernate step already applies finds nothing (`state/kernel`'s `current_img` is the
    running image, or, while no `current_img` is recorded, `current` is the running
    release; no `writing`; not a kernel trial or finishing boot; kernel-artifacts.md
    "Order on the device"), no kernel candidate is set (004; a kernel waiting for its
    trial keeps a staged deployment staged, so it keeps the restart cold too), and,
    where the board keeps a loader record, it holds no `request` and names no other
    default set than the running one (an empty default under a parent is its baseline,
    the running image; 012). Image ids are compared where they are recorded, not
    releases: the same release can come with another device tree or initramfs. A board
    with no kernel hand-off (`HANDOFF` empty) has only the running kernel and qualifies;
  - the running kernel covers the deployment the pick will start (the rule of
    `select`'s exit 8, kernel-artifacts.md "Which combinations boot"), and that
    deployment's modules subvolume `modules/<uname -r>` is on the system partition. A
    modules subvolume is never replaced (kernel-artifacts.md "Kernel release"), so the
    same release is the same subvolume, the one the running kernel loaded its modules
    from;
  - the running start is a start of a deployment (not a bare boot, not the first start
    of 009, not the test role, not a kernel trial or finishing boot) and has reached the
    health conditions of 001 FR-018 (FR-016);
  - soft restarts aren't turned off (FR-004).
- **FR-002** Otherwise the restart is a cold one: the orderly restart through
  the firmware. A restart that asks for something only a cold start can do is always cold:
  a kernel trial (`glassine-bootimg reboot-test`), the recovery, the loader's start
  menu, the other system, the bootloader, a power-off.
- **FR-003** `glassine-deploy` decides, and nothing else does. It decides twice, with
  the same rules: when asked to report (FR-006), so the person sees which kind comes;
  and again after the outgoing session has stopped, so a state that changed in between
  counts. When the second decision is "cold", the restart is cold (FR-021).
- **FR-004** A machine or the person can turn soft restarts off
  (`SOFT_RESTART=no` in `deploy.conf`; default on). Then every restart is cold.
- **FR-005** The plain layout has no soft restart.

### How the person learns which one happens

- **FR-006** A check with no write reports what a restart now would be, and why:
  `glassine-deploy restart --check` (exit 0: soft, 9: cold, with the reason), and
  `status` (`restart=soft|cold`, `restart_reason=`). The reasons are fixed words
  (`kernel`, `kernel-trial`, `loader-request`, `not-covered`, `modules`, `not-healthy`,
  `bare`, `off`, …), so a shell can word them.
- **FR-007** The power menu has two restart entries: "Restart" (`restart`: soft where
  FR-001 allows, else cold) and "Restart fully" (`restart --cold`: always cold). Before
  the person confirms, "Restart" says which kind it will be: a soft restart as a
  restart in which the apps close and the device stays on; a cold one as an ordinary
  restart, with the reason in the shell's words (FR-006). A restart that turns cold after all (FR-003, FR-021)
  is said on the screen while it happens, and the next session says why, once.
- **FR-008** The incoming session can tell how it started: `/run/glassine/restart`
  (`kind=cold|soft`, `from=` the outgoing deployment, `count=` the soft starts in this
  kernel run, `at=` the start's time on the monotonic clock), and `status`
  (`last_start=cold|soft`).

### What starts a soft restart

- **FR-009** `glassine-deploy restart` restarts: soft where FR-001 allows, else cold.
  `--cold` always restarts cold. `--soft` restarts only soft and refuses otherwise
  (exit 9, nothing stopped). `select`, `rollback`, `reset` and `stage` take `--restart`:
  the command, then `restart`. A restart that the person starts is a user-started
  restart in the sense of 001 FR-009, so the switch rule applies to it (FR-012).
- **FR-010** The shell's "Restart" is `restart`, with or without a deployment change
  waiting (a staged or selected deployment): soft where FR-001 allows, else cold. With
  no change waiting, the soft restart starts the deployment the pick gives, which is
  the running one. "Restart fully" is `restart --cold`, always there beside it, for a
  person who wants the hardware and the kernel started again; it applies a waiting
  change through the same switch.
- **FR-011** An update never restarts by itself. When it has staged a deployment, the
  shell's notice offers "Restart to update", which is `restart`; the person's choice
  starts it, as the switch waits for a user-started shutdown.
- **FR-012** A staged deployment is carried and selected by the same switch, at the same
  point and under the same conditions as at a user-started shutdown (001 FR-007 to
  FR-010): after the session's services have stopped and its processes have ended,
  from a plain bind of the live root, with a charger or the battery at
  `SWITCH_MIN_CAPACITY`. A switch that doesn't happen (the battery, no space) leaves the
  deployment staged, and the restart goes on into what the state now picks; the
  incoming session says that the update wasn't applied, and why. `restart --check`
  reports beforehand whether the switch would happen (`switch=yes|no`,
  `switch_reason=`), so the shell can say so before the person confirms.
- **FR-013** `restart --once ID` starts ID for the incoming session only, by a soft
  restart, with the meaning of 010 FR-043 to FR-045: `state/deploy` not written, no try
  used, nothing accepted, the healthy mark as on any start. It refuses (exit 9) when the
  restart would not be soft: a cold start has no way to carry the request from the
  running system. An ID that isn't there, is staged or doesn't assemble is refused
  before anything stops.

### The trial and acceptance

- **FR-014** The incoming session's deployment is chosen by the pick of 001 FR-005, run
  by the same assembly as a cold start, on the state as the outgoing session and the
  switch left it. A candidate with tries left uses one; one with none is marked failed
  and current starts; a candidate that doesn't assemble is marked failed and the next
  in the order starts. The only difference: where the cold pick would end in a bare
  boot, a soft restart restarts cold instead (FR-021).
- **FR-015** The try is written once, after the chosen root has assembled and right
  before the hand-over to its init system, so a soft restart that gives up before that
  (FR-021) has used no try, and the cold start that follows uses it. A failure after
  that write is a failed start of the candidate and counts as one, as at a cold start.
- **FR-016** A soft restart starts only from a start that has reached the health
  conditions of 001 FR-018 in its own session: the boot-success step records that in
  `/run/glassine/healthy`. So it checks health on every start of a deployment, on
  every board, also where it has nothing to accept, no slot and no loader record to
  mark. So a soft start never follows an unhealthy start, and a
  candidate that isn't accepted is left only by a cold restart (Scenario 5). A start
  younger than its healthy time restarts cold.
- **FR-017** The boot-success step waits `ACCEPT_AFTER` seconds from the start of its
  own session (FR-008's `at`), not from the kernel's start, and checks the health of
  its own session's services. It accepts the booted candidate under 001 FR-018, and
  accepts nothing in a start by request (FR-013, 010 FR-044).
- **FR-018** A soft start is not a loader start. It doesn't change the loader record's
  `unmarked`, `started`, `started_why`, `request` or `deploy_once`, takes no
  `deploy_once`, and ignores the kernel command line's `glassine.deploy.once=`, which
  was the cold start's. The loader's count belongs to the kernel run: because the
  outgoing start had its healthy mark (FR-016), `unmarked` is 0 throughout, the
  incoming session's mark is no write, and the shutdown step at the end of the kernel
  run finds the mark. The loader record changes only by what the commands publish
  (`deploys`, 010 FR-041).
- **FR-019** The bootloader's slot state is the kernel run's: a soft restart neither
  counts nor marks a slot.

### What stops, what survives

- **FR-020** A soft restart stops the whole session: every service in the init system's
  orderly order, then every remaining process (asked to end, then ended), the person's
  sessions and apps, Flatpak sandboxes and containers among them. It keeps only the
  kernel, its threads, its loaded modules and firmware, its devices (network devices,
  input, the display, storage), remote processors, the mounts of the system partition
  and userdata, and the device file system. Network connections, Bluetooth links and
  whatever userspace set up on devices start again as at a cold start. Nothing of the
  outgoing session's runtime directory survives except FR-024's.
- **FR-021** It has two phases:
  1. **The check**, with nothing stopped: FR-001, the free space for a switch
     (the switch's own check, exit 5), the target's presence. A refusal
     leaves the session running (the exit codes of FR-028).
  2. **From the first stop on**, the restart ends in the incoming session or in a cold
     restart, nothing else. Each step has a time limit. Any step that fails or runs out
     of time makes the restart cold: what is left is ended, both file systems are
     synced and made read-only as `glassine-mount-ro` does, and the device restarts
     through the firmware.
- **FR-022** Before the old root is unmounted, no process may remain whose root,
  working directory, open files or mappings are in it, or in any mount below it. Before
  the assembly runs, the old root and every mount under it are unmounted, none of them
  lazily. A process that doesn't end, or a mount that doesn't unmount, within the time
  limit makes the restart cold (FR-021). Open files on userdata end with their
  processes; both file systems are synced before the assembly.
- **FR-023** Userdata and the system partition stay mounted through a soft restart: no
  fsck, no remount, no journal replay. Their ext4 mount count and last mount time don't
  change.
- **FR-024** Per start, made anew by every start: `booted`, `storage`, `deploy-once`,
  `healthy`, `restart`, the merged root. Gone with the outgoing session: `unlocked`,
  `user-shutdown`, `switching`, the apk lock. Per kernel run, carried into the incoming
  session: `kernel-boot`, `loader-marked`, `health-failed` (the shutdown step's inputs,
  010 FR-012), and the fact that `limit-start` was acted on, so a rollback after the
  loader's limit (010 FR-013) runs once per kernel run.
- **FR-025** The assembly that runs is the one the running image brought, kept in memory
  for the kernel run, so it is byte for byte the assembly the next cold start would run
  (FR-001). The steps that belong to a cold start alone don't run in a soft start: the
  boot modules (already loaded), the hibernation step, the pstore save, the developer
  hooks of the initramfs. The device data step runs as at a cold start.
- **FR-026** A hardware watchdog stays armed through the restart. From the first stop to
  the hand-over, the restart step feeds it itself, between its steps, so a step that
  hangs longer than the watchdog's time resets the device into a cold start. The
  incoming session's start feeds it again as the initramfs does at a cold start. A
  machine without a watchdog relies on FR-021's limits, and on the person for a hang
  in the kernel (010 "No watchdog is assumed").

### Interaction with hibernation and the state

- **FR-027** The hibernate step refuses while a restart runs (`/run/glassine/restarting`,
  next to `switching`, exit 4). A restart refuses while the hibernate step holds the
  state lock (exit 6). In the incoming session the hibernate guard records the
  soft-started deployment (`/run/glassine/booted`) and the running kernel, and its
  refusal "the state would boot another deployment next" reads the state the soft start
  left: so an image made after a soft start resumes into that deployment. Since userdata
  stayed mounted (FR-023), the guard's mount count and time are the kernel run's.
- **FR-028** Exit codes of `restart`: the existing ones of `glassine-deploy`
  (deployments.md) apply before anything stops (1, 2, 3, 5 too little space for the
  switch, 6 busy, 8 not covered by the current kernel), and one more: **9**, the restart
  would not be soft (`--check`), or `--soft`/`--once` refused for that reason. From the
  first stop on, `restart` doesn't return: the session ends.
- **FR-029** Every state write of a soft restart is the existing one (`gs_write` under
  `state/.lock`): the switch's, the pick's try, a failed mark. A power cut or a reset at
  any point leaves a state the next cold start picks from as from any other.
- **FR-030** The clean-up (001 FR-020) runs at the points 001 gives it. The outgoing
  deployment is unmounted by then, so after the restart it is removed if nothing else
  keeps it (it is current or previous in every path that leads here).

### The screen

- **FR-031** The outgoing session's shell shows one picture that says the system
  restarts, with one whole-panel refresh on an e-ink panel, before the stop. From then
  on nothing draws until the incoming session's first frame, as 011 FR-016 holds for a
  cold start. A restart that turns cold says so in one more refresh before it restarts.
- **FR-032** The splash store and its override belong to the loader's starts: a soft
  start neither reads nor removes an override, and 011 FR-015's removal of an unused
  override happens at cold starts only.

## Key entities

- **The restart step**: `glassine-deploy restart`; decides (FR-001), stops, switches,
  assembles through the kept assembly, hands over.
- **The kept assembly**: the running image's assembly, in memory for the kernel run.
- **The restart record**: `/run/glassine/restart` (FR-008).
- **The healthy record**: `/run/glassine/healthy` (FR-016), per start.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| `glassine-deploy restart` (`--check`, `--soft`, `--cold`, `--once`), `--restart` on `select`, `rollback`, `reset`, `stage`, exit 9 | owned (added) | porcelain 1, keys added | `docs/deployments.md`, "`glassine-deploy`", "Exit codes" |
| `status` keys `restart`, `restart_reason`, `switch`, `switch_reason`, `last_start` | owned (added keys) | porcelain 1 | `docs/deployments.md`, "Porcelain" |
| `/run/glassine/restart`, `healthy`, `restarting`; FR-024's lifetimes | owned (added) | runtime, unversioned | `docs/deployments.md`, "Runtime directory" |
| `SOFT_RESTART` in `deploy.conf` | owned (added) | key added | `docs/deployments.md`, "Configuration" |
| The assembly kept for the kernel run; the soft start's steps | owned (added) | boot steps | `docs/boot.md`, "Deployments layout" |
| `state/deploy`, `state/kernel` | owned (unchanged) | `version=1` | `docs/deployments.md`, `docs/kernel-artifacts.md` |
| The loader record | consumed (read only by the restart step; FR-018) | `format=1` | `docs/boot-partition.md` |
| The shell's restart entries and notice | consumed by GlassineOS/shell | `restart --check`, porcelain 1 | `docs/deployments.md` |

## Device scope and risk

- **Device-neutral.** The same on every machine with the deployments layout: a PC and
  the Note Air alike. Nothing in it names a device; a board turns it off only through
  `SOFT_RESTART`.
- **Writes:** `state/deploy` (the switch, the try, a failed mark) and the deployment's
  layers on userdata, as a cold start and a shutdown switch do. No boot partition, no
  loader record write of its own, no bootloader slot, no firmware variable.
- **Failure modes:** a process or mount that won't let go (FR-022: cold restart); an
  assembly that fails (FR-014: the pick's fallback, else cold); an incoming init that
  can't start (the kernel's restart on the death of the first process, a cold start);
  a userspace driver that doesn't cope with its device already set up (an unhealthy
  session: FR-016 makes the next restart cold); a hang in the restart step (the
  watchdog, FR-026, or the person).
- **Escape:** a cold restart is always one step away, and every failure ends in one; it
  depends on nothing a soft restart changes. `SOFT_RESTART=no` turns the feature off.
  The recovery is reached as from any session.

## Edge cases

- **A restart soon after a cold start**, before the healthy time: cold (FR-016).
- **A kernel rollback or a new initramfs waiting** (`current_img` isn't the running
  image): cold, and said (FR-006).
- **A kernel candidate installed but its trial not asked for**: cold (FR-001), as the
  switch leaves a staged deployment staged while a kernel candidate is set (004); the
  kernel's own restart (`reboot-test`) is cold anyway.
- **A start by request** (010 FR-043, FR-013 here) **restarts**: the incoming session
  runs the ordinary pick; the request is not repeated.
- **A soft restart chain**: any number in one kernel run; `count` in the restart record
  says how many.
- **The person's storage**: `home/` and `flatpak/` are bound again into the new root,
  as at a cold start; a bind that fails is reported as at a cold start.
- **A removable disk mounted by the person**: unmounted with the old root's tree; one
  that won't unmount makes the restart cold.
- **A swap file or a hibernate image in use**: the hibernate swap file is only on during
  a hibernate, which refuses during a restart (FR-027); other swap the kernel holds
  doesn't block anything.
- **An unlocked root** (`glassine unlock`): the incoming session is locked again.
- **Power cut during a soft restart**: FR-029; the cold start picks as the state says.
- **The staged deployment's switch fails** (space, a copy error): the deployment stays
  staged, the restart goes on into the current one, and the incoming session says so.
- **A target whose base needs something the running kernel doesn't provide**: `select`
  and `stage` refuse already (exit 8); `restart` re-checks (FR-001).

## Success criteria

- **SC-001** On the Note Air and on one PC: after a soft restart the kernel's boot id is
  unchanged and its uptime continuous, no remote processor or firmware was started
  again (the kernel log shows none), and the network devices keep their interface
  index.
- **SC-002** Host test: for the same starting state and target, the `state/deploy`
  after a soft start equals byte for byte the one after a cold start, for each pick
  case (candidate with tries, without, not assembling, current, previous).
- **SC-003** Host test: the loader record is byte for byte the same before and after a
  soft restart that runs no publishing command.
- **SC-004** Host test: the incoming session's mount table, `/run/glassine` contents
  (FR-024) and person's storage binds equal a cold start's of the same deployment, and
  no mount of the old root is left.
- **SC-005** Host test: a process that doesn't end (one in uninterruptible sleep, one
  that ignores signals in a mount namespace of its own) and a mount that doesn't
  unmount each make the restart cold, with no try used and the switch's result kept.
- **SC-006** Host test: a restart cut at every step of phase 2 leaves either the
  incoming session or a cold start whose pick is that of the state as written; never a
  session on a half-assembled root.
- **SC-007** Host test: a hibernate image made after a soft start resumes into the
  soft-started deployment, and one made while a candidate is on its last try is
  refused (exit 3).
- **SC-008** On an e-ink panel: one whole-panel refresh for the restart picture and
  none from then until the incoming session's first frame.

## Assumptions

- The running image's initramfs can leave its assembly in memory for the kernel run,
  and the init system can hand its first process over to the restart step at the end of
  its orderly stop.
- Userspace services that drive hardware cope with a device a previous session already
  set up, as they cope with a crash and restart of their own. Where one doesn't, its
  board or package fixes it, or the board turns soft restarts off.
- Kernel memory leaked or fragmented over a long kernel run is not this feature's: a
  cold restart remains the remedy.

## Out of scope

- A soft restart into another kernel (kexec): a kernel hand-over brings the hardware
  hand-overs this feature avoids.
- Restarting single services or the person's session without restarting the system.
- Keeping apps or the person's session across a restart.
