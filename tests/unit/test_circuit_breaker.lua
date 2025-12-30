--
-- Unit tests for unifra/jsonrpc/redis_circuit_breaker.lua
--
-- Run with: busted tests/test_redis_circuit_breaker.lua
--

describe("redis_circuit_breaker module", function()
    local circuit_breaker

    setup(function()
        -- Mock dependencies
        _G.ngx = {
            log = function() end,
            INFO = 1,
            WARN = 2,
            ERR = 3,
            now = function() return 1000000 end,
        }

        circuit_breaker = require("unifra.jsonrpc.redis_circuit_breaker")
    end)

    teardown(function()
        package.loaded["unifra.jsonrpc.redis_circuit_breaker"] = nil
    end)

    before_each(function()
        -- Reset circuit breaker state
        circuit_breaker.reset_all()
    end)

    describe("state transitions", function()
        it("should start in CLOSED state", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }
            local state = circuit_breaker.get_state(redis_conf)
            assert.equals("CLOSED", state)
        end)

        it("should open after failure threshold", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Record failures to exceed threshold
            for i = 1, 6 do  -- Default threshold is 5
                circuit_breaker.record_failure(redis_conf, "connection failed")
            end

            local state = circuit_breaker.get_state(redis_conf)
            assert.equals("OPEN", state)
        end)

        it("should transition to HALF_OPEN after timeout", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force open state
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end
            assert.equals("OPEN", circuit_breaker.get_state(redis_conf))

            -- Mock time passing (default open_timeout is 60s)
            _G.ngx.now = function() return 1000000 + 61 end

            local state = circuit_breaker.get_state(redis_conf)
            assert.equals("HALF_OPEN", state)
        end)

        it("should close after successful health check in HALF_OPEN", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force HALF_OPEN state
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end
            _G.ngx.now = function() return 1000000 + 61 end
            assert.equals("HALF_OPEN", circuit_breaker.get_state(redis_conf))

            -- Record success
            circuit_breaker.record_success(redis_conf)

            local state = circuit_breaker.get_state(redis_conf)
            assert.equals("CLOSED", state)
        end)
    end)

    describe("allow_request", function()
        it("should allow requests in CLOSED state", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }
            local allowed, state = circuit_breaker.allow_request(redis_conf)
            assert.is_true(allowed)
            assert.equals("CLOSED", state)
        end)

        it("should block requests in OPEN state", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end

            local allowed, state = circuit_breaker.allow_request(redis_conf)
            assert.is_false(allowed)
            assert.equals("OPEN", state)
        end)

        it("should allow limited requests in HALF_OPEN state", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force HALF_OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end
            _G.ngx.now = function() return 1000000 + 61 end

            local allowed, state = circuit_breaker.allow_request(redis_conf)
            assert.is_true(allowed)
            assert.equals("HALF_OPEN", state)
        end)
    end)

    describe("execute", function()
        it("should execute operation in CLOSED state", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }
            local operation = function()
                return "success", nil
            end

            local result, err, blocked = circuit_breaker.execute(
                redis_conf, {}, operation, true
            )

            assert.equals("success", result)
            assert.is_nil(err)
            assert.is_false(blocked)
        end)

        it("should block operation in OPEN state with fail-open=false", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end

            local operation = function()
                return "should not run", nil
            end

            local result, err, blocked = circuit_breaker.execute(
                redis_conf, {}, operation, false  -- fail-open=false
            )

            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.is_true(blocked)
        end)

        it("should allow operation in OPEN state with fail-open=true", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end

            local operation = function()
                return nil, "operation not executed"
            end

            local result, err, blocked = circuit_breaker.execute(
                redis_conf, {}, operation, true  -- fail-open=true
            )

            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.is_true(blocked)
        end)

        it("should record failures and transition to OPEN", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }
            local failure_count = 0

            local operation = function()
                return nil, "redis error"
            end

            -- Execute until circuit opens
            for i = 1, 10 do
                local result, err, blocked = circuit_breaker.execute(
                    redis_conf, {}, operation, true
                )
                if blocked then
                    break
                end
                failure_count = failure_count + 1
            end

            -- Should have opened after ~5 failures
            assert.is_true(failure_count >= 5 and failure_count <= 7)
            assert.equals("OPEN", circuit_breaker.get_state(redis_conf))
        end)
    end)

    describe("reset", function()
        it("should reset specific circuit breaker", function()
            local redis_conf = { host = "127.0.0.1", port = 6379 }

            -- Force OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf, "error")
            end
            assert.equals("OPEN", circuit_breaker.get_state(redis_conf))

            -- Reset
            circuit_breaker.reset(redis_conf)
            assert.equals("CLOSED", circuit_breaker.get_state(redis_conf))
        end)

        it("should reset all circuit breakers", function()
            local redis_conf1 = { host = "127.0.0.1", port = 6379 }
            local redis_conf2 = { host = "127.0.0.2", port = 6379 }

            -- Force both OPEN
            for i = 1, 6 do
                circuit_breaker.record_failure(redis_conf1, "error")
                circuit_breaker.record_failure(redis_conf2, "error")
            end

            -- Reset all
            circuit_breaker.reset_all()

            assert.equals("CLOSED", circuit_breaker.get_state(redis_conf1))
            assert.equals("CLOSED", circuit_breaker.get_state(redis_conf2))
        end)
    end)
end)
