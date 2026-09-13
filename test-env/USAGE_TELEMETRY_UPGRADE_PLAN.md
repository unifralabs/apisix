# Usage、日志语义和 HTTP/WS 分类联合升级计划

日期：2026-09-13。状态：**本地候选已实现并完成多轮验证，未批准生产变更。**

> 本地可行性验证更新：22.10.7.13 的 Kafka 表不支持 ADD COLUMN；晚挂下游汇总 MV
> 在持续消费时多次复现漏收新行，刷新消费者才开始接收。此前的“恢复消费后才挂汇总”顺序
> **不可直接执行**。改为一次受控的消费维护窗口内准备接收表和完整下游，再恢复消费；
> 日汇总先收集，Dashboard 的 ready/完整覆盖标记最后开启。此顺序调整待用户确认，
> 不代表已批准生产维护。该修正顺序已经在原生 Kafka 3.2.0 上完成本地依赖图验证，
> 第 5 节已更新为候选顺序；迁移工具、APISIX/Dashboard 联合验收、真实上游和
> 本地发布恢复/坏消息取证测试已完成。工具仍禁止生产写入，尚未进行新的生产发布前复核。
> 详见 `USAGE_UPGRADE_LOCAL_RESULTS.md`。

本文取代 Dashboard `dev/USAGE_AGGREGATES.md` 中的历史回填发布流程；旧文档、
`clickhouse/usage_daily_v2.py` 的 capture/backfill/audit 命令不能直接用于本方案。
下面保留完整验收设计；实际完成范围和数值以 `USAGE_UPGRADE_LOCAL_RESULTS.md` 为准，
不能将设计中的样本数/P95目标当成实测结果。

## 1. 范围和不做的事情

- 同时解决 `/usage` 查询性能、network/入口语义、HTTP/WS 与请求/推送分类。
- 优先验收 Arc testnet、DogeOS testnet；共享 metadata 的其他路由必须做静态兼容审计。
- 不回填历史，不修改原始表的一周 TTL，不清空或重算 Redis 计费账本。
- 不修改 CU 定价、白名单、eth_getLogs 策略、Consumer 权限或同步逻辑。
- 不合并 Kafka 两个主题，不改变既有消费组或主动重置 offset。
- 不开展多 APISIX 实例测试、大规模压测；生产发布仍须确认所有运行实例加载新版本。
- 搁置的 `codex/parked-rpc-telemetry` 只作为代码来源逐项审查，不整体合并，以免覆盖已上线安全修复。

## 2. 数据契约

| 字段 | 新日志定义 | 缺失字段兼容规则 |
|---|---|---|
| network | 规范链网络名，例如 dogeos-testnet、arc-testnet | 保留旧日志的原值；新查询需要时用明确的别名映射归一化，不做全局字符串截断 |
| route_name | 配置中的入口名称，例如 dogeos-testnet-public、dogeos-testnet-ws | 空值；必要的旧格式入口推断必须单独标注，不能伪装成实测 |
| transport | http / ws | 请求主题默认为 http；推送主题默认为 ws |
| event_kind | rpc_request / subscription_push | 请求主题默认为 rpc_request；推送主题默认为 subscription_push |
| schema_version | 新契约版本 2 | 旧消息版本 1；用于发现遗漏升级的生产者，不作为计费字段 |

沿用 user_id、app_id、cu_cost/cu_costs、状态、时间及 subscription_type 等已有字段。
route_name 来自可信路由配置，不能包含 URL、API key 或用户提供的路径。

用户已接受：旧请求主题里少量 WS 请求可能被默认归到 HTTP；这只影响分类，
不能改变 CU、所属用户或权限。旧消息默认值必须在真实 Kafka JSONEachRow 解析中验证，
不能仅用直接 INSERT 验证。缺失字段与显式非法字段分开处理；非法值不可悄悄改成合法值。

四类必验样本：

| 流量 | network | route_name 示例 | transport | event_kind |
|---|---|---|---|---|
| 私有 HTTP RPC | dogeos-testnet | dogeos-testnet | http | rpc_request |
| 公共 HTTP RPC | dogeos-testnet | dogeos-testnet-public | http | rpc_request |
| WS 普通 RPC / 订阅请求 / 取消订阅请求 | dogeos-testnet | dogeos-testnet-ws | ws | rpc_request |
| WS 订阅后的节点推送 | dogeos-testnet | dogeos-testnet-ws | ws | subscription_push |

## 3. 各仓库工作项

### APISIX

- HTTP 与 WS 日志使用同一契约；HTTP metadata 所需变量在新插件中明确产生。
- WS 请求和推送都携带 network、route_name、transport、event_kind、版本。
- 不改计费时机和价格；避免握手、订阅响应、推送在两个 logger 中重复产生计费记录。
- HTTP 非 Upgrade 请求访问 WS 路由时不能因路由名带 ws 就被误认作 WS 业务流量。

### nomad-config

- 新代码先部署，随后启用配套 HTTP Kafka metadata 和路由配置。
- Arc/DogeOS 路由的 network 已正确，保留；日志 network 改读规范变量，入口存 route_name。
- 同步审计 Conflux 两条 NFT 路由（现 network 带 -nft-api）、公共路由及通用 OPTIONS 路由。
- OPTIONS 不当作业务链网络；具体过滤行为用测试固定。NFT 等非 RPC 入口不得被新变量改为空或误计入 RPC 汇总。
- Service 6 保留；不顺带删除历史路由或改其他业务策略。

### Dashboard / ClickHouse

- 调整 Kafka 接收表、原始落地表和入库物化视图，让字段端到端保留。
- 原始表仅追加必要列，不执行 MATERIALIZE COLUMN、历史 UPDATE 或全表重写。
- 现有两个 Kafka 主题、原始数据、旧日/分钟汇总及 Metabase 旧视图保留。
- 新日汇总按 `(user_id, day UTC, app_id, network, route_name, transport, event_kind)` 分组，
  使用用户优先排序、月分区、独立 13 个月 TTL；不把 request_id、请求体、IP、完整 URL 放进汇总键。
- 指标包括 CU、条目数、限流条目数；请求条目按展开后的 RPC 计算，推送条目按通知计算，
  两者不能混称 HTTP 请求数。CU 延续既有账本/日志规则，对拒绝和错误行为逐项验证。
- 取消旧候选中的 history/snapshot/stage 回填结构；保留实时汇总、查询入口及 readiness/覆盖范围记录。
- 查询始终 SUM/GROUP BY，不依赖后台 merge 或 FINAL；启用后不扫描原始表。
- 保留用户级缓存、并发合并、错误重试、显式 raw 回退；更新缓存/控制记录版本，拒绝误用旧候选汇总结构。
- 顶部本月额度仍读 Redis（或明确标注的存储值回退），不与新图表覆盖范围混为一谈。
- 页面展示按链网络、应用、HTTP/WS 和请求/推送的准确口径；公共用量不能混入个人账户。
- 启用前未知历史不显示成 0；启用当天/当月标不完整；覆盖日期使用 UTC。

### Metabase

- 更新共享查询模型的字段口径，再更新依赖报表；新旧模型并存便于回滚。
- 旧 network 别名显式映射，不让不同报表各自猜测；不能把原始表与覆盖相同区间的新汇总相加。

## 4. 本地验证计划（按顺序执行）

### A. 固定基线与隔离

- 使用 ClickHouse **22.10.7.13**、真实本地 Kafka（精确 DDL 演练优先匹配生产 Kafka 3.2）、
  本地 APISIX、Redis、Postgres、Dashboard。新测试数据库/主题/消费组显式命名。
- 复刻生产两个 Kafka 队列、HTTP 展开链路、WS 入库链路、旧汇总依赖及实际 settings。
- 禁止测试工具连接生产 Admin API、Kafka、ClickHouse、Redis 或 Postgres；日志不得打印密钥。
- 构造旧日志、少量既有原始数据及已提交 offset，作为升级前基线。

### B. 接收结构滚动兼容测试

- 旧插件 + 新接收结构：默认分类正确，旧报表/入库不中断。
- 新插件 + 新结构：全部字段落地；新旧日志混合、缺字段、空值、批量 RPC、错误消息逐项验证。
- 同一个日志格式分别验证“缺失”和“空字符串”的行为；不允许以 kafka_skip_broken_messages 跳过测试失败。
- 持续低速写入期间执行候选 DDL；记录每个 Kafka 分区起止/提交 offset，核对消息和 CU。
- **先验证 22.10 是否支持计划中的 Kafka schema 和 MV 在线调整。**
  不假定 ADD COLUMN/视图替换在整个链路上原子生效；不盲用旧迁移文件的 DROP/CREATE。
- 注入每个 DDL 步骤失败、客户端响应丢失后重试，确认幂等、旧链路可恢复、不会启动重复消费者/MV。
- 如果必须重建 Kafka 接收表，记录实际维护步骤和消费恢复结果，单独提出短暂停消费方案请求批准；
  不能为了兑现“零暂停”而接受统计缺口或重复消费。

### C. 本地完整链路与计费一致性

- 每个网络覆盖免费、付费和公共入口：普通 HTTP、公共 HTTP、WS RPC、订阅/取消、至少 3 条推送。
- 覆盖成功、付费方法拒绝、429、参数错误、上游错误、batch、notification、WS 断开与重连。
- 用固定测试用户/应用和请求标识逐项核对：APISIX 输出 → Kafka → 原始表 → 日汇总 → Dashboard API。
- 合法请求及推送 CU 与预期/local Redis 增量核对；重订阅/取消/握手不能被误算成推送。
- 私有用户不得读到他人或 pub_user_id 的用量；伪造查询参数不能改变 session owner。
- 额外验证同一 network 的三个入口聚合可合可分，WS 普通请求不再被归到 HTTP。

### D. 无历史回填的启动边界

- 先写入旧数据，后启用两个实时汇总 MV；断言历史行不被复制，禁止 POPULATE。
- 记录两个 MV 的启用时间、共同可用起点、首个完整 UTC 日期及契约版本。
- 测试升级中的旧消息积压、跨日迟到消息、两个 MV 创建间隔、月界/年界；
  写入边界与事件时间不是同一概念，旧日期迟到事件不能使页面声称此前日期已完整。
- 先验收全部日志生产者的新格式并确认旧积压消化，再发布汇总 ready；汇总采集已提前启动，启用日标部分数据。
- 持续写入时核对固定测试批次，不扫描全库对账，不要求为旧 capture/audit 流程暂停消费。
- 新 MV 不存在、未 ready、格式不符时必须禁止 Dashboard 新模式；恢复后还需确认没有漏汇总区间。

### E. 真实节点小流量验证

- 复用 `test-env/test_real_nodes.py` 的本地网关 + Arc/DogeOS 真实上游模式，若连接条件允许。
- upstream 地址取 nomad-config；网关、Kafka、数据库、账本全部本地。
- 该现有测试目前把 Kafka 指向禁用目标，必须显式改为隔离的本地 Kafka 后才能称为“日志端到端验证”。
- 每链普通调用及 3 条 newHeads 推送即可；不广播交易、不用生产 API key、不做重查询或压测。
- 若真实节点不可达，记录未验收项，不用 mock 通过冒充真实节点测试通过。

### F. 性能、页面和回滚

- 复用/改造 Dashboard `tests/usage-performance.ts`、`tests/usage-aggregate-service.ts`、
  `tests/usage-aggregation.py`、`tests/usage-aggregation-kafka.py`；新增契约断言。
- APISIX 复用 access/billing/WS security 测试；评估 parked 分支 `test_telemetry.py` 的可复用部分。
- 至少百万行本地合成数据，包含多用户、多路由及新维度，核对原始与汇总结果；分别报告冷/热查询，
  read_rows/read_bytes、执行时间、响应体积，不能套用旧方案的基准结果。
- 验收目标：数据分布合理的本地样本读取行数降低至少 99%；API 冷查询 P95 < 1 秒，
  热缓存无 ClickHouse 查询；少量顺序样本测量，不做生产或大规模负载测试。
- 浏览器验证登录用户、UTC 日期、空白/不完整历史、分类/范围切换、错误提示/重试、跨月账本展示。
- TypeScript/单元/集成测试、生产模式构建通过；浏览器验收按 Playwright 技能执行。
- 演练 Dashboard 回退 raw、APISIX 回退旧输出、新旧消息继续消费，以及新 MV 失败后的降级路径。

## 5. 生产升级顺序（每步通过再进行下一步）

1. **审批前交付**：三个仓库精确 diff/commit、版本兼容表、DDL dry-run、本地测试报告、
   变更窗口与回滚命令。该联合方案所有必测项通过后请求生产批准。
2. **上线前只读复核**：重查版本、schema、所有生产者/消费者、offset、lag、磁盘/内存、错误、权限、
   新对象命名冲突；保存 DDL/配置和独立可恢复备份的证明。此前预检不是永久有效的通行证。
3. **接收层先升级**：在经批准的短暂消费维护窗口内，按本地验证过的顺序追加落地列、
   替换队列表元数据，先建全部下游（包括空汇总及其 MV），最后恢复每个 Kafka 源的唯一入口 MV。
   请求展开由原文表级联，保留原日/分钟汇总。新日汇总开始收集，但控制状态不标 ready、不切 Dashboard。
   旧格式在入库 MV 显式兼容；确认原始数据、旧汇总无损，主题和消费组不变。不能等恢复消费后再挂新汇总。
4. **APISIX 代码后配置**：先部署支持新字段的插件并逐实例 test/reload；随后发布 nomad-config
   日志 metadata/必要路由配置。不得只 git pull 后假定 worker 已生效。
5. **验证新日志**：经用户批准，用测试账户在 Arc/DogeOS 四类入口做少量请求/订阅，确认格式、归属、
   CU、offset/lag、错误计数；全部生产者版本检查通过，旧格式积压已消化。
6. **验收实时日汇总**：汇总已在第 3 步随消费恢复开始收集，不回填、不 POPULATE。
   新生产者切换完成后核对小批次、两消费组 lag 和 CH 错误；进行第二次短暂采集暂停，
   稳定对账后先恢复入口再标 ready。首个完整日从发布后的下一 UTC 日算起，
   首日/混合版本区间不得声称完整，此时 Dashboard 仍保持旧查询。两次暂停都须提前获批。
7. **Dashboard 切换**：部署批准镜像，验证新结构版本后开启 `telemetry-v2` 模式，淘汰旧实例；
   验证用户隔离、覆盖说明、顶部账本、分类和实际线上性能。
8. **Metabase 与观察**：切换相关报表模型；观察至少一个完整 UTC 日及正常流量周期。
   不自动删除旧结构/旧视图，不主动清理任何用户数据。

## 6. 停止条件与回滚

- 出现解析/入库错误、offset 不前进/积压持续增长、字段归属错误、CU 不一致、重复/漏汇总，立即停止下一步。
- Kafka/MV 错误不得通过增加跳过坏消息数或忽略写入错误来掩盖。
- Dashboard 问题：withdraw 撤销就绪，显式回退 raw 并重启/切镜像；新增结构保留，接受旧查询的已知性能限制。
- 新生产者问题：先将 metadata 恢复为与旧插件兼容的配置，再按匹配版本回退插件；旧格式仍能入库。
- 新汇总 MV 影响入库：先禁用 Dashboard 新模式并暂停相关采集入口，保留消息、offset及结构证据。
  隔离故障 MV 以恢复原始采集需要单独审查，不自动恢复旧的并行 Kafka MV 拓扑；
  标记这一代汇总未就绪，不能简单重新 attach 后宣称数据连续。
- 若需要丢弃失效的新汇总、修复缺口或另起统计起点，须单独批准；不偷偷回填。
- 新接收结构问题：使用本地演练过的恢复步骤，保留原表和消费组 offset；不得盲目删表或改消费组来重试。
- 这是对已有至少一次 Kafka 投递链路的升级，不承诺新增 exactly-once；测试报告区分新增问题与既有重复投递风险。

## 7. 最终交付清单

- 字段契约与新旧日志样本（脱敏）、各入口映射清单。
- 三仓库变更列表、兼容性顺序和回滚配对版本。
- 无回填迁移工具、只读预检、升级/恢复命令和执行检查点。
- 可重复运行的本地 E2E、迁移故障测试、浏览器截图及性能报告。
- 尚未验收项、生产必查项和必须单独申请的操作明确列出。

本地实现和验证已进行多轮，实际结果见测试报告。没有修改生产服务、数据结构、日志格式或计费规则。
