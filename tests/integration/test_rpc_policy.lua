-- Pure policy tests (no production dependencies, run with resty).
package.path="/opt/unifra-apisix/?.lua;"..package.path
local cjson=require("cjson.safe")
local policy=require("unifra.jsonrpc.rpc_policy")
local passed=0
local A="0x"..string.rep("0",39).."1"
local H="0x"..string.rep("0",64)
local function check(name,ok) assert(ok,name); passed=passed+1 end
local function clone(x) return cjson.decode(cjson.encode(x)) end
local function validate(method,params,paid,public,transport)
    local req={method=method,params=params,id=1}
    local result={raw=req,methods={method},is_batch=false}
    local ctx={var={remote_addr="127.0.0.1"},consumer={username="test"}}
    local ok,msg,code=policy.validate(result,"test-network",paid,public,transport or "http",ctx,"bounded_evm")
    return ok,msg,code,result,ctx
end
local tx={to=A,gas="0x186a0"}
check("owner empty quota falls back",policy.owner({consumer={username="alice",plugins={["unifra-ctx-var"]={quota_key=""}}},var={}})=="alice")
check("owner missing remains nil",policy.owner({consumer={},var={}})==nil)
check("unknown networks unchanged",policy.validate({},"eth-mainnet",false,true,"http",{})==true)
local config={networks={
    ["some-other-evm-network"]={rpc_policy="bounded_evm"},
    ["arc-testnet"]={},
    bad={rpc_policy="unknown_profile"},
}}
check("profile selected solely from configuration",policy.resolve(config,"some-other-evm-network")=="bounded_evm")
check("known chain name does not enable policy",policy.resolve(config,"arc-testnet")==nil)
local selected,selection_err=policy.resolve(config,"bad")
check("invalid profile fails closed",selected==nil and selection_err~=nil)
check("invalid profile cannot silently disable validation",policy.validate({},"any-network",true,false,"http",{},"bad")==nil)
check("log free boundary",validate("eth_getLogs",{{fromBlock="0x1",toBlock="0x64"}},false)==true)
check("log free overflow",validate("eth_getLogs",{{fromBlock="0x1",toBlock="0x65"}},false)==nil)
check("log paid boundary",validate("eth_getLogs",{{fromBlock="0x1",toBlock="0x7d0"}},true)==true)
check("log mixed tag rejected",validate("eth_getLogs",{{fromBlock="0x1",toBlock="latest"}},true)==nil)
check("log public broad denied",validate("eth_getLogs",{{fromBlock="latest",toBlock="latest"}},false,true)==nil)
check("log public narrow",validate("eth_getLogs",{{address=A}},false,true)==true)
check("trace filter count does not bypass span",validate("trace_filter",{{fromBlock="0x0",toBlock="0xa",count=1}},true)==nil)
check("trace filter from/to required to agree",validate("trace_filter",{{fromBlock="safe",toBlock="latest"}},true)==nil)
local bounded,_,_,bounded_result=validate("trace_filter",{{count=1}},true)
check("trace filter omitted range is explicitly forwarded",bounded and bounded_result.raw.params[1].fromBlock=="latest"
    and bounded_result.raw.params[1].toBlock=="latest")
check("trace no JS",validate("debug_traceCall",{tx,"latest",{tracer="javascript"}},true)==nil)
check("trace no opcode",validate("debug_traceCall",{tx,"latest",{tracer="structLogger"}},true)==nil)
check("trace timeout capped",validate("debug_traceCall",{tx,"latest",{timeout="4s"}},true)==nil)
check("trace overrides rejected",validate("debug_traceCall",{tx,"latest",{blockOverrides={}}},true)==nil)
local ok,_,_,r=validate("debug_traceCall",{{to=A},"latest"},true)
check("default options bounded",ok and r.raw.params[3].timeout=="3s" and r.raw.params[3].tracer=="callTracer")
check("gas cap forwarded",r.raw.params[1].gas=="0x4c4b40")
local invalid={cjson.null,false,true,1,"bad",{},{"bad"},{cjson.null},{{}},{ {},{},{} }}
local methods={"eth_call","eth_estimateGas","eth_createAccessList","eth_getLogs","eth_newFilter",
    "eth_feeHistory","eth_getProof","eth_getStorageValues","eth_callMany","debug_traceCallMany",
    "eth_simulateV1","trace_call","trace_callMany","trace_rawTransaction","trace_replayTransaction",
    "trace_replayBlockTransactions","trace_filter","trace_get","debug_traceCall","debug_traceTransaction",
    "debug_traceBlockByHash","debug_traceBlockByNumber","eth_subscribe","eth_unsubscribe",
    "eth_sendRawTransaction","eth_newBlockFilter","eth_getFilterChanges","eth_uninstallFilter"}
for _,m in ipairs(methods) do
    for i,p in ipairs(invalid) do
        for _,transport in ipairs({"http","ws"}) do
            local safe=pcall(validate,m,clone(p),true,false,transport)
            check("malformed params do not throw "..m.."/"..i.."/"..transport,safe)
        end
    end
end
local _,_,_,result=validate("eth_callMany",{{{transactions={tx,tx}}}},true)
check("internal multiplier",result.rpc_policy.units[1]==2)
local cu={get_method_cu=function() return 1 end}
local total,costs=policy.costs(result,{policy_methods={eth_callMany=10}},cu)
check("internal units charged",total==20 and costs[1]==20)
check("old pricing fails closed",policy.costs(result,{},cu)==nil)
local batch={is_batch=true,raw={{method="eth_blockNumber",id=1},{method="eth_chainId",id=1}}}
check("duplicate batch IDs denied",policy.validate(batch,"test-network",false,false,"http",{var={}},"bounded_evm")==nil)
print(passed.." RPC policy checks passed")
