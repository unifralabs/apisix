# Usage 联合升级：生产只读复核

## 操作入口后续进展（本地准备，未上线）

新增独立人工操作入口 `Dashboard/clickhouse/usage_telemetry_release.py`，
支持固定目标、敏感备份校验、精确计划/代码/action及时效授权；默认原入口仍本地专用。
已在隔离本地模式复跑实际操作CLI与原恢复测试，结果见
`USAGE_OPERATOR_ENTRY_RESULTS_20260913.md`，生产步骤见Dashboard的
`dev/USAGE_PRODUCTION_RUNBOOK.md`。这不是执行生产写入的批准；本轮未访问生产。

## 最新进展：生产DDL本地演练已通过

用户批准演练后，以16:59导出的真实生产快照为来源，在内部隔离网络完成
12个迁移相关对象的恢复、迁移中断/确认丢失恢复、实际CLI及网关全链路和Dashboard服务/API测试。
详情见 `USAGE_PRODUCTION_DDL_REHEARSAL_20260913.md`。
未恢复7个无关/外部对象、未执行生产账号授权、未复制生产业务行，不能称为全实例灾备恢复。
生产迁移CLI保护仍在，未执行任何生产结构变更。下方早先“尚未恢复演练”描述保留为当时状态。

## 最新状态：2026-09-13 16:59（UTC+8）

以下状态覆盖本文早先的阻塞描述；早先记录保留用于追溯。

- 网关磁盘：指定旧镜像已清理，可用约15GiB，当前/回退镜像保留。
- Kafka：用户明确决定保持每分区10GiB限制与现有时间配置，不扩容、不要求保证7天。
  该容量决策已完成；上线前仍需刷新实际保留窗口、两个组位点和错误增量。
- 用户明确授权敏感DDL本地保存后，只读导出已成功。保护目录：
  `/private/tmp/unifra-prod-ddl-20260913-e_g65hsf`（0700）。
  `backup.json` 包含 metrics_prod 数据库DDL、19个表/视图（含内部表）的
  服务端SHOW CREATE定义、依赖清单、当前连接账号的SHOW GRANTS和版本信息；
  并非全实例所有用户/角色的权限备份。
  `plan.json` 包含目标绑定、12个原有对象定义/必要列元数据和不回填计划；
  `manifest.json` 包含文件及迁移脚本校验值。三个文件均0600，敏感原文未进Git或聊天。
- 计划ID：`ef427aab9b8614c47621716226401f2c8caacecd2ecb62dd1b5b1521e1993f0e`。
  独立重新读取文件核对SHA-256、大小、权限和计划指纹成功，
  计划原始DDL与备份中的对应定义一致；读取期间未发现这些对象的DDL变化。
- 本次只运行只读plan和元数据导出，没有运行prepare/resume/pause/publish，
  没有更改生产结构、消费位点、日志配置或Dashboard查询源。
  生成计划不是批准执行；迁移CLI的生产写入保护仍保持。
- 此处完成的是结构备份与计划生成，不是业务数据备份，也不代表已完成该生产备份的
  隔离恢复演练、所有有效权限验证或生产发布验收。临时目录可能被系统清理，
  正式维护前需确认文件仍在并按用户指定位置做持久安全归档；未擅自复制到其他目的地。

---

## 后续复核：2026-09-13 下午（UTC+8）

此节更新下方原始记录的三项阻塞状态；原始检查保留作为当时证据。

1. **网关磁盘已处理**：按用户明确清单删除 Dashboard 本地镜像
   `v0.9.8`、`v1.1.4-test`、`v1.1.5-test`；删除前确认无容器引用。
   可用空间增加 10,611,073,024 字节（约9.88GiB），变为约15GiB，使用率61%。
   当前运行的 `v1.2.0`、回退镜像 `v1.1.7` 保留；未重启或清理业务数据。
   本次再次登录复核为可用15G、使用率62%，console持续运行23小时；
   61%是删除完成时快照，后台正常写入会使使用率变化。
2. **Kafka实际窗口已量化，7天保证尚未解决**：
   - 请求topic仍为 retention.ms=604800000、retention.bytes=10737418240；
     segment.bytes=1073741824，cleanup.policy=delete；未改配置。
   - 只读指定分区的最早offset为2,873,801,638；不加入现有消费组、不commit。
     Kafka记录时间戳为-1；另取该条JSON的 `time`，只输出时间而非请求内容：
     1789223051.098，即2026-09-12 14:24:11.098 UTC。
     对比2026-09-13 07:48 UTC，最早可读记录业务时间距今约17.4小时。
     这是端点抽样与业务时钟估计，不是证明中间逐条无缺口或严格入站时间排序。
   - 分段文件共约10.695GiB；按17.408小时线性估算14.745GiB/天、
     103.212GiB/7天。该估算不是峰值容量承诺。
   - Kafka位于prod-db系统盘 `/data/kafka`，与ClickHouse共盘；
     系统盘193G、当前可用114G。取消大小限制后估计再增加约92.5GiB，
     剩余仅二十多GiB；流量波动或ClickHouse临时合并可进一步消耗余量。
     因此未直接取消限制，尚需扩容/容量预算决定。
   - 最近请求消费位点持续前进，两次lag为172、159，推送lag为0；
     不把瞬时小lag宣称为严格lag=0。正式暂停前仍须刷新两个组位点。
   - 维护建议（未执行）：两个暂停窗口分别控制在15分钟内，10分钟仍未能恢复
     应停止推进并进入已验证的恢复步骤；开始前须确认lag=0、无新增解析/写入错误，
     实际窗口及按峰值写入速度计算的余量足够。17.4小时不是获准暂停17小时。
3. **完整DDL/权限备份与精确计划仍被拦截**：本次用户要求解决该项后，
   准备了只读导出脚本，计划保存到本机 `/private/tmp/unifra-prod-ddl-20260913-*`，
   目录0700、文件0600、独占创建并校验SHA-256；不展示DDL、不入Git、无生产迁移写入。
   安全检查仍要求用户明确同意具体敏感载荷和本地目录，执行在启动前被拒绝。
   本次没有导出完整DDL/权限清单，没有生成生产plan指纹，也没有绕过拦截。
   待明确批准后才能导出，并继续独立恢复验证；DDL备份不是业务数据备份。

本次未修改Kafka保留配置、未扩容、未暂停消费、未执行ClickHouse迁移，
也未更改生产Dashboard查询源。两项待决事项不能标为已完成。

---

复核时间：2026-09-13 12:35–12:48（UTC+8），最后一次 Kafka 采样 04:48:31 UTC。
范围：经 JumpServer 访问 `prod-node`（10.142.0.19）、`prod-db`（10.142.0.18）；
ClickHouse 系统元数据查询设置 readonly=1、max_threads=2、10秒执行限制。

**结论：现有采集在前进，最后两个消费组 lag 都为0；本地基线的主要版本/列/依赖结构仍适用。
尚不能无条件批准生产迁移：网关镜像磁盘余量偏紧，完整DDL备份和精确迁移计划仍待另行授权。**

没有修改线上配置或业务数据，没有部署/reload/停消费/reset offset/重放消息，
没有清理镜像或数据库，没有发起 RPC 业务请求或订阅。只读检查会产生正常访问/查询审计记录。

## 运行版本与配置

| 项目 | 最新观测 |
|---|---|
| ClickHouse | 22.10.7.13；metrics_prod 为 Atomic |
| Kafka | 3.2.0，commit 38103ffaa962ef50 |
| Kafka 容器 Java | OpenJDK 11.0.15.1，满足候选取证工具的源文件运行版本要求；本次未上传/运行该工具 |
| APISIX | apache/apisix:3.14.0-debian；本机可见1个容器、2个worker |
| APISIX 代码 | 018e643e，工作树干净；新 telemetry 代码未部署 |
| Dashboard | ghcr.io/unifralabs/unifra_dashboard:v1.2.0 |
| Dashboard 镜像摘要 | sha256:d90ef2d2343df11b000df4b1686bc43a53da39ba0f26db3f56e295ca939dc2df |
| Dashboard 查询源 | USAGE_CHARTS_SOURCE 未设置，仍为 raw 默认路径；连接 metrics_prod |
| 服务器 nomad-config | a0761e4，工作树干净；本地已提交到890505f，服务器checkout少该后续提交 |

APISIX Admin API实际读取到的 HTTP Kafka metadata：`network=$route_name`，
route_name/transport/event_kind/schema_version 均未配置。不是根据 Git 文件猜测。
Arc/DogeOS HTTP、公用、WS 路由的 unifra-jsonrpc-var 网络配置分别是 arc-testnet/dogeos-testnet；
WS 仍使用 request_metrics_prod 和 request_metrics_event_prod 两个主题。
共枚举23条配置为启用且带日志插件的路由（含其他网络、NFT、OPTIONS）；这不是23个后端节点在线的证明。
本次仅核对所列主机，未进行全网实例发现，也不能用容器磁盘上的commit证明每个worker的全部代码已加载。

## ClickHouse 结构和存储

- 两个 Kafka 队列、三个原始表的列名和类型仍为旧版本，没有新 telemetry 字段。
- `usage_telemetry_v2` 名称空间为空，没有同名新表/MV冲突。
- 请求 Kafka队列 → 原文和展开 **两个并行MV**；展开表 → 原日/分钟汇总。
- 推送 Kafka队列 → 推送原始表单个MV；与本地复刻的旧依赖图一致。
- `system.mutations` 未完成任务为0；采样没有其他长时间执行查询。
- 原文/展开表的part事件和删除期限元数据相差7天，仍符合一周TTL。
  推送表part删除期限为2026-09-20 01:21:37–01:21:43 UTC。
  **未导出完整TTL/分区/排序/设置DDL，因此这不是完整DDL逐字节复核通过。**

首次parts元数据快照（不是对业务表做COUNT全扫描）：

| 表 | 行数 | 磁盘字节 |
|---|---:|---:|
| t_request_metrics | 91,511,764 | 18,358,873,189 |
| t_request_metrics_expanded | 98,850,140 | 18,697,466,642 |
| storage_mv_request_metrics_minutes | 121,177,915 | 1,731,580,024 |
| storage_mv_request_metrics_daily | 553,757 | 9,503,000 |
| t_ws_event_metrics | 3 | 1,242 |

随后原文/展开增长至91,546,708 / 98,886,968行，推送仍为3行。
该数量代表展开RPC条目/推送等各表口径，不能互相当作相同HTTP请求数。

## Kafka 消费与保留期

三个间隔采样：请求组 lag **114 → 129 → 0**；推送组 **0 → 0 → 0**。
请求消费位点从2,879,481,154推进到2,879,540,363，同一消费者持续消费，无本次重启/reset。

最后采样，两个主题各有一个分区：

| group / topic | committed | log end | lag |
|---|---:|---:|---:|
| clickhouse_consumer_prod / request_metrics_prod | 2,879,540,363 | 2,879,540,363 | 0 |
| clickhouse_event_consumer_prod / request_metrics_event_prod | 6,266,096 | 6,266,096 | 0 |

earliest offset 较早采样：请求2,872,385,476，推送6,266,093；当前committed未越过保留边界。
请求topic：delete，retention.ms=604800000，retention.bytes=10737418240（每分区10GiB）。
推送topic：继承delete、7天，retention.bytes=-1。

实际可恢复时长**未确认**：按时间查找请求offset时，6小时查询无结果、12小时查询超出25秒限制，
停止了该探测；确认没有遗留 GetOffsetShell 进程。没有据此推断实际仅保留多少小时，
也没有把配置7天当作保证。正式维护前仍需按当时流量/retention余量控制暂停窗口。

## 资源与已有告警

| 主机 | 可用内存 | 磁盘 |
|---|---:|---|
| prod-db | 8,130 MiB，约7.9GiB | 193G总量，约113G可用，42%使用 |
| prod-node | 5,671 MiB，约5.5GiB | 38G总量，4.9G可用，87%使用 |

ClickHouse MemoryTracking 约430–453MiB，短窗口无新增解析/转换/资源写入错误。
内部 KafkaConsumersInUse 一次为-1，本次不以该异常内部计数判断消费健康，以broker真实offset为依据。

已有 QUERY_NOT_ALLOWED 计数从382变383，最新04:44:04 UTC；错误分类命中
stream_like_engine_allow_direct_select，说明存在对流式引擎的直接查询被禁止。
没有读取完整错误文本或定位调用者；不能据此断言业务采集失败，因为消费位点持续前进且最终lag=0。
04:37最新认证失败来自本次不带密码的默认连接探测，之后使用已有凭据只读检查成功，勿误认为新业务故障。

prod-node 的Docker目录是系统盘上的 `/var/lib/docker`。当前Dashboard镜像Size为3,760,948,238字节，
约3.5GiB；新旧镜像共存、下载和解压需要额外空间。docker system df报告：
18个镜像、9个active、总18.27GB、可回收13.54GB。可回收不等于可安全删除，可能有回退版本。
**本次未清理；发布前应审批明确的清理清单或扩容，并保留回退镜像。**

## 未完成项和批准边界

1. 原本拟用只读plan保存完整DDL到本地0600文件；安全检查因DDL可能包含连接配置而拒绝执行。
   改为只读安全摘要后继续完成上述检查，**没有读取/保存完整DDL或导出权限清单**。
   `/private/tmp/unifra-usage-production-plan-20260913.json` 不存在。
2. 完整DDL、准确迁移指纹、权限核验、独立恢复备份仍需授权和验证；本次结构摘要不能替代这些门槛。
3. 网关系统盘余量偏紧，需清理方案或扩容决策。两次采集维护窗口、告警接收人仍需确认。
4. 复核不等于上线批准；候选迁移仍禁止生产写入。生产日志格式、Dashboard查询源均保持旧版本。
