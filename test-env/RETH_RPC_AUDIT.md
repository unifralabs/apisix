# Arc / DogeOS Reth RPC 实测与权限设计

日期：2026-09-12。本报告保留调查时的实测结果与设计建议；调查阶段没有修改生产、白名单或计价。
后续本地实现与测试见 [RPC_POLICY.md](RPC_POLICY.md)，运行时按配置选择通用 RPC 策略，不识别节点客户端。
独立 WS 安全提交 d3751986 保持不变；后续策略实现不属于该历史提交。

## 1. 结论

- DogeOS 和 Arc 均开放了 trace 命名空间中本次测试的 9 个方法。DogeOS 白名单缺失 trace 是网关历史配置遗漏，不是节点能力缺失。
- 两边的 HTTP 和 WS 均实际执行成功 trace_call、trace_callMany、debug_traceCall、debug_traceCallMany、eth_callMany、eth_simulateV1。
- 两网络应该采用共同的业务权限标准，少量节点能力差异单独处理，不能再把 eth_* 全部视为免费低成本方法。
- 付费也不能访问节点管理、节点签名、磁盘导出等方法。
- 方法存在、实际能执行、适合开放给用户，是三个不同结论。

## 2. 实测对象和安全边界

| 节点 | HTTP / WS | web3_clientVersion | chain ID |
|---|---|---|---|
| DogeOS testnet | 10.142.0.16:8545 / :8546 | reth/v2.0.0-972366a/x86_64-unknown-linux-gnu | 6281971 |
| Arc testnet | 10.142.0.28:8545 / :8546 | reth/v2.2.0-88505c7/x86_64-unknown-linux-gnu | 5042002 |

通过 JumpServer 登录 prod-node，从其内网直连本地 upstream 配置所指向的节点；不是通过 APISIX 公共域名探测。
两个节点的 HTTP 和 WS 分别探测了 90 个候选只读/订阅相关方法，并补充有效参数验证。
这不是 RPC 所有方法的完整枚举；rpc_modules 两边均返回 -32601。管理、签名、广播方法不通过执行来枚举。
没有修改服务、数据库、元数据或账户，没有广播交易；仅短暂创建 newHeads WS 订阅，随后取消并关闭连接。
单连接顺序请求，间隔约 120–150 ms，客户端超时 6 秒、响应上限 1 MiB。
执行类探测使用最多 100,000 gas 的简单模拟；块追踪仅选取 <=500,000 gasUsed 且 <=4 笔交易的块。
客户端超时不是服务端计算取消的保证，因此没有发起无限范围扫描或大块重放。
未读取节点启动参数、裁剪模式和实际服务端资源上限，也未做压力测试。

### 如何解释结果

- 成功响应：实测返回 result；null/空数组只能说明该输入下正常响应，不能证明查到了真实交易。
- 已注册／参数校验：不是 -32601，说明处理器已注册，不等于完整实现。
- 已注册／对象不存在：使用零 hash 或不存在的块，已进入对应处理器；不等于真实交易追踪成功。
- 未开放：该地址及协议返回 -32601，不代表 Reth 的所有版本都不实现该方法。
- 未实现：明确返回 unimplemented。
- 疑似占位：有效参数返回 null，并与上游 Reth 某些兼容空实现吻合，不列为可售功能。

### 有效执行的重点证据

- 两节点、两协议：eth_call、eth_estimateGas、eth_createAccessList、eth_getAccount、
  eth_getAccountInfo、eth_getStorageValues、eth_simulateV1、eth_callMany、
  trace_call、trace_callMany、debug_traceCall、debug_traceCallMany 均返回结果。
- 两节点 WS：newHeads 订阅返回 ID，取消返回 true。这里只验证建立/取消，未等待推送事件。
- DogeOS：块 0x74cbbe（gasUsed=0，交易数=0）完成 trace_block、trace_filter、
  trace_replayBlockTransactions、debug_traceBlockByHash/Number 验证。
  近期选中的块为空块，没有真实交易级追踪成功样本。
- Arc HTTP：真实交易
  0x88d29c81da005acbbcff3f8b3dcf5d1c1d1ff286ecbd6dc1beaa5e765fe7ed67
  （块 0x3adf357，交易序号 0，gas limit 100,000）
  完成 trace_transaction、trace_get、trace_replayTransaction、debug_traceTransaction。
  Arc 未找到符合本轮负载阈值的整块，因此未做真实整块追踪；WS 下一笔候选交易超过阈值也主动跳过。
- trace_rawTransaction 使用空原始交易，返回 empty transaction data，只确认处理器注册。
  未广播或构造真实签名交易。
- 第一轮模拟误选预编译地址 0x1 且仅给 21,000 gas，出现 out of gas；
  随后改为无代码地址 0xdead、100,000 gas，执行成功。该首轮错误不属于能力缺失。

### 节点差异

- DogeOS eth_blobBaseFee：HTTP/WS 均报 excess blob gas missing in the EVM's environment after Cancun。
  Arc 返回 0x1。DogeOS 暂不对外承诺该能力；原因需另查链配置/客户端版本，不能只凭错误定论。
- txpool_status / txpool_contentFrom：Arc 两协议开放，DogeOS 两协议 -32601。
  不能据此断言所有 txpool 方法均已测试。
- 两边 eth_getWork、eth_mining、eth_coinbase 返回 unimplemented。
- 两边 rpc_modules、eth_getMultiProof、debug_getRawBlockAccessList、debug_getBlockRlp、
  debug_accountAt、debug_accountInfoAt、reth_getBalanceChangesInBlock、ots_getApiLevel 未开放。
- debug_accountRange、debug_storageRangeAt、debug_getModifiedAccountsByHash/Number：
  有效参数返回 null，不作为已实现的高级数据产品。

## 3. 建议的权限设计

以下为建议，不是已经修改的配置。FREE 包括免费 API-key 用户；PAID 包括有效付费/合作伙伴授权。
Public 为共享匿名入口，不归属某个终端用户，也不因携带付费 key 而提升权限。

### A. 基础免费（付费用户也可用）

全部改为明确方法名，不再保留 eth_*、net_*、web3_* 通配符：

~~~text
web3_clientVersion
web3_sha3
net_version
net_listening
net_peerCount
eth_chainId
eth_blockNumber
eth_protocolVersion
eth_syncing
eth_gasPrice
eth_maxPriorityFeePerGas
eth_feeHistory
eth_getBalance
eth_getStorageAt
eth_getCode
eth_getTransactionCount
eth_getAccount
eth_getAccountInfo
eth_getBlockByHash
eth_getBlockByNumber
eth_getHeaderByHash
eth_getHeaderByNumber
eth_getBlockTransactionCountByHash
eth_getBlockTransactionCountByNumber
eth_getTransactionByHash
eth_getTransactionByBlockHashAndIndex
eth_getTransactionByBlockNumberAndIndex
eth_getTransactionReceipt
eth_getRawTransactionByHash
eth_getRawTransactionByBlockHashAndIndex
eth_getRawTransactionByBlockNumberAndIndex
eth_getUncleCountByBlockHash
eth_getUncleCountByBlockNumber
eth_getUncleByBlockHashAndIndex
eth_getUncleByBlockNumberAndIndex
eth_call
eth_estimateGas
eth_createAccessList
eth_getLogs
eth_getBlockReceipts
~~~

保留 uncle 查询是兼容现有 SDK，返回 0/null 不代表链有 uncle。
eth_createAccessList 是钱包交易准备能力，建议免费但补足计价，而不是所有 EVM 执行一律收费。
eth_getLogs / eth_getBlockReceipts 保持基础免费以降低兼容性变化，但必须限制范围、返回量和响应大小。
Arc 可额外保留 eth_blobBaseFee；DogeOS 排除，待查清错误后加入。

eth_sendRawTransaction 建议继续对免费/API-key/public 开放已签名交易广播（防滥用限速、大小限制）。
本轮没有实际调用该写入方法，因此它是保留既有产品能力的建议，不是本轮广播验收通过。
它与节点代签 eth_sendTransaction 完全不同。

### B. 专业能力付费

共同 tracing 白名单：

~~~text
debug_traceTransaction
debug_traceCall
debug_traceBlockByHash
debug_traceBlockByNumber
trace_block
trace_transaction
trace_call
trace_rawTransaction
trace_replayBlockTransactions
trace_replayTransaction
trace_get
~~~

共同高级查询/原始数据：

~~~text
eth_getProof
debug_getRawHeader
debug_getRawBlock
debug_getRawTransaction
debug_getRawTransactions
debug_getRawReceipts
~~~

getProof 改付费属于既有免费能力收紧，需明确公告；不是 WS 安全修复必需内容。
原始数据方法是专业数据格式，不等同于危险节点管理，但应有明确 CU、单块/响应上限。
若要降低迁移影响，可先保留 getProof 免费并限制 storage keys，再按产品政策调整。

以下方法也定位付费，但必须先加“请求内部规模”限制及计价，再开放/继续提供：

~~~text
trace_filter
trace_callMany
debug_traceCallMany
eth_callMany
eth_simulateV1
eth_getStorageValues
~~~

不能把内部 100 次调用按外层 1 次请求收费。外层 JSON-RPC batch 的数量限制不能解决方法参数内部嵌套批量问题。
已在旧列表开放的 trace_filter / trace_callMany 需要补防护；
debug_traceCallMany 等新增权限在防护前不加入正式列表。
eth_callMany / eth_simulateV1 / eth_getStorageValues 当前被 eth_* 意外免费放行，应显式归类处理。

### C. 有状态查询和 WS 订阅

- eth_subscribe / eth_unsubscribe：必须是 WS；newHeads、带窄过滤条件的 logs 建议免费。
- newPendingTransactions（特别是完整交易推送）建议付费并限制连接、订阅、推送 CU；
  本轮只验证 newHeads 的建立/取消，没有验证其它订阅类型及实际推送。
- eth_newFilter / eth_newBlockFilter / eth_getFilterChanges / eth_getFilterLogs / eth_uninstallFilter：
  建议免费 API-key 用户保留；需按用户校验 filter ID 归属、数量、TTL。
  本轮仅检查 newFilter 参数校验和不存在 filter 的查询，没有创建 HTTP filter。
- eth_newPendingTransactionFilter 建议与 pending 订阅同属付费。
- Public 建议只提供无状态 HTTP 基础 RPC；若提供 Public WS，则仅允许受限的 newHeads/logs。
  公共入口不提供 HTTP 有状态 filters，不承诺恢复断线后的共享 filter。

这些是额外的入口/参数策略，不是现有 free_only 一个字段就能完成：
现有方法白名单不能区分 eth_subscribe 参数，必须在 HTTP/WS 共同访问控制逻辑中处理。

### D. 不对免费或付费用户开放

- admin_*、engine_*、personal_*、miner_*、testing_* 以及未知扩展命名空间。
- eth_accounts、eth_sign、eth_signTypedData、eth_signTransaction、eth_sendTransaction、
  eth_sendUnsignedTransaction 等节点账户/代签能力。这里按风险给禁止策略，未实际调用或断言这些方法在节点均已注册。
- debug_setHead、debug_clearTxpool、数据库操作、磁盘导出、profiling、dump、日志级别等节点管理方法。
- debug_executionWitness / executionWitnessByBlockHash、任意状态遍历：虽部分处理器已注册，
  暂不在共享节点上作为普通付费能力开放，需独立容量和资源预算。
- debug_traceBlock（任意 RLP block）：本轮只确认解码错误，优先提供已存储块的追踪，暂不开放任意块输入。
- 未实现、未开放或占位的方法不列入售卖清单。
- txpool_status 虽较轻，但默认保留运维；txpool_content/inspect/全池 pending 查询不因 PAID 就自动开放。
  本轮没有取完整交易池。

## 4. 必须同步处理的计价与限制

按本地 conf/cu-pricing.yaml，目前 default=1：
eth_createAccessList、eth_getAccount、eth_getAccountInfo、eth_getStorageValues、
eth_callMany、eth_simulateV1 没有明确价格，会落入默认价格。
这只是仓库计价的核对，未复核生产 metadata 是否覆盖配置路径。

建议起步价格（产品草案，不是实测 CPU 定价）：

| 方法类型 | 建议 CU |
|---|---|
| 基础查询 | 保持现有 1–3 |
| getAccount / getAccountInfo | 5 / 3 |
| createAccessList | 10 |
| getProof | 20 起，按 storage keys 增量 |
| 4 个现有 debug tracing | 保持 30/50，配额外执行上限 |
| 单交易/单调用 trace | 保持现有 25；trace_get 明确 25 |
| 整块 trace | 保持 50 起，同时限制块资源，不应把静态 CU 当 CPU 保障 |
| callMany 类 | 按内部调用数计费，不再固定一个外层价 |
| simulateV1 | 按模拟块/内部交易数量计价 |
| getStorageValues | 按地址数与槽位总数计价 |
| trace_filter | 按区块跨度计价，且独立限制输出数量 |
| debug 原始数据读取 | 单交易 3，header 3，单块/receipts 10 起 |

建议初始防护值，仅作为待压测的保守草案：

- logs：免费/public <=100 块，付费 <=2,000 块；另限制日志数量/响应大小。
- trace_filter：<=10 块、count<=100；count 不是计算量上限，必须同时限制块跨度。
- callMany：<=10 个内部调用；simulateV1：<=1 个模拟块、<=10 笔模拟交易。
- trace：每付费账户并发 <=2，必须另设全局并发预算。
- debug tracer：先开放经过验证的内置 tracer（本轮执行 callTracer）；拒绝任意 JS tracer，
  禁止没有边界的逐 opcode/大内存输出。用户传入 timeout 不能突破服务端最大执行预算。
- 状态覆盖/块覆盖、gas、输入大小、响应大小、WS 连接/订阅数均需校验。
- historical state 是否保留、追踪历史跨度需另查节点裁剪配置，不能根据一次 latest 成功承诺 archive 能力。

Reth 官方提供相应的 tracing 并发、trace_filter 区块数、日志范围、gas cap 等参数，
但当前线上实际值未查；文档默认值不等于线上配置。

## 5. 实施顺序（等待确认，不执行）

1. 保持 d3751986 的 WS 握手安全修复独立，不将本调查扩大为紧急大版本。
2. 最小补齐：DogeOS 增加与 Arc 同口径的明确 trace 方法；对 filter/callMany 检查边界后再放行。
3. 两网络免费列表从通配符改为明确名字；先确认常见钱包/SDK、广播、filters/订阅兼容性。
4. 同时补齐明确 CU；把内部批量计价、范围和并发检查实现为 HTTP/WS 共享逻辑。
5. 本地 mock 与真实客户端回归：免费、付费、public、嵌套批量、WS 每消息和订阅类型均覆盖。
6. 对 getProof、pending 推送等从免费改付费的变化单独公告/评估，不能伪装成纯安全补丁。
7. 用户批准后再部署。本次没有修改已有安全提交、运行时配置或生产服务。

## 6. 逐方法实测矩阵

表内成功响应不代表全参数、全历史高度、全 tracer 均可用；范围/错误解释见上文。
| 方法 | DogeOS HTTP | DogeOS WS | Arc HTTP | Arc WS |
|---|---|---|---|---|
| `debug_accountAt` | 未开放 | 未开放 | 未开放 | 未开放 |
| `debug_accountInfoAt` | 未开放 | 未开放 | 未开放 | 未开放 |
| `debug_accountRange` | null／疑似占位 | null／疑似占位 | null／疑似占位 | null／疑似占位 |
| `debug_executionWitness` | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 |
| `debug_executionWitnessByBlockHash` | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 |
| `debug_getBlockRlp` | 未开放 | 未开放 | 未开放 | 未开放 |
| `debug_getModifiedAccountsByHash` | null／疑似占位 | null／疑似占位 | null／疑似占位 | null／疑似占位 |
| `debug_getModifiedAccountsByNumber` | null／疑似占位 | null／疑似占位 | null／疑似占位 | null／疑似占位 |
| `debug_getRawBlock` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `debug_getRawBlockAccessList` | 未开放 | 未开放 | 未开放 | 未开放 |
| `debug_getRawHeader` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `debug_getRawReceipts` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `debug_getRawTransaction` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `debug_getRawTransactions` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `debug_storageRangeAt` | null／疑似占位 | null／疑似占位 | null／疑似占位 | null／疑似占位 |
| `debug_traceBlock` | 错误 -32603 | 错误 -32603 | 错误 -32603 | 错误 -32603 |
| `debug_traceBlockByHash` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `debug_traceBlockByNumber` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `debug_traceCall` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `debug_traceCallMany` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `debug_traceTransaction` | 已注册／对象不存在 | 已注册／对象不存在 | 成功响应 | 已注册／对象不存在 |
| `eth_blobBaseFee` | 链环境错误 | 链环境错误 | 成功响应 | 成功响应 |
| `eth_blockNumber` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_call` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_callMany` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_chainId` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_coinbase` | 未实现 | 未实现 | 未实现 | 未实现 |
| `eth_createAccessList` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_estimateGas` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_feeHistory` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_gasPrice` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getAccount` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getAccountInfo` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getBalance` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getBlockByHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getBlockByNumber` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getBlockReceipts` | 成功响应 | 成功响应 | 成功响应 null | 成功响应 null |
| `eth_getBlockTransactionCountByHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getBlockTransactionCountByNumber` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getCode` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getFilterChanges` | 已注册／对象不存在 | 已注册／对象不存在 | 已注册／对象不存在 | 已注册／对象不存在 |
| `eth_getFilterLogs` | 已注册／对象不存在 | 已注册／对象不存在 | 已注册／对象不存在 | 已注册／对象不存在 |
| `eth_getHeaderByHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getHeaderByNumber` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getLogs` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getMultiProof` | 未开放 | 未开放 | 未开放 | 未开放 |
| `eth_getProof` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getRawTransactionByBlockHashAndIndex` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getRawTransactionByBlockNumberAndIndex` | 成功响应 null | 成功响应 null | 成功响应 | 成功响应 |
| `eth_getRawTransactionByHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getStorageAt` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getStorageValues` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getTransactionByBlockHashAndIndex` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getTransactionByBlockNumberAndIndex` | 成功响应 null | 成功响应 null | 成功响应 | 成功响应 |
| `eth_getTransactionByHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getTransactionCount` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getTransactionReceipt` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getUncleByBlockHashAndIndex` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getUncleByBlockNumberAndIndex` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getUncleCountByBlockHash` | 成功响应 null | 成功响应 null | 成功响应 null | 成功响应 null |
| `eth_getUncleCountByBlockNumber` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_getWork` | 未实现 | 未实现 | 未实现 | 未实现 |
| `eth_hashrate` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_maxPriorityFeePerGas` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_mining` | 未实现 | 未实现 | 未实现 | 未实现 |
| `eth_newFilter` | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 |
| `eth_protocolVersion` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_simulateV1` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_subscribe` | 错误 -32603 | 成功响应 | 错误 -32603 | 成功响应 |
| `eth_syncing` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `eth_unsubscribe` | 错误 -32603 | 成功响应 | 错误 -32603 | 成功响应 |
| `net_listening` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `net_peerCount` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `net_version` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `ots_getApiLevel` | 未开放 | 未开放 | 未开放 | 未开放 |
| `reth_getBalanceChangesInBlock` | 未开放 | 未开放 | 未开放 | 未开放 |
| `rpc_modules` | 未开放 | 未开放 | 未开放 | 未开放 |
| `trace_block` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `trace_call` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `trace_callMany` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `trace_filter` | 成功响应 | 成功响应 | 已注册／对象不存在 | 已注册／对象不存在 |
| `trace_get` | 成功响应 null | 成功响应 null | 成功响应 | 成功响应 null |
| `trace_rawTransaction` | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 | 已注册／参数校验 |
| `trace_replayBlockTransactions` | 成功响应 | 成功响应 | 成功响应 null | 成功响应 null |
| `trace_replayTransaction` | 已注册／对象不存在 | 已注册／对象不存在 | 成功响应 | 已注册／对象不存在 |
| `trace_transaction` | 成功响应 null | 成功响应 null | 成功响应 | 成功响应 null |
| `txpool_contentFrom` | 未开放 | 未开放 | 成功响应 | 成功响应 |
| `txpool_status` | 未开放 | 未开放 | 成功响应 | 成功响应 |
| `web3_clientVersion` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |
| `web3_sha3` | 成功响应 | 成功响应 | 成功响应 | 成功响应 |

## 7. 参考资料

- [Reth JSON-RPC 与 HTTP/WS 独立命名空间配置](https://reth.rs/jsonrpc/intro/)
- [Reth trace API](https://reth.rs/jsonrpc/trace/)
- [Reth eth API 源码：批量模拟、storage values、proof](https://reth.rs/docs/src/reth_rpc_eth_api/core.rs.html)
- [Reth v2.0.0 debug 实现：若干兼容方法为空实现](https://raw.githubusercontent.com/paradigmxyz/reth/v2.0.0/crates/rpc/rpc/src/debug.rs)
- [Reth 节点 RPC 资源限制选项](https://reth.rs/cli/reth/node/)

官方源码仅用于理解方法语义，不等同于对两个定制构建的完整源码审计。
