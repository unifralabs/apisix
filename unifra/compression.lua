--
-- Unifra Compression Module
-- Provides gzip compression and decompression using LuaJIT FFI
--
-- This module handles Content-Encoding: gzip for incoming requests
-- and can be used for response compression as well.
--

local ffi = require("ffi")

local _M = {
    version = "1.0.0"
}

-- zlib FFI definitions
ffi.cdef[[
    typedef void* voidp;
    typedef unsigned int uInt;
    typedef unsigned long uLong;
    typedef unsigned char Byte;
    typedef Byte* Bytef;

    typedef struct z_stream_s {
        Bytef*   next_in;
        uInt     avail_in;
        uLong    total_in;
        Bytef*   next_out;
        uInt     avail_out;
        uLong    total_out;
        char*    msg;
        void*    state;
        voidp    zalloc;
        voidp    zfree;
        voidp    opaque;
        int      data_type;
        uLong    adler;
        uLong    reserved;
    } z_stream;

    int inflateInit2_(z_stream* strm, int windowBits, const char* version, int stream_size);
    int inflate(z_stream* strm, int flush);
    int inflateEnd(z_stream* strm);

    int deflateInit2_(z_stream* strm, int level, int method, int windowBits,
                      int memLevel, int strategy, const char* version, int stream_size);
    int deflate(z_stream* strm, int flush);
    int deflateEnd(z_stream* strm);

    uLong compressBound(uLong sourceLen);
    const char* zlibVersion(void);
]]

-- Load zlib library
local zlib = ffi.load("z")

-- zlib constants
local Z_OK = 0
local Z_STREAM_END = 1
local Z_NEED_DICT = 2
local Z_ERRNO = -1
local Z_STREAM_ERROR = -2
local Z_DATA_ERROR = -3
local Z_MEM_ERROR = -4
local Z_BUF_ERROR = -5
local Z_VERSION_ERROR = -6

local Z_NO_FLUSH = 0
local Z_PARTIAL_FLUSH = 1
local Z_SYNC_FLUSH = 2
local Z_FULL_FLUSH = 3
local Z_FINISH = 4

local Z_DEFLATED = 8
local Z_DEFAULT_COMPRESSION = -1
local Z_DEFAULT_STRATEGY = 0
local MAX_WBITS = 15

-- windowBits + 16 for gzip format, + 32 for auto-detect gzip/zlib
local GZIP_WINDOW_BITS = MAX_WBITS + 16
local AUTO_DETECT_WINDOW_BITS = MAX_WBITS + 32

-- Buffer size for compression/decompression (16KB)
local CHUNK_SIZE = 16384

-- Maximum decompressed size (10MB) to prevent zip bombs
local MAX_DECOMPRESSED_SIZE = 10 * 1024 * 1024

-- Get zlib version string
local ZLIB_VERSION = ffi.string(zlib.zlibVersion())


--- Decompress gzip data
-- @param data string The gzip compressed data
-- @return string|nil Decompressed data
-- @return string|nil Error message
function _M.gunzip(data)
    if not data or #data == 0 then
        return nil, "empty data"
    end

    -- Allocate z_stream
    local stream = ffi.new("z_stream")
    stream.zalloc = nil
    stream.zfree = nil
    stream.opaque = nil

    -- Initialize for gzip decompression (auto-detect gzip or zlib)
    local ret = zlib.inflateInit2_(
        stream,
        AUTO_DETECT_WINDOW_BITS,  -- Auto-detect gzip/zlib
        ZLIB_VERSION,
        ffi.sizeof("z_stream")
    )

    if ret ~= Z_OK then
        return nil, "inflateInit2 failed: " .. ret
    end

    -- Set input
    local input_buf = ffi.new("uint8_t[?]", #data)
    ffi.copy(input_buf, data, #data)
    stream.next_in = ffi.cast("Bytef*", input_buf)
    stream.avail_in = #data

    -- Output buffer
    local output_buf = ffi.new("uint8_t[?]", CHUNK_SIZE)
    local output_parts = {}
    local total_output = 0

    -- Decompress loop
    repeat
        stream.next_out = ffi.cast("Bytef*", output_buf)
        stream.avail_out = CHUNK_SIZE

        ret = zlib.inflate(stream, Z_NO_FLUSH)

        if ret == Z_STREAM_ERROR or ret == Z_DATA_ERROR or ret == Z_MEM_ERROR then
            zlib.inflateEnd(stream)
            local err_msg = "inflate failed: " .. ret
            if stream.msg ~= nil then
                err_msg = err_msg .. " - " .. ffi.string(stream.msg)
            end
            return nil, err_msg
        end

        local have = CHUNK_SIZE - stream.avail_out
        if have > 0 then
            total_output = total_output + have

            -- Check for zip bomb
            if total_output > MAX_DECOMPRESSED_SIZE then
                zlib.inflateEnd(stream)
                return nil, "decompressed size exceeds limit"
            end

            output_parts[#output_parts + 1] = ffi.string(output_buf, have)
        end
    until ret == Z_STREAM_END or stream.avail_out ~= 0

    zlib.inflateEnd(stream)

    if ret ~= Z_STREAM_END then
        return nil, "incomplete gzip stream"
    end

    return table.concat(output_parts), nil
end


--- Compress data to gzip format
-- @param data string The data to compress
-- @param level number Compression level 1-9 (optional, default 6)
-- @return string|nil Compressed data
-- @return string|nil Error message
function _M.gzip(data, level)
    if not data or #data == 0 then
        return nil, "empty data"
    end

    level = level or 6  -- Default compression level

    -- Allocate z_stream
    local stream = ffi.new("z_stream")
    stream.zalloc = nil
    stream.zfree = nil
    stream.opaque = nil

    -- Initialize for gzip compression
    local ret = zlib.deflateInit2_(
        stream,
        level,
        Z_DEFLATED,
        GZIP_WINDOW_BITS,  -- gzip format
        8,  -- memLevel
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        ffi.sizeof("z_stream")
    )

    if ret ~= Z_OK then
        return nil, "deflateInit2 failed: " .. ret
    end

    -- Set input
    local input_buf = ffi.new("uint8_t[?]", #data)
    ffi.copy(input_buf, data, #data)
    stream.next_in = ffi.cast("Bytef*", input_buf)
    stream.avail_in = #data

    -- Estimate output size
    local bound = tonumber(zlib.compressBound(#data))
    local output_buf = ffi.new("uint8_t[?]", bound + 18)  -- +18 for gzip header/trailer
    local output_parts = {}

    -- Compress loop
    repeat
        stream.next_out = ffi.cast("Bytef*", output_buf)
        stream.avail_out = bound + 18

        ret = zlib.deflate(stream, Z_FINISH)

        if ret == Z_STREAM_ERROR then
            zlib.deflateEnd(stream)
            return nil, "deflate failed: " .. ret
        end

        local have = (bound + 18) - stream.avail_out
        if have > 0 then
            output_parts[#output_parts + 1] = ffi.string(output_buf, have)
        end
    until ret == Z_STREAM_END

    zlib.deflateEnd(stream)

    return table.concat(output_parts), nil
end


--- Check if data looks like gzip (magic bytes)
-- @param data string First few bytes of data
-- @return boolean
function _M.is_gzip(data)
    if not data or #data < 2 then
        return false
    end
    -- Gzip magic bytes: 0x1f 0x8b
    return data:byte(1) == 0x1f and data:byte(2) == 0x8b
end


return _M
