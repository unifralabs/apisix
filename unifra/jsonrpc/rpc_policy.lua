-- Configuration-selected RPC request policy. No backend client detection.
-- No network calls; HTTP and every WS
-- message pass the same validation before CU/rate/monthly admission.
local cjson = require("cjson.safe")
local _M = {}
local FILTER_CREATE = {eth_newFilter=true, eth_newBlockFilter=true,
    eth_newPendingTransactionFilter=true}
local FILTER_USE = {eth_getFilterChanges=true, eth_getFilterLogs=true, eth_uninstallFilter=true}
_M.filter_create, _M.filter_use = FILTER_CREATE, FILTER_USE
function _M.resolve(config, network)
    local entry = config and config.networks and config.networks[network]
    local profile = entry and entry.rpc_policy
    if profile == nil or profile == false then return nil end
    if profile ~= "bounded_evm" then return nil, "unknown RPC policy profile" end
    return profile
end
function _M.enabled(profile)
    return profile == "bounded_evm"
end
function _M.owner(ctx)
    local consumer = ctx.consumer
    local vars = consumer and consumer.plugins and consumer.plugins["unifra-ctx-var"]
    if not consumer then return nil end
    local owner=vars and vars.quota_key
    if owner==nil or owner=="" then owner=consumer.username or ctx.var.consumer_name end
    if owner==nil or owner=="" then return nil end
    return tostring(owner)
end
local function object(x) return type(x) == "table" end
local function array(x, max, min)
    if not object(x) or #x > max or #x < (min or 0) then return false end
    for k in pairs(x) do
        if type(k) ~= "number" or k < 1 or k > #x or k % 1 ~= 0 then return false end
    end
    return true
end
local function quantity(x)
    if type(x) ~= "string" or not x:match("^0x%x+$") or #x > 15 then return nil end
    return tonumber(x:sub(3), 16)
end
local function hex(x, bytes)
    return type(x) == "string" and #x == bytes * 2 + 2 and x:match("^0x%x+$") ~= nil
end
local function size(x, max)
    return type(x) == "string" and x:match("^0x%x*$") and #x % 2 == 0 and #x <= 2 + max * 2
end
local function tag(x)
    return x == "latest" or x == "safe" or x == "finalized" or x == "earliest"
end
local function span(filter, max)
    if not object(filter) then return nil end
    if filter.blockHash ~= nil then
        if filter.fromBlock or filter.toBlock or not hex(filter.blockHash,32) then return nil end
        return 1
    end
    -- Do not resolve moving tags by making a second, unmetered upstream call.
    local from, to = filter.fromBlock or "latest", filter.toBlock or "latest"
    local a,b = quantity(from),quantity(to)
    if a and b and b >= a and b-a+1 <= max then return b-a+1 end
    if from == to and tag(from) then return 1 end
end
local function log_filter(f, require_narrow)
    if not object(f) then return false end
    local narrow = false
    if f.address ~= nil then
        if hex(f.address,20) then narrow = true
        elseif array(f.address,10,1) then
            for _,a in ipairs(f.address) do if not hex(a,20) then return false end end
            narrow = true
        else return false end
    end
    if f.topics ~= nil then
        if not array(f.topics,4) then return false end
        for _,topic in ipairs(f.topics) do
            if topic ~= cjson.null then
                if hex(topic,32) then narrow = true
                elseif array(topic,10,1) then
                    for _,v in ipairs(topic) do if not hex(v,32) then return false end end
                    narrow = true
                else return false end
            end
        end
    end
    return not require_narrow or narrow
end
local function tx_call(tx, paid)
    if not object(tx) then return false end
    local cap = paid and 5000000 or 1000000
    if tx.gas == nil then tx.gas = string.format("0x%x",cap) end
    local gas = quantity(tx.gas)
    if not gas or gas > cap or gas < 21000 then return false end
    for _,field in ipairs({"data","input"}) do
        if tx[field] ~= nil and not size(tx[field],65536) then return false end
    end
    return true
end
local function trace_options(p, index)
    local o = p[index]
    if o == nil or o == cjson.null then o = {}; p[index] = o end
    if not object(o) then return false end
    -- Only the bounded built-in callTracer; no JS/opcode tracer, state/block
    -- overrides or intermediate-transaction execution context.
    for key in pairs(o) do
        if key ~= "tracer" and key ~= "timeout" and key ~= "tracerConfig" then return false end
    end
    if o.tracer ~= nil and o.tracer ~= "callTracer" then return false end
    o.tracer = "callTracer"
    if o.timeout == nil then o.timeout = "3s" end
    if type(o.timeout) ~= "string" then return false end
    local secs = o.timeout:match("^(%d+)s$")
    local ms = o.timeout:match("^(%d+)ms$")
    local limit = secs and tonumber(secs)*1000 or ms and tonumber(ms)
    if not limit or limit < 1 or limit > 3000 then return false end
    if o.tracerConfig ~= nil then
        if not object(o.tracerConfig) then return false end
        for k,v in pairs(o.tracerConfig) do
            if (k ~= "onlyTopCall" and k ~= "withLog") or type(v) ~= "boolean" then return false end
        end
    end
    return true
end
local function trace_types(types)
    return array(types,1,1) and types[1] == "trace"
end
local function context(value)
    if value == nil or value == cjson.null then return true end
    if not object(value) or (value.transactionIndex ~= nil and value.transactionIndex ~= -1) then return false end
    for k in pairs(value) do if k ~= "blockNumber" and k ~= "transactionIndex" then return false end end
    return true
end
local function bundle_calls(bundles, paid)
    if not array(bundles,10,1) then return nil end
    local n=0
    for _,b in ipairs(bundles) do
        if not object(b) or not array(b.transactions,10,1) then return nil end
        for k in pairs(b) do if k ~= "transactions" then return nil end end
        for _,tx in ipairs(b.transactions) do
            if not tx_call(tx,paid) then return nil end
            n=n+1
        end
    end
    if n > 10 then return nil end
    return n
end
local function require_id(req)
    return req.id ~= nil and req.id ~= cjson.null
end

function _M.validate(result, network, paid, public, transport, ctx, profile)
    if profile == nil or profile == false then return true end
    if not _M.enabled(profile) then return nil,"Service temporarily unavailable",-32603 end
    local requests = result.is_batch and result.raw or {result.raw}
    local plan = {units={}, heavy=0, requests=requests, filters={}, public=public, paid=paid,
        owner=_M.owner(ctx), network=network}
    result.rpc_policy = plan
    local new_subs=0
    local ids={}
    for _,r in ipairs(requests) do
        if not object(r) or type(r.method) ~= "string" then
            return nil,"invalid batch member",-32600
        end
        if r.id~=nil and r.id~=cjson.null then
            if type(r.id)~="string" and type(r.id)~="number" then return nil,"invalid request id",-32600 end
            local id=cjson.encode(r.id)
            if ids[id] then return nil,"duplicate request id",-32600 end
            ids[id]=true
        end
    end
    for i,r in ipairs(requests) do
        local m,p = r.method,r.params or {}
        if not array(p,4) then return nil,"invalid params for "..m,-32602 end
        local valid,units,heavy = true,1,false
        if m == "eth_call" or m == "eth_estimateGas" or m == "eth_createAccessList" then
            valid = #p <= 2 and tx_call(p[1],paid)
        elseif m == "eth_getLogs" or m == "eth_newFilter" then
            units = span(p[1],paid and 2000 or 100)
            valid = #p == 1 and units ~= nil and log_filter(p[1],public)
            if valid then
                p[1].fromBlock = p[1].fromBlock or (not p[1].blockHash and "latest" or nil)
                p[1].toBlock = p[1].toBlock or (not p[1].blockHash and "latest" or nil)
            end
            -- Per-100-block query pricing; filter creation is bounded separately.
            units = math.ceil((units or 1)/100)
        elseif m == "eth_feeHistory" then
            local n=quantity(p[1])
            valid=n ~= nil and n >= 1 and n <= (paid and 1024 or 128)
                and (p[3] == nil or array(p[3],20))
            units=math.ceil((n or 1)/128)
        elseif m == "eth_getProof" then
            valid = #p <= 3 and hex(p[1],20) and array(p[2],32)
            if valid then for _,v in ipairs(p[2]) do if quantity(v)==nil and not hex(v,32) then valid=false end end end
            units = valid and math.max(1,#p[2]) or 1
            heavy=true
        elseif m == "eth_getStorageValues" then
            valid = #p <= 2 and object(p[1])
            local n,addresses=0,0
            if valid then for address,slots in pairs(p[1]) do
                addresses=addresses+1
                if not hex(address,20) or not array(slots,32,1) then valid=false; break end
                for _,v in ipairs(slots) do
                    if quantity(v)==nil and not hex(v,32) then valid=false; break end
                    n=n+1
                end
            end end
            valid=valid and addresses>=1 and addresses<=10 and n<=32
            units=math.max(1,n); heavy=true
        elseif m == "eth_callMany" or m == "debug_traceCallMany" then
            units=bundle_calls(p[1],paid)
            valid=units ~= nil and context(p[2])
            if m == "eth_callMany" then valid=valid and #p<=2
            else valid=valid and #p<=3 and trace_options(p,3) end
            heavy=true
        elseif m == "eth_simulateV1" then
            local v=p[1]; units=0
            valid=#p<=2 and object(v) and array(v.blockStateCalls,1,1)
            if valid then
                for k in pairs(v) do
                    if k~="blockStateCalls" and k~="validation" and k~="traceTransfers" and k~="returnFullTransactions" then valid=false end
                end
                for _,b in ipairs(v.blockStateCalls) do
                    if not object(b) or not array(b.calls,10,1) then valid=false; break end
                    for k in pairs(b) do if k~="calls" then valid=false end end
                    for _,tx in ipairs(b.calls) do if not tx_call(tx,paid) then valid=false end; units=units+1 end
                end
            end
            heavy=true
        elseif m:sub(1,6) == "trace_" then
            heavy=true
            if m == "trace_call" then valid=#p<=3 and tx_call(p[1],paid) and trace_types(p[2])
            elseif m == "trace_callMany" then
                valid=#p<=2 and array(p[1],10,1); units=valid and #p[1] or 1
                if valid then for _,pair in ipairs(p[1]) do
                    if not array(pair,2,2) or not tx_call(pair[1],paid) or not trace_types(pair[2]) then valid=false end
                end end
            elseif m == "trace_rawTransaction" then valid=#p==2 and size(p[1],131072) and trace_types(p[2])
            elseif m == "trace_replayTransaction" or m == "trace_replayBlockTransactions" then
                valid=#p==2 and trace_types(p[2])
            elseif m == "trace_filter" then
                local f=p[1]; units=span(f,10)
                valid=#p==1 and units ~= nil and object(f) and f.blockHash==nil
                if valid then
                    -- A backend's omitted fromBlock is not necessarily latest.
                    -- Forward the SAME bounded range that was validated.
                    f.fromBlock=f.fromBlock or "latest"
                    f.toBlock=f.toBlock or "latest"
                    for k in pairs(f) do
                        if k~="fromBlock" and k~="toBlock" and k~="fromAddress" and k~="toAddress"
                            and k~="after" and k~="count" and k~="mode" then valid=false end
                    end
                    for _,field in ipairs({"fromAddress","toAddress"}) do
                        if f[field]~=nil then
                            if not array(f[field],10,1) then valid=false
                            else for _,a in ipairs(f[field]) do if not hex(a,20) then valid=false end end end
                        end
                    end
                    if f.count==nil then f.count=100 end
                    valid=valid and type(f.count)=="number" and f.count>=1 and f.count<=100 and f.count%1==0
                        and (f.after==nil or f.after==0)
                end
            elseif m == "trace_get" then valid=#p==2 and hex(p[1],32) and array(p[2],16)
            else valid=#p==1 end
        elseif m:sub(1,11) == "debug_trace" then
            heavy=true
            local ix=m=="debug_traceCall" and 3 or 2
            valid=#p<=ix and trace_options(p,ix)
            if m=="debug_traceCall" then valid=valid and tx_call(p[1],paid) end
            if m=="debug_traceTransaction" or m=="debug_traceBlockByHash" then
                valid=valid and hex(p[1],32)
            elseif m=="debug_traceBlockByNumber" then
                valid=valid and (quantity(p[1])~=nil or tag(p[1]))
            end
        elseif m == "eth_subscribe" then
            local kind=p[1]
            valid=transport=="ws" and require_id(r)
            if kind=="newPendingTransactions" then
                if not paid or public then return nil,"pending subscriptions require paid tier",-32003 end
                valid=valid and #p==1 -- hash-only; no full pending transaction stream
            elseif kind=="logs" then
                valid=valid and #p==2 and log_filter(p[2],true)
                    and p[2].fromBlock==nil and p[2].toBlock==nil and p[2].blockHash==nil
            elseif kind=="newHeads" then valid=valid and #p==1
            else valid=false end
            new_subs=new_subs+1
        elseif m == "eth_unsubscribe" then
            valid=transport=="ws" and #p==1 and type(p[1])=="string" and require_id(r)
            if valid and not (ctx.rpc_subscriptions or {})[p[1]] then
                return nil,"subscription not found",-32602
            end
        elseif m == "eth_sendRawTransaction" then
            valid=#p==1 and size(p[1],131072)
        end
        if FILTER_CREATE[m] or FILTER_USE[m] then
            if public or not plan.owner then return nil,"filters require an authenticated API key",-32003 end
            valid=valid and transport=="http" and require_id(r)
            if m=="eth_newPendingTransactionFilter" and not paid then
                return nil,"pending filters require paid tier",-32003
            end
            if FILTER_USE[m] then valid=valid and #p==1 and type(p[1])=="string" end
            plan.filters[#plan.filters+1]={request=r, create=FILTER_CREATE[m], remove=m=="eth_uninstallFilter"}
        end
        if heavy and not require_id(r) then return nil,"execution requests require an id",-32602 end
        if not valid then return nil,"request parameters exceed policy or are invalid: "..m,-32602 end
        plan.units[i]=units or 1
        if heavy then plan.heavy=plan.heavy+1 end
    end
    if new_subs>0 then
        local count=0
        for _ in pairs(ctx.rpc_subscriptions or {}) do count=count+1 end
        for _ in pairs(ctx.rpc_pending_subscriptions or {}) do count=count+1 end
        if count+new_subs>(paid and 16 or public and 2 or 4) then
            return nil,"subscription limit exceeded",-32000
        end
    end
    return true
end

function _M.costs(result, config, cu)
    if result.rpc_policy and type(config.policy_methods)~="table" then return nil end
    local costs,total={},0
    local requests=result.is_batch and result.raw or {result.raw}
    for i,r in ipairs(requests) do
        local cost=result.rpc_policy and config.policy_methods[r.method] or cu.get_method_cu(r.method,config)
        cost=cost*(result.rpc_policy and result.rpc_policy.units[i] or 1)
        if result.rpc_policy and r.method=="eth_simulateV1" then cost=math.max(50,cost) end
        costs[i]=cost; total=total+cost
    end
    return total,costs
end
return _M
