# Corpus Workflow

`deflate_fingerprint` is corpus-driven, but corpus data has different safety
levels. Keep the distinction explicit:

| Location | Purpose | Committed? | CI? |
|---|---|---|---|
| `tests/corpus/corpus_public/` | Synthetic fixtures and permissively licensed public samples | yes | yes |
| `tests/corpus/corpus_local/` | Deterministic samples from Peter's NAS or other private sources | no | no |
| `tests/corpus/corpus_private/` | Hand-curated sensitive or unpublished reproductions | no | no |

The public corpus is the reproducible baseline. The local/private corpora are
the expressive baseline: they expose old generators, vendor quirks, and files
that cannot be redistributed.

## Rules

- Never commit personal files, raw extracted payloads from personal files, or
  manifests containing absolute private paths.
- Public reports may include aggregate counts, hit rates, fingerprint IDs,
  compressed/raw sizes, and sanitized producer/version metadata.
- Public reports must not include private filenames, directory names, document
  text, or full binary payloads.
- If a local file exposes an important miss and is safe to redistribute, Peter
  can manually promote it to `tests/corpus/corpus_public/<format>/<source>/`.
- Near-matches are evidence for future reverse-engineering, not substitutes for
  byte-exact fingerprint/config reproduction.

## Local NAS Sampling

Use the helper below to sample without committing data:

```bash
tests/corpus/scripts/sample_local --nas-root /Volumes/Fileserver --n 25
tests/corpus/scripts/sample_local --format xlsx --dry-run
tests/corpus/scripts/sample_local --dest-root /tmp/dfp-local-corpus --format epub
```

The helper uses `rg --files` rather than `find`, because ripgrep parallelizes
directory walking and behaves better on network mounts. Output lands under
`tests/corpus/corpus_local/<format>/wild/`, which is gitignored.

## Stream Metadata

For every extracted DEFLATE stream, track this shape in local manifests or
public fixture metadata:

- `corpus`: `public`, `local`, or `private`
- `source_id`: stable sanitized ID, never a private absolute path
- `container_type`: `zip`, `xlsx`, `png`, `pdf`, `gzip`, `iwork`, etc.
- `entry_path`: container-relative member/object path when safe to disclose
- `raw_len` and `compressed_len`
- `container_metadata`: ZIP method/version bits, PDF object/filter metadata,
  PNG chunk metadata, or analogous wrapper details
- `producer_metadata`: application/version/platform when known
- `observed_features`: block sequence, flush schedule, token cadence, Huffman
  header shape, and first-divergence information
- `expected_config`: generic fingerprint/config only after byte-exact
  reproduction is proven
