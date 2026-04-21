# JiPatcher.jl — Internal: rewrite include-records inside Julia .ji cache files.
#
# Background
# ==========
# A Julia precompile cache (.ji) records, per included source file, a triple
#   (fsize::UInt64, hash::UInt32, mtime::Float64)
# inside its header. At load time `Base.any_includes_stale` re-stats every
# include and rejects the cache unless these match.
#
# Therefore, if we want to *modify* the .jl source after precompilation
# without forcing recompilation, we must rewrite those triples inside the
# .ji to match the new file content, then recompute the trailing CRC32c
# checksum of the .ji.
#
# The .so pkgimage has its own separate trailing CRC over the .so contents
# itself; we never touch the .so so it stays valid.
#
# Format reference
# ================
# Re-implements the byte layout from Julia 1.12's
# `Base._parse_cache_header` in stdlib/loading.jl. Each version branch lives
# in `_layout_for_version()`. To support a new Julia release:
#   1. Diff the upstream `_parse_cache_header` against the version we know.
#   2. If the include-record layout (fsize/hash/mtime triple) is unchanged
#      and the trailing-CRC scheme (last 4 bytes = crc32c of all preceding
#      bytes) is unchanged, just add the new VERSION to SUPPORTED_VERSIONS.
#   3. Otherwise, add a new branch in `_layout_for_version` and a new
#      `_locate_include_offsets_v<N>` function.
#
# Public API
# ==========
#   patch_ji!(jifile::String, src_dir::String) -> Int
#       Rewrites every include record in `jifile` whose `.filename` points
#       inside `src_dir` so it matches the file on disk now. Returns the
#       number of records updated.

module JiPatcher

using SHA: SHA  # not actually used; just present so deps are explicit
using CRC32c: crc32c

export patch_ji!, SUPPORTED_VERSIONS, is_supported

"Julia versions whose .ji include-record layout we understand."
const SUPPORTED_VERSIONS = [v"1.10", v"1.11", v"1.12"]

"Returns true if running on a Julia version whose .ji format we know."
is_supported() = any(v -> VERSION.major == v.major && VERSION.minor == v.minor,
                     SUPPORTED_VERSIONS)

# ---------------------------------------------------------------------------
# Layout description
# ---------------------------------------------------------------------------

"Per-include record offsets inside the .ji header (relative to file start)."
struct IncludeRecordOffset
    filename::String        # decoded filename string
    fsize_off::Int64        # byte offset of UInt64 fsize field
    hash_off::Int64         # byte offset of UInt32 hash field
    mtime_off::Int64        # byte offset of Float64 mtime field
end

# ---------------------------------------------------------------------------
# Format readers (Julia 1.10 / 1.11 / 1.12 share this layout)
# ---------------------------------------------------------------------------

# Read the same magic / preamble that Base.isvalid_cache_header reads.
# We just need to advance the read pointer past it.
function _skip_cache_header_preamble(io::IO)
    # Replicate Base.isvalid_cache_header's read pattern. The exact byte
    # contents we don't care about — only that `io` ends up pointing at the
    # first byte after the preamble (== flags::UInt8).
    Base.isvalid_cache_header(io) == 0 && error("invalid .ji header")
    # isvalid_cache_header already left io at the byte after the preamble
    return nothing
end

# Read a length-prefixed module list, mirroring Base.read_module_list.
function _skip_module_list!(io::IO, has_buildid_hi::Bool)
    while true
        n = read(io, Int32)
        n == 0 && break
        skip(io, n)                       # symbol bytes
        skip(io, 16)                      # uuid (2 × UInt64)
        if has_buildid_hi
            skip(io, 8)                   # build_id_hi
        end
        skip(io, 8)                       # build_id_lo
    end
end

"""
Parse the .ji header up through the includes section, recording the byte
offsets of the (fsize, hash, mtime) triple for every include entry.

Returns `(offsets::Vector{IncludeRecordOffset}, header_end_pos::Int64)`.
"""
function _scan_include_offsets(io::IO)
    seekstart(io)
    _skip_cache_header_preamble(io)
    skip(io, 1)                                   # flags::UInt8
    _skip_module_list!(io, false)                 # `modules`
    skip(io, 8)                                   # totbytes::UInt64

    offsets = IncludeRecordOffset[]
    while true
        n2 = read(io, Int32)
        n2 == 0 && break
        depname_bytes = read(io, n2)
        # IMPORTANT: snapshot the leading byte BEFORE handing the buffer to
        # `String`, because `String(::Vector{UInt8})` takes ownership and
        # leaves `depname_bytes` empty, which would falsely look like a
        # `requires` record (and silently skip every include).
        leading = isempty(depname_bytes) ? UInt8(0) : depname_bytes[1]
        depname = String(depname_bytes)

        fsize_off = position(io)
        skip(io, 8)                               # fsize::UInt64
        hash_off  = position(io)
        skip(io, 4)                               # hash::UInt32
        mtime_off = position(io)
        skip(io, 8)                               # mtime::Float64

        n1 = read(io, Int32)                      # module id
        if n1 != 0
            # modpath strings, terminated by Int32(0)
            while true
                m = read(io, Int32)
                m == 0 && break
                skip(io, m)
            end
        end

        # `requires` records have a leading NUL — those are not includes.
        if leading != UInt8('\0')
            push!(offsets, IncludeRecordOffset(depname, fsize_off, hash_off, mtime_off))
        end
    end
    return offsets
end

# ---------------------------------------------------------------------------
# Patching
# ---------------------------------------------------------------------------

"Compute the (fsize, crc32c-hash) pair Julia would record for a path on disk."
function _file_sig(path::AbstractString)
    if isdir(path)
        return (UInt64(0), crc32c(join(readdir(path))))
    else
        sz = UInt64(filesize(path))
        h  = open(crc32c, path, "r")
        return (sz, h)
    end
end

"""
    patch_ji!(jifile, predicate) -> Int

Rewrite every include record whose filename satisfies `predicate(filename)`
to match the current on-disk content of that file. Returns the number of
records updated.

Also recomputes the trailing UInt32 CRC32c at the end of the .ji so the
file remains a valid Julia cache.
"""
function patch_ji!(jifile::AbstractString, predicate::Function)
    is_supported() ||
        error("JiPatcher: unsupported Julia version $VERSION " *
              "(known: $SUPPORTED_VERSIONS)")

    # 1. Scan offsets
    offsets = open(_scan_include_offsets, jifile, "r")

    # 2. Decide which records to patch (filename matches predicate AND file
    #    actually exists on disk so we can re-hash it)
    targets = IncludeRecordOffset[]
    for rec in offsets
        predicate(rec.filename) || continue
        ispath(rec.filename) || continue
        push!(targets, rec)
    end

    isempty(targets) && return 0

    # 3. Open rw and rewrite triples + trailing CRC
    open(jifile, "r+") do io
        for rec in targets
            sz, h = _file_sig(rec.filename)
            seek(io, rec.fsize_off);  write(io, sz)
            seek(io, rec.hash_off);   write(io, h)
            seek(io, rec.mtime_off);  write(io, Float64(mtime(rec.filename)))
        end
        flush(io)

        # Recompute trailing whole-file CRC32c (last 4 bytes).
        # _crc32c spec: covers file[0 : end-4].
        seekstart(io)
        total = filesize(jifile)
        body  = read(io, total - 4)
        new_crc = crc32c(body)
        seek(io, total - 4)
        write(io, new_crc)
    end

    return length(targets)
end

"""
    patch_ji!(jifile, src_dir::AbstractString) -> Int

Convenience overload: patch every include record whose filename starts with
`src_dir`.
"""
function patch_ji!(jifile::AbstractString, src_dir::AbstractString)
    src_abs = abspath(src_dir) * "/"
    return patch_ji!(jifile, fn -> startswith(abspath(fn), src_abs))
end

end # module
