# zlib wrapper representation (open decision)

Context for the PLAN.md item about how zlib fingerprints are represented in code.

The 2026-06-01 fleet code review (suite grew 119 → 131 tests) flagged, as INFO, that the
`encodeZlibLevel{N}[Mem{M}]` wrappers in `src/encoder.zig` are thin shims over
`encodeZlib{Fast,Slow}MemLevel`. Each one is still load-bearing as a named `.encode`
function pointer in the `FINGERPRINTS` registry (`src/lib.zig`), and several carry
rationale doc comments.

Options recorded at the time, plus the older v0.1 item about module layout:

- Safe: leave as-is (explicit, documented, greppable from the registry).
- Bold: replace with a comptime factory such as `fn zlibFast(comptime level, comptime mem)`
  inlined at registry call sites; removes about 20 wrappers but loses per-wrapper doc comments.
- Promote the inline zlib registry/encoder functions into `src/encoder_zlib.zig` behavior
  tables before the v0.1 release.

The project's refactor rule requires BDFN (Benevolent Dictator For Now) to choose between
safe and bold refactors, so this stays open until that choice is made.

Resolution (2026-10-20): BDFN shelved the project until further notice, so no refactor is planned. The existing named wrappers remain.
