# CLAUDE.md — GlassineOS/boot

Boot initramfs and on-device kernel update tools (see `README.md`). Every change: run
`make check` (host tests in Docker) and extend the tests for new behaviour.

- Nothing vendor-owned in this repository: no firmware, blobs, dumps, keys, serials.
- `glassine.devmode=usb` opens a root shell over USB: never default it on, never put it in
  the `CMDLINE` of `conf/board.conf.example` or a packaged board.conf.
- These tools write boot partitions: a change to a write path needs a test of the
  failure case (cut write, read-back mismatch) before it merges.
- Commits carry an `Assisted-by:` or `Co-Authored-By:` trailer. Never add
  `Signed-off-by`. Run `.glassine/org/scripts/safety-scan.sh --staged` before committing.
