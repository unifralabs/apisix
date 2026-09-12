"""Local-only RPC policy regression: real APISIX, Redis ledger and HTTP/WS mock."""
import argparse
import concurrent.futures
import copy
import json
import time
from pathlib import Path
import test_access as t
import test_billing_e2e as b

A = "0x" + "00"*19 + "01"
H = "0x" + "00"*32
TX = {"to": A, "gas": "0x186a0"}
def rpc(method, params, rid=1):
    return {"jsonrpc":"2.0","id":rid,"method":method,"params":params}

def setup(network):
    b.setup()
    for suffix, plugin in (("http","unifra-jsonrpc-var"),("ws","unifra-ws-jsonrpc-proxy")):
        endpoint="routes/billing-"+suffix
        status, body=t.request(t.ADMIN+endpoint,headers={"X-API-KEY":t.ADMIN_KEY})
        route=body["value"]; route["plugins"][plugin]["network"]=network
        route.pop("create_time",None); route.pop("update_time",None)
        t.admin(endpoint,route)
    time.sleep(.4)

def checked(transport,tier,payload,cost,expected=None):
    account=b.Account(tier)
    ws=account.ws() if transport=="ws" else None
    try:
        return b.checked(account,ws.call if ws else account.http,copy.deepcopy(payload),
                         cost,0 if expected else (len(payload) if isinstance(payload,list) else 1),expected)
    finally:
        if ws: ws.close()

def policy_matrix(transport):
    allowed=[
        (rpc("trace_call",[TX,["trace"],"latest"]),25),
        (rpc("trace_callMany",[[[TX,["trace"]],[TX,["trace"]]],"latest"]),60),
        (rpc("debug_traceCallMany",[[{"transactions":[TX,TX]}],{"blockNumber":"latest"}]),60),
        (rpc("eth_callMany",[[{"transactions":[TX,TX,TX]}],{"blockNumber":"latest"}]),30),
        (rpc("eth_simulateV1",[{"blockStateCalls":[{"calls":[TX]*6}]},"latest"]),60),
        (rpc("eth_getStorageValues",[{A:["0x0","0x1","0x2"]},"latest"]),6),
        (rpc("eth_getProof",[A,["0x0","0x1"],"latest"]),40),
        (rpc("trace_filter",[{"fromBlock":"0x10","toBlock":"0x12","count":1}]),150),
    ]
    for payload,cost in allowed:
        b.run(transport+"/"+payload["method"]+"/paid internal CU",
              lambda p=payload,c=cost: checked(transport,"paid",p,c))
        b.run(transport+"/"+payload["method"]+"/free denied",
              lambda p=payload: checked(transport,"free",p,0,-32003))
    invalid=[
        rpc("eth_callMany",[[{"transactions":[TX]*11}]]),
        rpc("eth_simulateV1",[{"blockStateCalls":[{"calls":[TX]},{"calls":[TX]}]}]),
        rpc("eth_simulateV1",[{"blockStateCalls":[{"calls":[TX],"stateOverrides":{A:{}}}]}]),
        rpc("eth_getStorageValues",[{A:["0x0"]*33},"latest"]),
        rpc("eth_getProof",[A,["0x0"]*33,"latest"]),
        rpc("trace_filter",[{"fromBlock":"0x1","toBlock":"0xb","count":1}]),
        rpc("trace_filter",[{"fromBlock":"0x1","toBlock":"latest","count":1}]),
        rpc("trace_filter",[{"fromBlock":"0x1","toBlock":"0x2","count":101}]),
        rpc("trace_call",[TX,["vmTrace"],"latest"]),
        rpc("trace_call",[TX,["trace"],"latest",{A:{}}]),
        rpc("debug_traceCall",[TX,"latest",{"tracer":"{step:function(){}}"}]),
        rpc("debug_traceCall",[TX,"latest",{"timeout":"99s"}]),
        rpc("debug_traceCall",[TX,"latest",{"stateOverrides":{A:{}}}]),
        rpc("eth_call",[{"gas":"0xffffff"},"latest"]),
        rpc("eth_call",[TX,"latest",{A:{}}]),
        rpc("eth_getLogs",[{"fromBlock":"0x1","toBlock":"0x1000"}]),
    ]
    for i,payload in enumerate(invalid):
        b.run(transport+f"/invalid bounds {i}",lambda p=payload: checked(transport,"paid",p,0,-32602))
    for m in ("eth_custom","eth_sendTransaction","eth_sign","admin_addPeer","debug_clearTxpool"):
        b.run(transport+"/"+m+"/denied",lambda m=m:checked(transport,"paid",rpc(m,[]),0,-32601))
    b.run(transport+"/heavy notification rejected",lambda:checked(transport,"paid",
          {"jsonrpc":"2.0","method":"trace_call","params":[TX,["trace"],"latest"]},0,-32602))
    b.run(transport+"/batch internal CU",lambda:checked(transport,"paid",[
          rpc("eth_callMany",[[{"transactions":[TX,TX]}]],1),
          rpc("trace_callMany",[[[TX,["trace"]],[TX,["trace"]]]],2)],80))
    b.run(transport+"/heavy batch concurrency cap",lambda:checked(transport,"paid",
          [rpc("trace_call",[TX,["trace"]],i) for i in range(3)],0,-32000))

def normalization(transport):
    a=b.Account("paid")
    ws=a.ws() if transport=="ws" else None
    try:
        b.checked(a,ws.call if ws else a.http,rpc("debug_traceCall",[{},"latest"]),30,1)
        rows=t.request("http://mock-rpc:8545/requests")[1]
        last=rows[-1]
        assert last["params"][0]["gas"]=="0x4c4b40",last
        assert last["params"][2]=={"tracer":"callTracer","timeout":"3s"},last
    finally:
        if ws:ws.close()

def filters():
    a=b.Account("free"); other=b.Account("free")
    same=b.Account("free",quota_key=a.quota_key)
    ids=[]
    try:
        for _ in range(16):
            response=b.checked(a,a.http,rpc("eth_newBlockFilter",[]),2,1)
            fid=response["result"]; ids.append(fid)
        b.checked(a,a.http,rpc("eth_newBlockFilter",[]),0,0,-32000)
        fid=ids[0]
        b.checked(other,other.http,rpc("eth_getFilterChanges",[fid]),0,0,-32602)
        b.checked(a,same.http,rpc("eth_getFilterChanges",[fid]),2,1)
        upstream_id=t.request("http://mock-rpc:8545/requests")[1][-1]["params"][0]
        assert upstream_id!=fid
        b.checked(a,a.http,rpc("eth_getFilterChanges",[upstream_id]),0,0,-32602)
        b.checked(a,a.http,rpc("eth_uninstallFilter",[fid]),1,1)
        ids.remove(fid)
        b.checked(a,a.http,rpc("eth_getFilterChanges",[fid]),0,0,-32602)
        ids.append(b.checked(a,a.http,rpc("eth_newBlockFilter",[]),2,1)["result"])
    finally:
        for fid in ids:a.http(rpc("eth_uninstallFilter",[fid]))

def public():
    for payload in [rpc("eth_newBlockFilter",[]),rpc("eth_getFilterChanges",["0x1"]),
                    rpc("eth_newFilter",[{"fromBlock":"0x1","toBlock":"0x1"}])]:
        t.http_case(payload=payload,status=400,error_code=-32003,forwarded=0)
    t.http_case(payload=rpc("eth_callMany",[[{"transactions":[TX]}]]),
                status=405,error_code=-32003,forwarded=0)

def subscriptions():
    a=b.Account("free"); ws=a.ws(); ids=[]
    try:
        for _ in range(4): ids.append(b.subscribe(ws,"newHeads"))
        b.checked(a,ws.call,rpc("eth_subscribe",["newHeads"]),0,0,-32000)
        b.checked(a,ws.call,rpc("eth_subscribe",["newPendingTransactions"]),0,0,-32003)
        b.checked(a,ws.call,rpc("eth_subscribe",["logs",{}]),0,0,-32602)
        b.checked(a,ws.call,rpc("eth_subscribe",["syncing"]),0,0,-32602)
        b.checked(a,ws.call,rpc("eth_unsubscribe",["someone-elses-id"]),0,0,-32602)
        b.checked(a,ws.call,rpc("eth_unsubscribe",[ids.pop()]),1,1)
        ids.append(b.subscribe(ws,"logs"))
    finally: ws.close()
    p=b.Account("paid"); ws=p.ws()
    try:
        b.subscribe(ws,"newPendingTransactions")
        b.checked(p,ws.call,rpc("eth_subscribe",["newPendingTransactions",True]),0,0,-32602)
    finally: ws.close()

def concurrency():
    a=b.Account("paid")
    ws=a.ws()
    slow=rpc("trace_call",[{**TX,"mock_delay":1.5},["trace"]])
    before=t.count()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(a.http,slow) for _ in range(2)]
            deadline=time.monotonic()+4
            while t.count()<before+2 and time.monotonic()<deadline:time.sleep(.01)
            assert t.count()==before+2
            response=ws.call(rpc("trace_call",[TX,["trace"]]))
            assert b.code(response)==-32000,response
            assert t.count()==before+2
            for f in futures:b.success(f.result())
        b.checked(a,ws.call,rpc("trace_call",[TX,["trace"]]),25,1)
        assert a.used()==75
    finally:ws.close()

def response_cap(transport):
    a=b.Account("free"); ws=a.ws() if transport=="ws" else None
    try:
        payload=rpc("eth_call",[{"mock_size":2100000}])
        if ws:
            ws.sock.sendall(t.frame(json.dumps(payload).encode(),masked=True))
            op,data=t.read_frame(ws.stream)
            assert op==8,(op,len(data))
        else:
            result=a.http(payload)
            assert b.code(result)==-32603,result
        assert a.used()==5,a.used()
    finally:
        if ws:ws.close()

def config_selected_policy():
    fixture="/opt/unifra-apisix/test-env/rpc-policy-fixtures.yaml"
    t.admin("plugin_metadata/unifra-ws-jsonrpc-proxy",{
        "redis_host":"redis", "whitelist_config_path":fixture})
    try:
        for enabled in (True,False):
            network="policy-enabled-demo" if enabled else "policy-disabled-demo"
            for transport in ("http","ws"):
                plugins={"key-auth":{}}
                if transport=="http":
                    plugins.update({"unifra-jsonrpc-var":{"network":network},
                        "unifra-whitelist":{"config_path":fixture},
                        "unifra-calculate-cu":{},"unifra-limit-monthly-cu":{}})
                else:
                    plugins["unifra-ws-jsonrpc-proxy"]={"network":network,"enable_rate_limit":False}
                path="/config-policy-"+network+"-"+transport
                t.admin("routes"+path,{"uri":path,"host":"access.test","plugins":plugins,
                    "upstream":t.UPSTREAM,"enable_websocket":transport=="ws"})
                time.sleep(.25)
                a=b.Account("paid")
                ws=t.WebSocket(path,a.key) if transport=="ws" else None
                invoke=ws.call if ws else lambda p:t.request(t.PROXY+path,"POST",p,{
                    "Host":"access.test","Content-Type":"application/json","apikey":a.key})[1]
                try:
                    b.checked(a,invoke,rpc("eth_call",[{"gas":"0xffffff"}]),
                        0 if enabled else 5,0 if enabled else 1,-32602 if enabled else None)
                    b.checked(a,invoke,rpc("eth_createAccessList",[TX]),
                        10 if enabled else 1,1)
                finally:
                    if ws:ws.close()
    finally:
        t.admin("plugin_metadata/unifra-ws-jsonrpc-proxy",{"redis_host":"redis"})

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--config-dir",type=Path,required=True)
    args=parser.parse_args()
    t.setup(args.config_dir)
    for network in ("arc-testnet","dogeos-testnet"):
        setup(network)
        for transport in ("http","ws"):
            policy_matrix(transport)
            b.run(network+"/"+transport+"/normalized upstream params",lambda p=transport:normalization(p))
            b.run(network+"/"+transport+"/response cap",lambda p=transport:response_cap(p))
        b.run(network+"/filter ownership and slots",filters)
        b.run(network+"/public restrictions",public)
        b.run(network+"/subscription policy",subscriptions)
        b.run(network+"/HTTP WS shared execution concurrency",concurrency)
    b.run("policy activation and pricing depend on config, not backend or chain name",config_selected_policy)
    print(f"{b.PASSED} passed; {len(b.FAILED)} failed",flush=True)
    if b.FAILED:raise SystemExit(1)
if __name__=="__main__":main()
