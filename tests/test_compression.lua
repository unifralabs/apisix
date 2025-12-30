--
-- Tests for Unifra Compression Module
--

package.path = package.path .. ";../?.lua"

local compression = require("unifra.compression")

-- Simple test framework
local tests_run = 0
local tests_passed = 0

local function test(name, fn)
    tests_run = tests_run + 1
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        print("✓ " .. name)
    else
        print("✗ " .. name .. ": " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assert_true(v, msg)
    if not v then
        error(msg or "expected true")
    end
end

local function assert_nil(v, msg)
    if v ~= nil then
        error(msg or "expected nil, got " .. tostring(v))
    end
end

print("\n=== Compression Module Tests ===\n")

-- Test gzip magic byte detection
test("is_gzip: valid gzip header", function()
    -- Gzip magic bytes: 0x1f 0x8b
    local gzip_data = string.char(0x1f, 0x8b, 0x08, 0x00)
    assert_true(compression.is_gzip(gzip_data), "should detect gzip header")
end)

test("is_gzip: non-gzip data", function()
    local json_data = '{"jsonrpc":"2.0"}'
    assert_true(not compression.is_gzip(json_data), "should not detect gzip in JSON")
end)

test("is_gzip: empty data", function()
    assert_true(not compression.is_gzip(""), "should return false for empty data")
    assert_true(not compression.is_gzip(nil), "should return false for nil")
end)

test("is_gzip: short data", function()
    assert_true(not compression.is_gzip("a"), "should return false for 1 byte")
end)

-- Test gzip compression
test("gzip: compress simple string", function()
    local original = "Hello, World!"
    local compressed, err = compression.gzip(original)
    assert_nil(err, "should not return error")
    assert_true(compressed ~= nil, "should return compressed data")
    assert_true(#compressed > 0, "compressed data should not be empty")
    assert_true(compression.is_gzip(compressed), "result should be valid gzip")
end)

test("gzip: compress JSON-RPC request", function()
    local json = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    local compressed, err = compression.gzip(json)
    assert_nil(err, "should not return error")
    assert_true(compression.is_gzip(compressed), "result should be valid gzip")
end)

test("gzip: compress empty data returns error", function()
    local compressed, err = compression.gzip("")
    assert_nil(compressed, "should return nil for empty data")
    assert_true(err ~= nil, "should return error for empty data")
end)

test("gzip: compress nil returns error", function()
    local compressed, err = compression.gzip(nil)
    assert_nil(compressed, "should return nil for nil")
    assert_true(err ~= nil, "should return error for nil")
end)

-- Test gzip decompression
test("gunzip: decompress simple string", function()
    local original = "Hello, World!"
    local compressed, _ = compression.gzip(original)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, original, "decompressed data should match original")
end)

test("gunzip: decompress JSON-RPC request", function()
    local json = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    local compressed, _ = compression.gzip(json)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, json, "decompressed data should match original")
end)

test("gunzip: decompress large JSON-RPC batch", function()
    -- Create a batch request
    local requests = {}
    for i = 1, 100 do
        requests[i] = string.format('{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":%d}', i)
    end
    local json = "[" .. table.concat(requests, ",") .. "]"

    local compressed, _ = compression.gzip(json)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, json, "decompressed data should match original")

    -- Verify compression ratio
    local ratio = #compressed / #json
    print(string.format("  (compression ratio: %.2f%%, %d -> %d bytes)", ratio * 100, #json, #compressed))
end)

test("gunzip: decompress empty data returns error", function()
    local decompressed, err = compression.gunzip("")
    assert_nil(decompressed, "should return nil for empty data")
    assert_true(err ~= nil, "should return error for empty data")
end)

test("gunzip: decompress nil returns error", function()
    local decompressed, err = compression.gunzip(nil)
    assert_nil(decompressed, "should return nil for nil")
    assert_true(err ~= nil, "should return error for nil")
end)

test("gunzip: decompress invalid gzip returns error", function()
    local invalid = "this is not gzip data"
    local decompressed, err = compression.gunzip(invalid)
    assert_nil(decompressed, "should return nil for invalid gzip")
    assert_true(err ~= nil, "should return error for invalid gzip")
end)

test("gunzip: decompress truncated gzip returns error", function()
    local original = "Hello, World!"
    local compressed, _ = compression.gzip(original)
    -- Truncate the compressed data
    local truncated = compressed:sub(1, #compressed - 10)
    local decompressed, err = compression.gunzip(truncated)
    assert_nil(decompressed, "should return nil for truncated gzip")
    assert_true(err ~= nil, "should return error for truncated gzip")
end)

-- Test roundtrip with different compression levels
test("gzip/gunzip: roundtrip with compression level 1", function()
    local original = string.rep("abcdefghij", 1000)
    local compressed, _ = compression.gzip(original, 1)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, original, "decompressed data should match original")
end)

test("gzip/gunzip: roundtrip with compression level 9", function()
    local original = string.rep("abcdefghij", 1000)
    local compressed, _ = compression.gzip(original, 9)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, original, "decompressed data should match original")
end)

-- Test with binary data
test("gzip/gunzip: roundtrip with binary data", function()
    local binary = ""
    for i = 0, 255 do
        binary = binary .. string.char(i)
    end
    local compressed, _ = compression.gzip(binary)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, binary, "decompressed data should match original")
end)

-- Test with Unicode/UTF-8 data
test("gzip/gunzip: roundtrip with UTF-8 data", function()
    local utf8 = '{"message":"你好世界","emoji":"🚀"}'
    local compressed, _ = compression.gzip(utf8)
    local decompressed, err = compression.gunzip(compressed)
    assert_nil(err, "should not return error")
    assert_eq(decompressed, utf8, "decompressed data should match original")
end)

-- Summary
print(string.format("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run))

if tests_passed ~= tests_run then
    os.exit(1)
end
