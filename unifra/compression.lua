--
-- Unifra Compression Module
-- Provides gzip compression and decompression using lua-ffi-zlib
--
-- This module handles Content-Encoding: gzip for incoming requests
-- and can be used for response compression as well.
--
-- Uses lua-ffi-zlib (https://github.com/hamishforbes/lua-ffi-zlib)
-- which is already included in APISIX dependencies.
--

local zlib = require("ffi-zlib")

local _M = {
    version = "1.1.0"
}

-- Maximum decompressed size (10MB) to prevent zip bombs
local MAX_DECOMPRESSED_SIZE = 10 * 1024 * 1024

-- Default buffer size (16KB)
local CHUNK_SIZE = 16384


--- Decompress gzip data
-- @param data string The gzip compressed data
-- @return string|nil Decompressed data
-- @return string|nil Error message
function _M.gunzip(data)
    if not data or #data == 0 then
        return nil, "empty data"
    end

    -- Track input position
    local input_pos = 1
    local input_len = #data

    -- Input function: returns chunks of compressed data
    local function input(bufsize)
        if input_pos > input_len then
            return nil  -- EOF
        end
        local chunk_end = math.min(input_pos + bufsize - 1, input_len)
        local chunk = data:sub(input_pos, chunk_end)
        input_pos = chunk_end + 1
        return chunk
    end

    -- Output buffer with size limit check
    local output_parts = {}
    local total_size = 0

    local function output(chunk)
        total_size = total_size + #chunk
        if total_size > MAX_DECOMPRESSED_SIZE then
            error("decompressed size exceeds limit")
        end
        output_parts[#output_parts + 1] = chunk
    end

    -- Decompress using ffi-zlib
    local ok, err = pcall(function()
        local success, zerr = zlib.inflateGzip(input, output, CHUNK_SIZE)
        if not success then
            error(zerr or "decompression failed")
        end
    end)

    if not ok then
        return nil, tostring(err)
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

    -- Track input position
    local input_pos = 1
    local input_len = #data

    -- Input function: returns chunks of uncompressed data
    local function input(bufsize)
        if input_pos > input_len then
            return nil  -- EOF
        end
        local chunk_end = math.min(input_pos + bufsize - 1, input_len)
        local chunk = data:sub(input_pos, chunk_end)
        input_pos = chunk_end + 1
        return chunk
    end

    -- Output buffer
    local output_parts = {}

    local function output(chunk)
        output_parts[#output_parts + 1] = chunk
    end

    -- Compress using ffi-zlib
    local ok, err = pcall(function()
        local success, zerr = zlib.deflateGzip(input, output, CHUNK_SIZE, {
            level = level,
        })
        if not success then
            error(zerr or "compression failed")
        end
    end)

    if not ok then
        return nil, tostring(err)
    end

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


--- Get zlib version
-- @return string zlib version
function _M.zlib_version()
    return zlib.version()
end


return _M
