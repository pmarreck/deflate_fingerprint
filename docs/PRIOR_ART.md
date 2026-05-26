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
