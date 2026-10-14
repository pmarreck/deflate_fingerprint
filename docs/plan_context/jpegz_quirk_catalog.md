# jpegz encoder-quirk catalog (sibling coordination)

In May 2026 the tiffz project noted that jpegz, a sibling JPEG decoder/validator, is growing
an encoder-quirk catalog that parallels this project on the JPEG side. jpegz surfaces quirks
as `FindingCode` warnings during validation, for example restart-marker cadence mismatches,
extraneous bytes before markers, and APP14 ColorTransform conflicting with JFIF.

Possible coordination, none of it requested or committed:

1. Shared naming for encoder-quirk findings, e.g. a `<vendor>_<format>_<quirk>` pattern, so
   cross-codec joins are easy (one PDF's JPEG and Deflate streams attributed together).
2. The `validate` tool as integration point: it already routes jpegz findings in its TIFF
   lane, and could surface DEFLATE attribution for the same file through a similar API.
3. Shared ground-truth corpora: files from known producers often contain both JPEG and
   DEFLATE streams, which allows cross-corroborated attribution.

Any finding or verdict surfaced through `validate` must follow that project's published
status contract rather than introducing new statuses here.
