-- Per-gateway resource leases shared by all workers, HTTP and WS. Uses the
-- existing APISIX limit-conn dictionary (must be enabled). No body-filter I/O.
-- For multiple independent gateways, deploy sticky HTTP filters and enforce
-- node-global tracing limits; these counters are not a cluster-wide Redis quota.
local cjson=require("cjson.safe")
local random=require("resty.random")
local str=require("resty.string")
local policy=require("unifra.jsonrpc.rpc_policy")
local _M={response_limit=2097152}
local function dict() return ngx.shared["plugin-limit-conn"] end
local function token() return str.to_hex(assert(random.bytes(16,true))) end
local function key(s) return "rpc-policy:v1:"..s end
local function slots(prefix,limit,ttl,id)
    local d=dict()
    if not d then return nil,"resource storage unavailable" end
    for i=1,limit do
        local k=key(prefix..":"..i)
        local ok,err=d:safe_add(k,id,ttl)
        if ok then return k end
        if err~="exists" then return nil,err end
    end
    return nil,"limit"
end
function _M.release(lease)
    if not lease or lease.released then return end
    lease.released=true
    local d=dict()
    if not d then return end
    for _,k in ipairs(lease.keys or {}) do
        if d:get(k)==lease.id then d:delete(k) end
    end
end
local function reserve(groups,ttl)
    local lease={id=token(),keys={},expires=ngx.now()+ttl}
    for _,g in ipairs(groups) do
        local k,err=slots(g[1],g[2],ttl,lease.id)
        if not k then _M.release(lease); return nil,err end
        lease.keys[#lease.keys+1]=k
    end
    return lease
end
function _M.acquire(result,ctx)
    local p=result.rpc_policy
    if not p then return true end
    ctx.rpc_inflight=ctx.rpc_inflight or {}
    if p.heavy>0 or #p.filters>0 then ctx.rpc_inflight[result]=true end
    if p.heavy>0 then
        -- Atomic with respect to nginx worker scheduling: shared-dict calls do
        -- not yield. A batch consumes one slot per heavy operation.
        local groups={}
        local owner=p.owner or ("public:"..ctx.var.remote_addr)
        for _=1,p.heavy do
            groups[#groups+1]={"trace-user:"..owner,2}
            groups[#groups+1]={"trace-global",16}
            groups[#groups+1]={"trace-network:"..p.network,8}
        end
        local lease,err=reserve(groups,120)
        if not lease then return nil,err=="limit" and "too many concurrent execution requests" or "Service temporarily unavailable",err=="limit" and -32000 or -32603 end
        p.lease=lease
    end
    local seen={}
    for _,f in ipairs(p.filters) do
        local id=cjson.encode(f.request.id)
        if seen[id] then _M.finish(result); return nil,"duplicate filter request id",-32602 end
        seen[id]=true
        if f.create then
            local lease,err=reserve({{"filter-user:"..p.owner,p.paid and 64 or 16},{"filter-global",1024}},300)
            if not lease then _M.finish(result); return nil,err=="limit" and "filter limit exceeded" or "Service temporarily unavailable",err=="limit" and -32000 or -32603 end
            f.lease=lease
            f.virtual="0x"..lease.id
        else
            local raw=dict() and dict():get(key("filter:"..p.network..":"..f.request.params[1]))
            local entry=raw and cjson.decode(raw)
            if not entry or entry.owner~=p.owner then _M.finish(result); return nil,"filter not found",-32602 end
            f.virtual=f.request.params[1]
            f.entry=entry
            f.request.params[1]=entry.upstream
        end
    end
    return true
end
function _M.finish(result,ctx)
    local p=result and result.rpc_policy
    if not p then return end
    if ctx and ctx.rpc_inflight then ctx.rpc_inflight[result]=nil end
    -- Disconnect/timeout does not prove the node stopped computing. Leave the
    -- lease until its expiry instead of reopening concurrency immediately.
    if p.sent and not p.completed then return end
    _M.release(p.lease)
    for _,f in ipairs(p.filters or {}) do
        if f.lease and not f.bound then _M.release(f.lease) end
    end
end
function _M.ws_open(profile,ctx,paid,public)
    if not policy.enabled(profile) then return true end
    local owner=policy.owner(ctx) or ("public:"..ctx.var.remote_addr)
    local lease,err=reserve({{"ws-user:"..owner,public and 2 or paid and 16 or 4},{"ws-global",512}},3720)
    if not lease then return nil,err end
    ctx.rpc_ws_lease=lease
    ctx.rpc_ws_deadline=ngx.now()+3600
    return true
end
function _M.filter_response(result,response)
    local p=result and result.rpc_policy
    if not p or #p.filters==0 then return response end
    local responses=result.is_batch and response or {response}
    if type(responses)~="table" then return nil end
    for _,r in ipairs(responses) do
        if type(r)=="table" then for _,f in ipairs(p.filters) do
            if r.id==f.request.id and r.result~=nil and not r.error then
                if f.create then
                    if type(r.result)~="string" then return nil end
                    local entry={owner=p.owner,upstream=r.result,lease=f.lease}
                    local ttl=f.lease.expires-ngx.now()
                    local ok=ttl>0 and dict() and dict():safe_set(key("filter:"..p.network..":"..f.virtual),cjson.encode(entry),ttl)
                    if not ok then
                        r.result=nil; r.error={code=-32603,message="Service temporarily unavailable"}
                    else
                        f.bound=true; r.result=f.virtual
                    end
                elseif f.remove and r.result==true then
                    dict():delete(key("filter:"..p.network..":"..f.virtual))
                    _M.release(f.entry.lease)
                end
            end
        end end
    end
    return response
end
return _M
