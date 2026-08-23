# Migrating from 0.4 to 1.0
LibDeflate v1.0 is a thoroughly breaking release.
Follow the guide below when updating to v1.0.
You might want to have an agent go over this document to check your migration.

All function's API now take concrete or `Union` types instead of e.g. `Integer`.
Read the updated function signatures for the now-expected types which may e.g.
be `UInt` instead of `Integer`.
The exception are the 'safe' de/compression functions that take `::Any` input
and outputs; these are immediately turned into `ReadableMemory` and `WriteableMemory`.
Read the signatures in the docstrics for every used function from this library
and check the updated types.

`compress!`, `gzip_compress!`, and `zlib_compress!` no longer resize `output`.
They return the number of bytes written (`UInt`) or a `LibDeflateError`.
Slice the buffer to that length when consuming the result.

Raw DEFLATE decompression now reports both input consumed and output written.

Gzip decompression no longer grows a `Vector` up to `max_len`. Allocate a sufficiently
large `UInt8` output buffer, and pass a `Vector{GzipExtraField}` to receive parsed
extra fields. A single-member result now has `written`, `read`, and `header` properties.

`parse_gzip_header` likewise takes `fields` as a positional argument and returns
`(; read, header)`, instead of `(header_length, header)`. `GzipHeader.extra` is now a
range into that vector, rather than a vector stored in the header. Its `mtime` is
`nothing` when unavailable and `NonZeroUInt32` otherwise; filename and comment remain
ranges into the input. `GzipExtraField.data` is an empty range for an empty field,
rather than `nothing`.

To process concatenated gzip members, use the new `gzip_decompress_all!` with a
`GzipDecompressAllScratch`.

Gzip compression no longer writes the current time by default. Set `mtime` explicitly
with `NonZeroUInt32(value)` when it is available, or leave it as `nothing`.

The unsafe functions no longer take pointer/length pairs or a `Base.HasLength`/
`Base.SizeUnknown` argument, but take `ReadableMemory` and/or `WriteableMemory`.

`ReadableMemory` and `WriteableMemory` now intentionally accept byte-oriented
containers rather than arbitrary bitstype arrays. Convert data to `UInt8` first, or
define the appropriate wrapper constructor for a custom container.

`LibDeflateError` names were consolidated and made more specific. Update code that
matches error values rather than relying on their numeric representation. In particular:

* `gzip_header_too_short` and `zlib_input_too_short` become `input_too_short`.
* `gzip_not_deflate` and `zlib_not_deflate` become `not_deflate`.
* `deflate_insufficient_space` and `zlib_insufficient_space` become
  `insufficient_output_space` where applicable.
* Gzip string and metadata errors are split into filename/comment-specific values, and
  `gzip_bad_flags` becomes `gzip_reserved_flags_set`.
* zlib errors are renamed to `zlib_bad_window_size`, `zlib_dictionary_required`,
  `zlib_bad_header_checksum`, and `zlib_bad_adler32`.
