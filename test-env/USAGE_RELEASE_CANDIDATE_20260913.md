# Usage联合升级：已提交候选清单（未批准上线）

日期：2026-09-13。三个仓库的功能改动已在本地分别提交；本轮没有push、
新建tag、触发构建、修改线上配置或执行数据库迁移。本文件自身是后续文档提交，
下表锁定功能代码提交，不依赖浮动分支HEAD。

## 精确代码版本

| 仓库 / 用途 | 分支 | 功能提交 |
|---|---|---|
| APISIX：HTTP/WS日志维度及配套测试 | `shu/zero-intrusion-refactor` | `8b508e323ac371f808b6018ad5a617c1d2d1016f` |
| Dashboard：人工迁移工具及操作手册 | `codex/usage-query-performance` | `f2d1e68271a43c67f5e71d105a0be823896a014d` |
| nomad-config：Kafka logger metadata | `main` | `eedb00cd6ee97f5cfee0160c10c71d7fdc420d35` |

APISIX需要同时部署两个插件文件和 `unifra/jsonrpc/telemetry.lua`，不能只拷贝插件目录
而漏掉共享模块。Nomad metadata精确匹配本地E2E采用的log_format；必须在新变量产生代码
启用后发布。Kafka10GiB保留策略、原始表TTL、CU价格、白名单及Redis账本逻辑不在这组改动中。

## Dashboard运行镜像与迁移工具是不同制品

- 已有应用镜像：`ghcr.io/unifralabs/unifra_dashboard:v1.3.0-rc.1`。
- 对应源码：`149448da75bae790ac8a0b5b79de6825024c5680`。
- GitHub构建34739187174：**completed / success**；build和push步骤均成功。
- 构建日志确认推送的最终manifest-list摘要：
  `sha256:f756526c114e0c7662f8ac3650a5416382b5dc37815e685944cfa9d331774be8`。
- 如批准使用该候选，建议锁定：
  `ghcr.io/unifralabs/unifra_dashboard@sha256:f756526c114e0c7662f8ac3650a5416382b5dc37815e685944cfa9d331774be8`。
- 来源：https://github.com/unifralabs/unifra_dashboard/actions/runs/34739187174

本轮只读核验了构建状态和推送日志，未重新拉取镜像或启动该镜像。
`f2d1e68`相较于镜像源码仅增加/调整迁移脚本、手册和测试，应用UI/API/query代码未变。
`clickhouse/`被.dockerignore排除，因此新的人工迁移入口**不在RC镜像中**，
需要从上述Dashboard仓库提交独立运行。不要把RC镜像误认为包含新迁移入口。

## 提交前最新回归

- 本地内部网络，真实APISIX→Kafka3.2→ClickHouse22.10.7.13；RPC上游是本地mock。
- 生产DDL快照的12对象恢复及当前候选全链路：
  数据库 `usage_topology_test_aac2a857d840`，PASS。
- 免费23CU、付费83CU、公共独立1CU、耗尽用户1CU；429不计费；HTTP/WS/推送维度正确。
- 最终raw/expanded/push行数27/31/3，含非法维度/旧格式等显式测试样本；本代对账通过。
- 同一数据源的真实Dashboard服务/API测试：PASS，免费23、付费83、用户WS15CU；
  冷服务调用50ms/2次CH查询，20次缓存调用0新增查询，不是线上P95或浏览器时延承诺。
- OpenResty telemetry维度测试、离线操作入口/旧入口生产拒绝测试、Python语法检查、
  Nomad与本地metadata逐对象相等、Git空白检查均通过。
- 前一轮实际operator CLI、原CLI、ACK丢失恢复结果见
  `USAGE_OPERATOR_ENTRY_RESULTS_20260913.md`；本轮未改变这些被测试脚本。

## 尚未纳入发布的本地文件

APISIX的 `.playwright-cli/`、`output/`、`test-env/__pycache__/` 以及既有的
`test-env/LIVE_SMOKE.md`、`test-env/test_live_smoke.py` 未加入本次提交，也未删除。
敏感DDL备份、环境凭据、生产API key没有加入任何提交。

## 下一道批准边界

1. 审核上述提交后push至对应远程分支；本次未push，不要直接在服务器pull并假设已有新版本。
2. 用户指定敏感备份的长期私有归档位置；执行前验证其完整性。
3. 生产上线单独批准；开始前刷新DDL、权限、磁盘、消费位点及实际Kafka保留余量。
   未开始的plan超过24小时须重新导出/审核，不能改旧时间戳绕过限制。
4. 按Dashboard `dev/USAGE_PRODUCTION_RUNBOOK.md`：ClickHouse准备并恢复采集 →
   APISIX代码及metadata → 第二次暂停对账、发布ready → Dashboard切telemetry-v2。
   不调用init、不重发Consumer、不清理Redis账本、不回填历史。

生成发布清单不等于批准上述任何生产操作。
