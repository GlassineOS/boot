# Golden files

Made by the loader's own code, GlassineOS/loader at commit
`6e7d1ee3fd900084152eda5519cddfef6a7298aa` (`core/src/raw.rs`):

- `table-16mib.hex`: `raw::build_table(16 << 20, &raw::layout_16mib())`, the region
  table of `docs/boot-partition.md`, "Sizes", for a 16 MiB partition.
- `loader-header-5000.hex`: `raw::loader_header(image)` for the 5000-byte image whose
  byte `i` is `(7 × i + 3) mod 256`.

`glassine-boot-raw init` and `glassine-boot-raw loader` must write these bytes
(`test/bootraw`), so the two programs agree on the raw form.

Both are kept as hex text (32 bytes a line); `test/bootraw/inner.sh` turns them back
into bytes before comparing.
