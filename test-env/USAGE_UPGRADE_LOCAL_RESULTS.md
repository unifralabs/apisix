# 联合升级第一阶段：本地结构可行性验证

日期：2026-09-13。**已推进到真实网关/节点及 Dashboard 联调，见第三阶段；生产迁移安全关口仍未全部收口，尚不能上线。**

> 后续同版本复验已完成，见文末“第二阶段”。当前已经使用与生产相同的 Kafka
> 3.2.0 二进制版本和 ClickHouse 22.10.7.13，基础 12 项、同构依赖 25 项通过。
> 以下第一阶段的环境/未完成清单是当时记录，不代表第二阶段后的最终进度。

## 环境和范围

- ClickHouse：本地 `usage-clickhouse`，22.10.7.13，与生产 ClickHouse 版本一致。
- Broker：已有本地 Redpanda v24.3.18，真实 Kafka 协议读写；**不是生产 Kafka 3.2**。
- 每次运行创建随机前缀的独立测试库、主题、消费组；不接触生产或其他开发库。
- 最新通过数据库：`usage_contract_test_0f0eb07ddc76`；12 个断言通过。
- 较早单请求主题版本也通过：`usage_contract_test_f92c795f2da9`。
- 失败运行的本地样本保留供排查，没有删除；脚本结束时仅 DETACH 自己的测试队列。
- 本轮只增加测试脚本/计划/报告，未修改生产插件、metadata、Dashboard 或生产结构。

## 发现 1：Kafka 表不能直接加列

实测错误：

```text
Code: 48. Alter of type 'ADD_COLUMN' is not supported by storage Kafka.
(NOT_IMPLEMENTED) (version 22.10.7.13)
```

普通 MergeTree 原始表追加带默认值的列成功，已有行读取默认值正确；
这不能代替 Kafka 接收结构升级。测试的可行替代步骤是：

1. DETACH 自己的 Kafka 队列，等后台读写结束。
2. 移除其消费 MV；ATTACH 队列后（此时无消费 MV）替换队列表元数据。
3. 使用**原主题、原消费组**重新准备接收表，准备全部下游后创建消费 MV。

未删除任何 MergeTree 数据、Kafka 主题或 offset。测试期间新生产的消息积压在 Kafka；
恢复后旧行与新消息各出现一次。这里只验证了简化图的正常停止与恢复，
尚未验证生产多入库 MV 图、全部故障恢复分支或原生 Kafka 3.2。

## 发现 2：队列表 DEFAULT 不能替代真实入库兼容处理

旧 writer 的 JSON 确实没有新字段。在 Kafka 队列声明默认值并启用
`input_format_defaults_for_omitted_fields=1` 后，实际落地仍得到：

```text
transport = ''
event_kind = ''
schema_version = 0
```

已在测试消费 MV 中显式按旧版本/主题转换，复跑通过：

- 请求主题缺字段 → `http / rpc_request / version=1`。
- 推送主题缺字段 → `ws / subscription_push / version=1`。
- 新日志传入 `ws / rpc_request / version=2` 时不被覆盖。
- SELECT 表达式必须引用 `q.schema_version` 等原始列，避免 ClickHouse 别名替换
  先把版本 0 变成 1，导致默认值条件失效；测试过程已捕获并修正该问题。

显式非法 v2 字段的拒绝/隔离处理仍需完整契约测试，当前脚本不声称覆盖。

## 发现 3：不能在消费恢复后再假定新挂汇总立即生效

多次运行都观察到：

- Kafka 已正常向 raw 写入，新建 raw → daily 物化视图，不使用 POPULATE。
- 随后两条新消息进入 raw，但等待后 daily 仍为 0 行。
- DETACH/ATTACH 队列刷新消费者后，随后两条新消息正确进入 daily：15 CU、2 条。
- 先前漏入 daily 的两条不会被重启自动补齐（原始表数据仍保留）。

这证明原计划“先恢复消费/升级生产者，再挂实时汇总”不能直接作为该版本的安全步骤。
原因可能涉及 Kafka 后台消费持有的下游执行图；测试确认的是上述可重复行为，
未把内部机制推断当成已完成的源码级根因诊断。

另一条推送主题采用“先建立 raw → daily，再启动 Kafka → raw”的顺序，
第一条旧格式推送即正确落地并汇总。最终 daily 为 24 CU、3 条，包含刷新后的
两条请求主题样本与新推送主题首条样本；之前原始数据没有被回填。

## 建议修正顺序（待确认，不是执行授权）

1. ClickHouse 消费维护窗口内，准备新接收表、兼容入库视图及全部实时汇总依赖。
2. 保持原消费组/主题恢复消费，确认旧格式继续正常处理。
3. 部署新 APISIX 插件，然后发布匹配的 metadata/路由配置。
4. 验证所有生产者新版本、旧格式积压消化、四类新流量及汇总结果。
5. 标记正式可用覆盖范围/ready，再切换 Dashboard；早期混合区间不宣称完整。

实时汇总提前创建不会自动复制历史，仍然遵守“不回填”。
这里的暂停仅涉及 Kafka → ClickHouse 消费，RPC 和 Kafka 日志生产不中断。
但维护时长与生产复杂依赖恢复尚未验收，不能现在承诺固定秒数或零丢失。

## 尚未完成的验收

- 原生 Kafka 3.2、生产同构的两个主题和全部入库/旧汇总依赖，以及每一步故障恢复。
- APISIX 新字段实际发出、Arc/DogeOS 本地网关 + 真实上游、免费/付费/公共计费回归。
- 新字段下的 Dashboard 查询/UI、用户隔离、新日汇总性能及 Metabase 模型。
- 无暂停替代拓扑没有实施；如坚持不停消费，需要单独设计平行接收链路和清晰统计边界。

上述项目不能沿用旧候选方案测试结果冒充通过。

## 复跑

在 APISIX 仓库执行；所有地址和凭据均为隔离本地测试值：

```sh
docker run --rm --network unifra-dashboard-dev_backend \
  --volume "$PWD/test-env:/tests:ro" \
  --env CLICKHOUSE_URL=http://usage-clickhouse:8123 \
  --env CLICKHOUSE_USERNAME=usage_test \
  --env CLICKHOUSE_PASSWORD=usage-local-only \
  python:3.12-alpine python -B /tests/test_usage_upgrade.py
```

脚本硬性拒绝其他 ClickHouse 地址/账号。PASS 表示已验证列出的行为和替代步骤，
**不表示原“不停消费、晚挂汇总”方案通过**；该风险作为探针结果单独打印。

## 第二阶段：原生 Kafka 3.2.0 和生产业务依赖图复验

### 精确版本与复刻边界

只读核对生产 Kafka CLI：`3.2.0 (Commit:38103ffaa962ef50)`。
本地 CLI 返回完全相同版本和提交号。生产私有镜像 registry 无权拉取，使用公开
`bitnamilegacy/kafka:3.2.0-debian-11-r20`，镜像摘要固定为：

```text
sha256:e087f4d1f199e871e0ad94fbdbc97c90d2c130e14f86f6559bd5ebe4c04423c9
```

因此是相同 Kafka 二进制版本，不声称相同私有镜像包装、操作系统或全部 broker 参数。
本地使用 ZooKeeper 模式、单 broker/单分区、独立本地网络，无宿主机端口。
ClickHouse 仍为 22.10.7.13；新增容器与原 Redpanda、其他开发数据分开。

只读获取并复刻了生产活跃业务链路的：

- 两张 Kafka 队列的字段类型、输入格式、主要消费 settings。
- 请求原文表、请求展开表、WS 推送原始表的字段、主键、分区和一周 TTL。
- 两个并列请求入库 MV、一个 WS 入库 MV，以及原有日/分钟汇总 MV 和存储表。
- batch 请求/响应数组及 CU 数组展开、429 过滤等实际表达式。

测试明确差异：broker/topic/group 改为随机本地名称；测试设置
`kafka_skip_broken_messages=0` 以暴露错误，生产当前是 1；不用测试通过证明坏消息策略相同。
未复刻无依赖的历史旧表、PostgreSQL 外部引擎、生产身份和业务数据。

### 同版本结果

| 套件 | 结果 | 测试数据库 |
|---|---|---|
| 基础结构与双主题兼容 | 12 项通过 | usage_contract_test_31d3fe787fce |
| 生产业务形状依赖与恢复 | 25 项通过 | usage_topology_test_19c9623db545 |

同构测试先在 Redpanda 通过（`usage_topology_test_4ec11136c18e`），再在原生 Kafka 重跑。
原生 Kafka 同样复现不支持 ADD COLUMN、旧字段默认值问题和晚挂汇总未立即收数。

候选升级将原来的两个并列请求 Kafka MV 改为：

```text
Kafka 请求队列 → 请求原文表 → 请求展开表 → 原日汇总 / 原分钟汇总 / 新日汇总
Kafka 推送队列 → WS 推送表 → 新日汇总
```

每张 Kafka 队列只有一个直接消费 MV，所有下游先建立再恢复入口。
这项依赖关系改变已在本地验证，不是单纯 ADD COLUMN，也尚未形成批准的生产迁移命令。

覆盖并通过：

- 暂停完成、队列表元数据替换、展开视图建立、汇总建立四个注入失败点；每次重试原始行数不变。
- 准备完成后丢失响应的重复执行是 no-op；缺少推送汇总时禁止任何入口恢复。
- 恢复 HTTP 入口后模拟中断，再恢复 WS；同一批 backlog 不重复计入。
- legacy + v2、HTTP + WS request、public 路由、batch、429、旧/新 WS push。
- 原始请求 6 条、展开 8 条、推送 3 条；展开前后计算 CU 均为 37（包括被限流的计算价格）。
- 新汇总不含建立前历史、不计 429 的请求 CU，得到 **19 CU、7 个条目、1 个限流条目**。
- 原日/分钟汇总仍各得到 7 个非限流请求条目、1 个限流条目。
- 消费者正常重启后，原始行数与新汇总结果不变。
- 测试结束后的 broker 只读核对：请求组 committed/end = **6/6**，推送组 **3/3**，lag 均为 0。
  无 active member 是测试 finally 主动 DETACH 自己的队列所致，不是消费故障。

这验证正常关闭/恢复及指定步骤异常，不是进程任意时刻崩溃、磁盘故障或 exactly-once 的证明。

### 新维度存储层性能样本

脚本：`test_usage_topology_perf.py`；数据库 `usage_topology_test_ae8b8e6220b8`。
百万条本地合成数据，按 user/app/network/route/transport/event_kind 查询；
直接 INSERT 用于存储层基准，不冒充经过 APISIX 或 Kafka 的百万条 E2E。

| 查询路径 | read_rows | read_bytes | ClickHouse elapsed（单次样本） |
|---|---:|---:|---:|
| 原始表 | 1,000,000 | 17,739,800 | 9.35 ms |
| 日汇总，默认索引粒度 | 12,000 | 1,338,680 | 0.975 ms |
| 日汇总，索引粒度 1024 | 1,024 | 114,249 | 0.531 ms |

三个查询都得到相同的 6 个维度组合、3,000 CU、1,000 条目标用户记录。
默认粒度减少 98.8%，未达到原 99% 读取量目标；1024 候选减少 **99.8976%**，达到该样本目标。
更细索引有额外索引空间/写入成本，仍需结合正式日汇总和持续插入评估。
这些不是冷缓存严格基准或 API P95，不能作为线上毫秒级响应承诺。

### 复跑原生 Broker 与测试

```sh
docker compose --env-file /dev/null -p unifra-usage-native \
  -f test-env/docker-compose.usage-native.yml up -d

docker run --rm --network unifra-dashboard-dev_backend \
  --volume "$PWD/test-env:/tests:ro" \
  --env CLICKHOUSE_URL=http://usage-clickhouse:8123 \
  --env CLICKHOUSE_USERNAME=usage_test \
  --env CLICKHOUSE_PASSWORD=usage-local-only \
  --env USAGE_TEST_BROKER=usage-kafka32:9092 \
  python:3.12-alpine python -B /tests/test_usage_topology.py
```

同一命令可将最后文件名替换为 `test_usage_upgrade.py` 或 `test_usage_topology_perf.py`。
本地 Kafka/ZooKeeper 和随机测试数据保留便于复查；不要将这些 guard 为 local-only 的测试脚本当生产工具。

### 第二阶段后的剩余工作

- 把验证过的恢复逻辑变成正式、可审查的迁移工具，补齐生产结构指纹/权限/锁和就绪状态检查。
- APISIX 与 nomad-config 的真实新字段输出及诊断事件分类、Arc/DogeOS 小流量完整日志验证。
- Dashboard 新维度 API/UI、私有/公共归属、日期覆盖、新结构版本门禁、浏览器及生产构建。
- 非法 v2 字段、坏消息、实际计费拒绝和未知扣费结果的完整验收；Metabase 同口径模型。
- 上线前再做资源/备份/lag/权限预检，取得生产批准。**本阶段仍不满足上线条件。**

## 第三阶段：候选代码、迁移工具、真实日志和 Dashboard

本轮没有生产数据库/配置写入，没有提交、推送、GitHub 镜像构建或上线。
真实节点只进行少量只读 RPC 和短时订阅；网关/Admin、账本、Kafka、ClickHouse 全部本地。

### 候选实现

- APISIX 新增纯日志维度模块；HTTP metadata 使用命名空间变量；WS 在连接时捕获配置维度，
  逐条分为 RPC request / subscription push / diagnostic。不改权限、CU 价格和 Redis 扣费函数。
- nomad-config 只改本地 `service/kafka-logger/log-format.json`，与测试 metadata 相同；未发布线上。
- Dashboard 新增独立 `telemetry-v2` 查询源，使用 `usage_telemetry_v2`，不混用旧 product 汇总。
  日汇总、API、页面统一 network / route / transport / event_kind；保留严格 owner 过滤。
- 迁移候选工具位于 Dashboard `clickhouse/usage_telemetry_v2.py`。只读 plan 导出原 DDL、目标和 SHA256；
  本地 prepare/resume/status 有审批指纹、服务器侧排他锁、初始/半途中源结构检查、视图语义检查、
  prepared 后 14 个对象完整 DDL 指纹。当前故意没有生产写入开关或生产 publish 命令。
- 原始表只追加列；额外 `usage_generation` 是 ClickHouse 内部审计标记，不进入 Kafka、计费或 Consumer。
  它区分本次接收与历史原始行，避免“同一天已有历史”被混进无回填审计。
- 类型合法但维度非法的 v2 日志留在 raw，排除在用量之外；提供运营诊断视图。
  Kafka 本身无法解析的坏 JSON 不属于这类隔离，见后面的实测风险。

### 本地真实网关 → 原生 Kafka → ClickHouse

`test_usage_gateway.py` 直接调用 Dashboard 的迁移候选代码，不再只测试复制的 DDL 实验。

- 最新强化版通过数据库：`usage_topology_test_ce451b75cf3a`。
- 当前浏览器预览库：`usage_topology_test_a291759e9775`，同一数据结构，免费测试日志归属本地登录用户。
- 免费账户 **23 CU**，付费账户 **83 CU**，限额账户 **1 CU**，各自与真实本地 Redis 账本一致。
- 公共入口 **1 CU** 只属于独立 public owner，不进入以上三个用户用量。
- 覆盖 HTTP/WS、单条/batch、免费拒绝付费 method、HTTP/WS 429、subscribe/push/unsubscribe、
  真实 Kafka 新字段、伪造维度请求头无效、旧消息默认值和明确历史 alias 归一化。
- 4 个 prepare 中断点重试、prepare/resume 重复执行、HTTP 已恢复后中断恢复、同名视图替换门禁、
  不回填历史、整代 raw/daily 对账通过。
- 4 条非法维度记录 + 1 条 diagnostic 保留 raw、不计用量；旧请求主题缺字段的 7 CU 正确归为
  `arc-testnet / empty legacy route / http / rpc_request`。

测试初稿使用同步 Kafka 生产模式，出现 HTTP 重复发送/空错误及新主题首次创建丢日志。
现已预建并验证随机主题就绪，HTTP/WS 都改为仓库生产采用的 async 模式，重跑原始条数和 CU 一致。
这说明测试必须对齐实际生产模式；没有据此断言线上异步模式存在相同重复问题。

### 真实 Arc / DogeOS 节点

`test_usage_real_nodes.py` 读取 nomad-config 中真实节点 IP；不导入生产日志地址或健康探针。
通过库：`usage_topology_test_1fadfe31003b`。

- 两个网络分别验证免费、付费：HTTP/WS chainId、blockNumber、newHeads 推送、unsubscribe。
- 四个账户各 **11 CU**，全部与本地 Redis 和新汇总一致。
- 两个公共 HTTP 入口各 **1 CU**，运营总计 **46 CU**，与 Metabase 候选 SQL 一致。
- 每个私有账户的三组维度：HTTP/request、WS/request、WS/push，全部匹配真实网络与入口名。
- 整代原始/展开/推送/汇总审计通过；测试后关闭 WS，恢复本地 mock 路由，断开网关临时出口。
- 首次真实公共请求测试漏了 JSON Content-Type，已补齐并从头复跑通过；没有把失败算作通过。

### Dashboard 和浏览器

- `tests/usage-telemetry.ts`：结构版本/ready/缺失视图、非法时间/维度、月初半天、HTTP/WS 真正汇总、
  WS request 与 push 分开、owner 转义通过。
- `tests/usage-telemetry-service.ts`：实际新汇总表 + 本地 Postgres + API handler 验证通过。
  冷请求 2 次 ClickHouse 查询，本地样本 **76 ms**；20 次缓存读取新增查询 **0**。
  不是线上 P95。请求参数不能选择另一个付费用户/public app；错误契约返回 503，不扫描 raw 兜底。
- 现有 `usage-performance.ts` 回归通过；最终 TypeScript、指定文件 lint、独立本地生产 build 通过。
  build 只留既有 Browserslist 数据库过期提示，无新增 lint 警告；不是 GitHub 镜像构建。
- Playwright 浏览器验收：6 张图、完整日期提示、周/月切换新增请求 0、未登录接口 401；
  模拟 503 有错误提示，Retry 后恢复。修复了单数据点虚线圆显示不清、首次失败空图出现 Jan 70/Invalid Date。
- 最终截图：`output/playwright/usage-telemetry-v2.png`。本地登录用户图表为23 CU；顶部卡片仍为存储0并有
  fallback警告，因为测试账本使用唯一 quota key，没有为了预览修改真实登录用户账本。
- 现有 APISIX 计费 E2E **49 passed / 0 failed**；OpenResty 集成测试也通过，包括586项RPC policy检查。

### 迁移 CLI 与坏消息实测

- `test_usage_migration_cli.py` 实际执行 CLI，不仅导入类。验证 plan 不改库、0600备份权限、错误审批拒绝、
  prepare/resume 重复执行、status、排他锁冲突及失败竞争者不释放别人的锁。
  首次通过库 `usage_topology_test_5211f043d12f`；最终强化版 `usage_topology_test_9ce8d4a1a50d` 也通过。
- `test_usage_bad_messages.py`：原生 Kafka 3.2 / CH22.10，通过库 `usage_topology_test_bba020fcff27`。
  两个消费组读同一主题的“合法1 / 坏JSON / 合法2”：
  - 生产现有 `kafka_skip_broken_messages=1`：合法1和2入库，坏JSON不落raw。
  - `=0`：停在坏消息，合法2不再入库。
  - 结束时detach自己的队列，未reset offset或删除主题。坏消息仍在Kafka保留期内，但不能说已被诊断视图保存。
- 此版本没有 `system.kafka_consumers` 表，生产监测方案应使用 broker消费组offset/lag + CH日志/错误指标，
  不要照搬新版本该系统表的查询。

### 第四轮：发布恢复、坏消息取证与最终回归

本轮仍全部本地；未提交、未推送、未构建 GitHub 镜像、未改变生产消费策略。

- `test_usage_release.py` 最终通过库 `usage_topology_test_2235f0b64e50`（此前 `usage_topology_test_a4694af2185d` 也通过）。
  新增 pause/resume/withdraw/publish，验证 prepared INSERT、暂停 DROP、恢复 HTTP ingress CREATE、
  ready INSERT 成功后丢失客户端响应的重试。首次发布需要新鲜、匹配计划的操作员验收证据和
  稳定 raw/daily 审计；错误计划、过期证据、非零 lag、缺少 WS push 验证会拒绝。
  再次 ready 不移动完整覆盖边界；withdraw 后仍可采集，resume 不自动重新发布。
  回退期间再写入旧格式消息，最终汇总7 CU与原始数据一致，无历史回填、无offset重置。
  构造生产数据库名但不连接生产，确认目标保护在执行任何SQL前拒绝。
- `test_usage_migration_cli.py` 最新通过库 `usage_topology_test_7043cb7ac48f`。
  真正运行 CLI 的暂停/重复暂停/撤销就绪/恢复和缺失 evidence 拒绝测试，原有指纹、文件权限、
  排他锁保护继续通过。
- `test_usage_forensics.py` 最终通过库 `usage_topology_test_231951cd6d62`（此前错误指标版 `usage_topology_test_d2566527b75b` 也通过）。
  Kafka3.2 自带客户端库编译运行只读 `KafkaRecordExport.java` / `KafkaLagCheck.java`：
  3条记录逐字节、SHA256、partition和offset一致；导出前后原组offset不变；
  skip0 lag=2返回告警，skip1 lag=0但CH解析错误增量仍可被发现；未知组不算正常0积压。
  越界、超过1000offset范围拒绝；0600临时保留文件通过。最终版包含输出写入失败检查。
  本地将该3条记录的导出写入 `/dev/full` 注入失败：退出1并明确报告 `export is incomplete`，没有误报COMPLETE。
  实际运行解析错误监控CLI：snapshot/check正常、0600基线文件、拒绝覆盖既有baseline通过。
- `usage_ingestion_check.py` 使用22.10真实 `system.errors`，解析错误增量、重启/计数变化拒绝
  被默认为健康；它是实例级告警线索，需要日志归因，不是自动证明迁移损坏数据。
- 完整本地网关 E2E 最终通过库 `usage_topology_test_7aee947af2f1`。
  免费23 CU、付费83 CU、独立公共1 CU、HTTP/WS分类、非法维度隔离、旧格式兼容及整代审计仍通过。
  本轮没有重跑真实上游，前一轮真实 Arc/DogeOS 结果和浏览器结果保持独立记录。

操作文档已补齐：Dashboard `dev/USAGE_TELEMETRY_V2.md`（发布/恢复）和
`dev/USAGE_INGESTION_OPERATIONS.md`（错误、lag、保留与人工处理）。
明确采用两次短暂的**采集暂停**：建完整依赖图、发布前稳定对账；不是重启/暂停整个ClickHouse。
异常原文按需导出、仅在Kafka尚保留时可救取，不是常驻DLQ，不自动重放；保留生产现有skip=1。

### 仍需生产批准和现场复核的事项

1. 当前 CLI 明确禁止生产写入；开启前需新鲜的目标DDL、资源/权限/lag/备份/保留期余量检查，
   审计耗时预算及两次短暂停采集的批准。生产 alert 接收人/渠道尚未接入，工具没有定时执行。
2. 全部生产者版本/metadata与worker清单不能由本地样本证明；publish evidence是操作员确认，
   不是工具自动发现线上全部实例。生产Java环境亦须支持工具的源文件运行方式（JDK11+）。
3. 本地有限故障注入不覆盖所有进程崩溃/掉电/磁盘失败边界；不承诺exactly-once或零丢失。
   整代审计只适用于原始数据未超保留期（候选拒绝6天以上计划）；长期回滚后重新发布需另审。

正式候选说明：Dashboard `dev/USAGE_TELEMETRY_V2.md`；Metabase SQL：
`clickhouse/usage-telemetry-metabase.sql`。新方案没有历史回填，没有 Redis 用量同步或 Consumer 重发。
