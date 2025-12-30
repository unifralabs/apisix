--
-- Tests for Unifra Key Auth Plugin
--
-- Tests URL-based API key extraction patterns
--

-- Simple test framework
local tests_run = 0
local tests_passed = 0

local function test(name, fn)
    tests_run = tests_run + 1
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        print("[PASS] " .. name)
    else
        print("[FAIL] " .. name .. ": " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected '%s', got '%s'", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assert_nil(v, msg)
    if v ~= nil then
        error(msg or "expected nil, got " .. tostring(v))
    end
end

print("\n=== Testing unifra-key-auth URL patterns ===\n")

-- Default patterns from the plugin
local http_pattern = "^/v1/([^/]+)(.*)"
local ws_pattern = "^/ws/([^/]+)(.*)"

-- Test HTTP pattern extraction
test("http_pattern: /v1/{key} basic", function()
    local uri = "/v1/abc123xyz"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "abc123xyz", "key extraction")
    assert_eq(remaining, "", "remaining path")
end)

test("http_pattern: /v1/{key}/ with trailing slash", function()
    local uri = "/v1/abc123xyz/"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "abc123xyz", "key extraction")
    assert_eq(remaining, "/", "remaining path")
end)

test("http_pattern: /v1/{key}/method with method path", function()
    local uri = "/v1/abc123xyz/eth_blockNumber"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "abc123xyz", "key extraction")
    assert_eq(remaining, "/eth_blockNumber", "remaining path")
end)

test("http_pattern: /v1/{key}/path/to/resource deep path", function()
    local uri = "/v1/my-api-key-here/some/deep/path"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "my-api-key-here", "key extraction")
    assert_eq(remaining, "/some/deep/path", "remaining path")
end)

test("http_pattern: complex key with special chars", function()
    local uri = "/v1/key_with-dashes_and_underscores123/method"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "key_with-dashes_and_underscores123", "key extraction")
    assert_eq(remaining, "/method", "remaining path")
end)

test("http_pattern: no match for /v2/", function()
    local uri = "/v2/abc123xyz"
    local key, remaining = uri:match(http_pattern)
    assert_nil(key, "should not match /v2/")
end)

test("http_pattern: no match for /api/", function()
    local uri = "/api/abc123xyz"
    local key, remaining = uri:match(http_pattern)
    assert_nil(key, "should not match /api/")
end)

-- Test WebSocket pattern extraction
test("ws_pattern: /ws/{key} basic", function()
    local uri = "/ws/abc123xyz"
    local key, remaining = uri:match(ws_pattern)
    assert_eq(key, "abc123xyz", "key extraction")
    assert_eq(remaining, "", "remaining path")
end)

test("ws_pattern: /ws/{key}/ with trailing slash", function()
    local uri = "/ws/abc123xyz/"
    local key, remaining = uri:match(ws_pattern)
    assert_eq(key, "abc123xyz", "key extraction")
    assert_eq(remaining, "/", "remaining path")
end)

test("ws_pattern: /ws/{key}/path with path", function()
    local uri = "/ws/my-ws-key/eth-mainnet"
    local key, remaining = uri:match(ws_pattern)
    assert_eq(key, "my-ws-key", "key extraction")
    assert_eq(remaining, "/eth-mainnet", "remaining path")
end)

-- Test edge cases
test("http_pattern: empty key segment should not match", function()
    local uri = "/v1//method"
    local key, remaining = uri:match(http_pattern)
    -- Pattern [^/]+ requires at least one non-slash character
    -- So empty key segment results in different match behavior
    -- The first capture group matches empty string between slashes
    -- This is correct - plugin will reject empty keys
    if key == "" or key == nil then
        -- Both behaviors are acceptable - empty key will be rejected by plugin
        return
    end
    error("unexpected key: " .. tostring(key))
end)

test("http_pattern: key only (no path)", function()
    local uri = "/v1/onlykey"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "onlykey", "key extraction")
    assert_eq(remaining, "", "no remaining path")
end)

-- Test Alchemy/Infura style URLs
test("alchemy style: /v2/{key}", function()
    -- Custom pattern for Alchemy style
    local alchemy_pattern = "^/v2/([^/]+)(.*)"
    local uri = "/v2/demo-api-key"
    local key, remaining = uri:match(alchemy_pattern)
    assert_eq(key, "demo-api-key", "key extraction")
end)

-- Test real-world scenarios
test("real world: eth-mainnet with full key", function()
    local uri = "/v1/unifra_8f7d9e2a1b3c4d5e6f7a8b9c0d1e2f3a/eth_getBlockByNumber"
    local key, remaining = uri:match(http_pattern)
    assert_eq(key, "unifra_8f7d9e2a1b3c4d5e6f7a8b9c0d1e2f3a", "key extraction")
    assert_eq(remaining, "/eth_getBlockByNumber", "remaining path")
end)

test("real world: websocket subscription", function()
    local uri = "/ws/unifra_8f7d9e2a1b3c4d5e6f7a8b9c0d1e2f3a"
    local key, remaining = uri:match(ws_pattern)
    assert_eq(key, "unifra_8f7d9e2a1b3c4d5e6f7a8b9c0d1e2f3a", "key extraction")
    assert_eq(remaining, "", "no remaining path for ws")
end)

-- Summary
print(string.format("\n=== Test Summary ==="))
print(string.format("Passed: %d, Failed: %d", tests_passed, tests_run - tests_passed))

if tests_passed == tests_run then
    print("All tests passed!")
else
    os.exit(1)
end
