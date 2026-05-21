# deflate_fingerprint

Identify which DEFLATE encoder implementation produced a given compressed byte stream by reproducing the byte-exact output from the original uncompressed data.

**Status**: scaffolded. Implementation pending.

## What it does

DEFLATE (RFC 1951) defines decoding exactly but leaves encoding largely free. Different encoders — even the same encoder at different "levels" — produce different bytes for the same input. `deflate_fingerprint` recovers the encoder identity from observed output, enabling:

- **Byte-identical archive round-tripping** of ZIP-based formats (`.docx`, `.xlsx`, `.pptx`, `.epub`, `.jar`, `.zip`) — primary consumer is [Mecha Archiver](https://mecha.llc/)
- **Digital forensics** — attribute artifacts to specific tools / versions
- **Build-reproducibility audits** — cryptographic provenance for DEFLATE-containing artifacts (`.whl`, `.deb`, `.apk`, etc.)
- **Format archaeology** — identify tools used in legacy archives
- **Storage deduplication** — improve dedup ratios on heterogeneously-compressed corpora

## Key documents

- [GOALS.md](GOALS.md) — mission, scope, success criteria, audiences
- [DESIGN.md](DESIGN.md) — architectural intent, algorithm, module breakdown
- [PLAN.md](PLAN.md) — phased roadmap

## License

MIT. Foundational, fully open infrastructure (like [BLIP](https://github.com/pmarreck/BLIP) and [difz](https://github.com/pmarreck/difz)). The commercial moat is downstream consumers; this tool benefits the broader ecosystem.

## Build

Requires [Nix](https://nixos.org/) with flakes enabled.

```bash
./build         # build (ReleaseFast via nix build)
./build --debug # debug build
./test          # run all tests
./bm            # run benchmarks (when implemented)
```

Or directly:

```bash
nix build
nix develop -c zig build -Doptimize=ReleaseFast
```

## CLI usage (planned)

```bash
deflate-fingerprint identify FILE       # attribute DEFLATE streams in FILE
deflate-fingerprint reproduce ID RAW    # encode RAW using fingerprint ID
deflate-fingerprint list                # list known fingerprints
deflate-fingerprint --about             # version + platform
deflate-fingerprint --help
```
