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

- 32 fingerprints registered: zlib level 0, zlib levels 1-9 across default /
  fixed / filtered strategies, collapsed zlib HUFFMAN_ONLY and RLE fingerprints,
  zlib L1 explicit `SYNC_FLUSH` + empty finish handling, and zlib L6
  memLevel 6/7/9 pending-buffer variants plus Info-ZIP-style 4096-symbol
  profitability flushes observed in ZIP-family streams.
- `./test` currently passes 163 tests: Zig unit tests, CLI integration tests,
  real-zlib fidelity checks, and the internal corpus hit-rate sweep.
- Internal project-file corpus: 100% hit rate across 500 generated raw-DEFLATE
  streams.
- Real-world ZIP-family probing is underway. Current checkpoint hit rates are
  recorded in [SESSION_RESUME.md](SESSION_RESUME.md).
- The first 200 mixed local ZIP-family DEFLATE streams currently reproduce at
  100.0% exact coverage after adding zlib L6 memLevel=9 and generic
  Info-ZIP-style 4096-symbol profitability flush profiles.
- Active research target: large ZIP-family XML streams with non-default flush
  topology. The core now models these as abstract `DeflateReproductionConfig`
  values with per-offset `FlushEvent` counts derived from the target stream,
  including empty fixed-before-stored marker sequences; `fingerprintConfigured`
  can recover a byte-exact generic config for observed flush/finish streams,
  while named producer details such as Excel worksheet structure live in
  probes/tests rather than the main encoder.
- Planned corpus coverage explicitly includes broader Office/iWork documents,
  EPUB, PDF FlateDecode streams, PNG IDAT streams, gzip, and outputs generated
  by zlib, libdeflate, 7-Zip, miniz, Go, .NET, Java, and Apple/CoreFoundation.
- ZIP-container coverage is intentionally broad: `.zip`, `.jar`, `.war`,
  `.ear`, `.apk`, `.ipa`, `.whl`, `.xpi`, `.crx`, `.vsix`, `.odt`, `.ods`,
  `.odp`, `.epub`, `.cbz`, and OOXML files reuse the same generic
  method=8 entry walker before any format-specific metadata is layered on.

## Why it exists

The downstream consumer is `../blar`, a deterministic archive format and tool
that transparently expands containers such as ZIP, Office Open XML, EPUB, PDF,
PNG, gzip, and tar before recompressing their meaningful payloads with stronger
compression.

For ZIP-family files, simply inflating each entry and later deflating it again
is content-preserving but not byte-preserving. That is not good enough for
users who need exact restoration of original `.docx`, `.xlsx`, `.epub`, `.jar`,
or `.zip` files.

The same byte-identity requirement applies to PNG IDAT data, PDF FlateDecode
streams, gzip payloads, iWork packages, and any other embedded RFC 1951 stream.
Container syntax, PNG filters, PDF object layout, and wrapper bytes are handled
by format adapters/tests or upstream consumers; the core responsibility here is
to identify and reproduce the embedded DEFLATE bytes exactly.

The intended archive workflow is:

1. During blar archive creation, inflate an embedded DEFLATE stream.
2. Run `deflate_fingerprint` against `(raw bytes, original compressed bytes)`.
3. Store the raw bytes under blar's stronger compression, plus the compact
   fingerprint/config that best reproduces the original stream.
4. On extract, call this encoder with that fingerprint to regenerate the
   DEFLATE stream.
5. If the best reproduction is close but not exact, store a compact
   DEFLATE-aware correction stream and apply it during restore. This residual
   must be described at the token/block/Huffman-decision level, not as a
   naive byte diff of the final packed DEFLATE bytes, because one wrong
   bit-aligned decision shifts every downstream byte.
6. For each stream, choose the smaller representation: recompressed raw data
   plus fingerprint/config/correction, or the original compressed bytes stored
   as-is.

The practical goal is to recover storage space from already-compressed formats
without giving up byte-identical reconstruction for the archive audiences that
care about it.

## What it does

- Encodes raw input using known DEFLATE behavior profiles.
- Identifies the first registered profile that reproduces a target stream
  byte-for-byte.
- Exposes a Zig API and C FFI suitable for blar and other consumers, including
  explicit config-driven compression via `dfp_encode_configured`.
- Provides a CLI for current raw-stream attribution experiments.
- Includes a ZIP-family corpus probe that extracts raw DEFLATE entries from
  `.zip`, `.docx`, `.xlsx`, `.pptx`, `.epub`, `.jar`, `.apk`, `.whl`, `.xpi`,
  `.odt`, `.ods`, `.cbz`, and similar files.
- Includes a PNG IDAT probe that concatenates IDAT chunks, preserves zlib
  wrapper metadata, strips to the raw RFC 1951 body, inflates to PNG-filtered
  bytes, runs the same fingerprint/config path, and reports sanitized
  aggregate miss features such as 4096-token dynamic blocks and empty fixed
  markers.
- Will add corpus probes for PDF, iWork, gzip, and generator-oracle outputs from
  external DEFLATE implementations. Those tools may be development-only
  dependencies supplied by `flake.nix`.

Long-term, this should become a general, highly configurable DEFLATE
implementation:

- "Extract"/identify path: return the best-guess fingerprint/config for an
  observed compressed stream, plus confidence and optional correction data.
- Compress/reproduce path: accept an explicit fingerprint/config and emit the
  corresponding DEFLATE bytes, applying correction data when exact
  reproduction cannot be expressed by config alone.
- Default path: provide a sensible default encoder config, but keep
  reproduction driven by explicit configuration.

The main research loop is corpus-driven: produce outputs from known encoder
implementations, harvest embedded DEFLATE streams from real files, classify
their observed block/flush/token behavior, then promote only byte-exact generic
reproductions into the fingerprint/config registry.

For zlib-like and Info-ZIP-like streams, the intended correction payload is
usually empty: the fingerprint/config alone should reproduce the target. For
optimal or combinatorial encoders such as zopfli, kzip, and some 7-Zip modes,
the parse can be structurally different from any zlib-heuristic prediction. In
those cases, exact restoration is still possible, but economics must be decided
per stream by comparing the corrected representation against storing the
original DEFLATE blob.

Corpus data is split into committed public fixtures and gitignored
local/private corpora. See `docs/CORPUS_WORKFLOW.md` before sampling from a NAS
or promoting a reproduction fixture.

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
- [docs/PRIOR_ART.md](docs/PRIOR_ART.md) - prior-art notes for
  precomp/preflate/preflate-rs/grittibanzli/reflate and how their ideas map to
  this project
- [docs/ENCODER_NOTES.md](docs/ENCODER_NOTES.md) - empirical encoder findings
- [docs/DEFLATE_DIALS.md](docs/DEFLATE_DIALS.md) - enumerated DEFLATE choices
- [docs/V0.1_STATUS.md](docs/V0.1_STATUS.md) - current v0.1 implementation status

## License

MIT. Foundational, fully open infrastructure, like BLIP and blar. The
commercial value is downstream; this library benefits the broader archive,
forensics, and reproducible-build ecosystems.
