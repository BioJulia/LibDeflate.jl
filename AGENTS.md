# Coding guidelines for AI agents
This LibDeflate.jl Julia package provides Julia bindings for the C library `libdeflate`, which provides highly optimized implementation of DEFLATE, CRC32 and Adler32.
It also provides some Julia-level parsing of the gzip and zlib formats.

This package prioritizes performance and low level control over high-level convenience. Performance and correctness are paramount.
Unlike Base Julia, this package does not default to the Int type for convenience, but chooses integer types based on their possible values, to achieve for explicitness and performance.

After making code changes, format by running `runic -i .`. If this fails (e.g. the user has not installed Runic), do not attempt to install Runic, but alert the user that it failed.

