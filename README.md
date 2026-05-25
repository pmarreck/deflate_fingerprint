# deflate_fingerprint

Identify and reproduce the DEFLATE encoder configuration that produced a
compressed byte stream.

DEFLATE decoding is deterministic; DEFLATE encoding is not. Different encoders,
levels, strategies, memory settings, block split heuristics, Huffman builders,
flush patterns, and wrapper choices can all produce valid but byte-distinct
streams for the same uncompressed input. `deflate_fingerprint` is a
parameterized DEFLATE implementation whose job is to recover those choices and
reproduce the exact bytes.

## Status

Active reverse-engineering / implementation project.

- 28 fingerprints registered: zlib level 0, zlib levels 1-9 across default /
  fixed / filtered strategies, collapsed zlib HUFFMAN_ONLY and RLE fingerprints,
  plus zlib L1 explicit `SYNC_FLUSH` + empty finish handling.
- `./test` currently passes 111 tests: Zig unit tests, CLI integration tests,
  real-zlib fidelity checks, and the internal corpus hit-rate sweep.
- Internal project-file corpus: 100% hit rate across 500 generated raw-DEFLATE
  streams.
- Real-world ZIP-family probing is underway. Current checkpoint hit rates are
  recorded in [SESSION_RESUME.md](SESSION_RESUME.md).
- Active research target: large ZIP-family XML streams with non-default flush
  topology. The core now models these as abstract `DeflateReproductionConfig`
  values with raw sync-flush offsets; named producer details such as Excel
  worksheet structure live in probes/tests rather than the main encoder.

## Why it exists

The downstream consumer is `../blar`, a deterministic archive format and tool
that transparently expands containers such as ZIP, Office Open XML, EPUB, PDF,
PNG, gzip, and tar before recompressing their meaningful payloads with stronger
compression.

For ZIP-family files, simply inflating each entry and later deflating it again
is content-preserving but not byte-preserving. That is not good enough for
users who need exact restoration of original `.docx`, `.xlsx`, `.epub`, `.jar`,
or `.zip` files.

The intended archive workflow is:

1. During blar archive creation, inflate an embedded DEFLATE stream.
2. Run `deflate_fingerprint` against `(raw bytes, original compressed bytes)`.
3. Store the raw bytes under blar's stronger compression, plus the compact
   fingerprint/config that best reproduces the original stream.
4. On extract, call this encoder with that fingerprint to regenerate the
   DEFLATE stream.
5. If the best reproduction is close but not exact, use `../difz` to store a
   small residual binary patch and apply it during restore.

The practical goal is to recover storage space from already-compressed formats
without giving up byte-identical reconstruction for the archive audiences that
care about it.

## What it does

- Encodes raw input using known DEFLATE behavior profiles.
- Identifies the first registered profile that reproduces a target stream
  byte-for-byte.
- Exposes a Zig API and C FFI suitable for blar and other consumers.
- Provides a CLI for current raw-stream attribution experiments.
- Includes a ZIP-family corpus probe that extracts raw DEFLATE entries from
  `.zip`, `.docx`, `.xlsx`, `.pptx`, `.epub`, `.jar`, `.apk`, and similar files.

Long-term, this should become a general, highly configurable DEFLATE
implementation:

- "Extract"/identify path: return the best-guess fingerprint/config for an
  observed compressed stream.
- Compress/reproduce path: accept an explicit fingerprint/config and emit the
  corresponding DEFLATE bytes.
- Default path: provide a sensible default encoder config, but keep
  reproduction driven by explicit configuration.

## Current CLI

```bash
deflate-fingerprint identify --raw RAW --target TARGET
deflate-fingerprint identify --json --raw RAW --target TARGET
deflate-fingerprint --about
deflate-fingerprint --help
```

Planned CLI surface:

```bash
deflate-fingerprint reproduce ID --raw RAW [--out FILE]
deflate-fingerprint list
```

## Build

Requires [Nix](https://nixos.org/) with flakes enabled.

Use the top-level scripts:

```bash
./build          # ReleaseFast build via nix build
./build --debug  # debug build
./test           # full test suite
./bm             # benchmarks, once implemented
```

On this project, native Zig builds should go through the top-level scripts.
The scripts avoid host macOS / Zig libSystem stub mismatches documented in
`AGENTS.md`.

## Key documents

- [SESSION_RESUME.md](SESSION_RESUME.md) - live checkpoint for the current
  investigation
- [GOALS.md](GOALS.md) - mission, scope, success criteria, audiences
- [DESIGN.md](DESIGN.md) - architectural intent, algorithm, module breakdown
- [PLAN.md](PLAN.md) - phased roadmap and current work items
- [docs/ENCODER_NOTES.md](docs/ENCODER_NOTES.md) - empirical encoder findings
- [docs/DEFLATE_DIALS.md](docs/DEFLATE_DIALS.md) - enumerated DEFLATE choices
- [docs/V0.1_STATUS.md](docs/V0.1_STATUS.md) - current v0.1 implementation status

## License

MIT. Foundational, fully open infrastructure, like BLIP and blar. The
commercial value is downstream; this library benefits the broader archive,
forensics, and reproducible-build ecosystems.
