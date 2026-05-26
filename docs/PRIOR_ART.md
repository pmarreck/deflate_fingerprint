# DEFLATE Recompression Prior Art

This project should learn from earlier DEFLATE recompression systems while
keeping its core RFC 1951-focused, Zig-native, C-FFI-friendly, and legally
clean. Do not copy code blindly. Prefer extracting architecture, tests,
observable behavior, and corpus ideas.

## Summary

| Project | License / availability | What it proves | What to mine |
|---|---|---|---|
| `precomp-cpp` | Apache-2.0 | Container-aware precompression is practical across ZIP, PNG, PDF, gzip, and related formats. | Container triage strategy, fallback economics, public corpus ideas. |
| `preflate` | Apache-2.0 | Raw-DEFLATE prediction plus correction can reconstruct zlib streams with tiny metadata and non-zlib streams with typed corrective data. | Parameter estimator design, zlib compatibility checks, correction categories. |
| `preflate-rs` | Apache-2.0 | Modern active implementation: parse, estimate, predict, CABAC-code corrections, and reconstruct exact DEFLATE streams. | Correction enum taxonomy, chunked streaming shape, supported encoder families, corpus samples. |
| `grittibanzli` | Apache-2.0 | Exact reconstruction can be expressed as uncompressed data plus a highly compressible "choices" stream, independent of the upstream compressor. | Simple choices-stream baseline, economics measurements for gzip/zopfli/low-level streams. |
| `reflate` | Closed source / not mineable | Comparative evidence that all-stream reconstruction is possible, but not a usable code source. | High-level claims only; do not depend on it or copy from it. |

## Architectural Lessons

- **Prediction plus correction is the stable architecture.** A finite registry
  of compressor dials is valuable because it drives correction size toward
  zero, but exact reconstruction needs an explicit residual path for streams
  outside the dial model.
- **The correction layer should be typed DEFLATE events.** Encode residuals
  over block types, token counts, literal-vs-reference decisions, lengths,
  distances, dynamic Huffman tree decisions, and flush/final markers. Avoid
  byte diffs over packed DEFLATE as the primary format because bit shifts
  create synchronization noise.
- **Distance corrections should use predictor-native coordinates.**
  `preflate-rs` encodes incorrect distances as hops through the hash chain,
  which is more compact than absolute distance replacement when the predictor
  found the right neighborhood but the wrong candidate.
- **Dynamic Huffman reconstruction is its own correction subproblem.** Treat
  literal-count, distance-count, tree-code bit length, LD type, repeat count,
  and LD bit length corrections separately instead of storing full Huffman
  headers whenever one choice differs.
- **Chunking is an API requirement, not an optimization.** Large Office/PDF/PNG
  streams need bounded-memory analysis and recreation. The DFP surrogate
  container should allow chunked raw data plus per-chunk correction/config
  records.
- **Unknown compressors should still round-trip.** Exact-known fingerprints
  produce empty or near-empty corrections; zopfli/kzip/7-Zip optimal-parser
  streams may produce larger structural corrections. The packer decides per
  stream whether corrected recompression beats storing the original DEFLATE
  blob.

## Where DFP Must Exceed Prior Art

Prior art proves the category is real. DFP needs to be better in at least one
clear dimension to justify new implementation work.

Target differentiators:

- **Forensic attribution, not just recompression.** Existing systems primarily
  optimize storage. DFP should expose the recovered encoder family, parameters,
  confidence, competing candidates, and corpus-derived evidence in a stable API
  and CLI report.
- **Transparent, append-only fingerprint registry.** Fingerprints should be
  named, versioned, documented, and reproducible from public generator-oracle
  tests. Users should be able to ask "why was this stream called zlib L6
  memLevel=9?" and inspect the evidence.
- **Zig core plus C FFI as the first-class product.** DFP should remain easy to
  embed from C, Swift, C#, Java, Rust, scripting runtimes, and forensic tools
  without pulling in Rust/C++ runtimes or external compressor libraries at
  restore time.
- **Corpus coverage as a measured artifact.** DFP should publish coverage by
  container family, producer, encoder, stream size bucket, and correction
  overhead. A stream is not merely "handled"; its behavior is classified.
- **Container-agnostic RFC 1951 core with adapter evidence.** Precomp-style
  container support is useful, but DFP's core should stay raw-DEFLATE while
  test adapters prove coverage for ZIP-family, PNG, PDF, gzip, iWork, Office,
  EPUB, APK/JAR/WHL/XPI/VSIX, and similar sources.
- **Native fallback economics.** The packer should always choose the smaller of
  corrected recompression and stored-original DEFLATE, making worst-case output
  predictable and safe for upstream archivers.
- **Clean-room extensibility for new encoders.** Adding libdeflate, zlib-ng,
  miniz, Go, .NET, Java, Apple/CoreFoundation, or legacy PKZIP should mean
  adding observable parameters, oracle fixtures, and tests, not grafting in an
  opaque foreign encoder.
- **Potential `difz` integration as an outer fallback.** If Peter adds
  bit-oriented sliding-window mode to `difz`, DFP can benchmark it as a
  last-resort packed-stream residual. The project should still prefer typed
  DEFLATE corrections when parsing succeeds.

Candidate v1.0 "exceeds prior art" success criteria:

- Publicly documented registry entries for every exact predictor, including
  source evidence and reproduction tests.
- Exact raw-DEFLATE reconstruction for known zlib-family streams with zero or
  near-zero correction overhead.
- Corrected round-trip for arbitrary valid RFC 1951 streams, subject to the
  per-stream stored-original fallback rule.
- Coverage reports across real and generated corpora, including correction
  overhead histograms and miss classifications.
- Stable C FFI for `fingerprint`, `compress`, `decompress`, `pack`, and
  `unpack`.

## Relationship To `difz`

`difz` is a strong byte-level binary differ using CDC, Myers gap refinement,
and BLIP encoding. A bit-oriented sliding-window mode would be useful for
diagnostics and as a last-resort packed-DEFLATE fallback, especially when DFP
cannot parse or semantically align a damaged/hostile stream.

It should not replace the DFP event correction format:

- A bit differ still sees the packed representation, so a wrong token or tree
  decision can require resynchronization work that is not informational.
- A token/event correction can say "the predicted match should be candidate
  hop 3 with length 42" instead of patching the emitted Huffman-coded bits.
- `difz` remains useful for wrappers and containers outside RFC 1951, for
  already-realigned payloads, and for an economics fallback when event
  correction has not yet been implemented.

## Concrete DFP Work Items

- Define a versioned DFP surrogate container, preferably BLIP/BLAR-shaped, with
  `raw`, `config`, optional `correction`, optional `original_deflate`, mode,
  sizes, and hashes.
- Add `pack(deflate) -> container` and `unpack(container) -> deflate` tests
  before exposing CLI commands.
- Model the first correction enum after the preflate-rs categories, but encode
  it in project-native Zig/BLIP terms.
- Add corpus probes that report correction-size estimates even when exact
  config reproduction fails.
- Keep studying prior art with a clean-room mindset: record behavior and public
  test vectors; avoid transplanting implementation code unless Peter approves
  the license/compliance path explicitly.

## Sources Checked

- `precomp-cpp`: <https://github.com/schnaader/precomp-cpp>
- `preflate`: <https://github.com/deus-libri/preflate>
- `preflate-rs`: <https://github.com/microsoft/preflate-rs>
- `grittibanzli`: <https://github.com/google/grittibanzli>
