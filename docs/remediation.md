# Wireless 修复建议

采集 `collect` 默认保存逐设备诊断与只读核查命令。只有指定 `--scripts` 才导出候选配置、回退草稿和受支持的类型化执行计划；诊断/导出均不连接额外设备、不修改已有报告：

```sh
bundle exec ruby bin/wireless review --batch /absolute/path/to/batch --scripts
# 可指定独立的私有输出根目录
bundle exec ruby bin/wireless review --batch /absolute/path/to/batch --output /private/reviews
```

默认输出到 `<batch>/reviews/<UTC时间>/`。退出码 0 表示建议文件生成成功，不表示网络健康或故障已修复；2 表示参数、输入结构或发布错误。

- `review.txt` / `review.json`：离线批次索引、建议分类和源文件 SHA256。
- `recommendations/*.txt`：普通文本报告，包含事实依据、适用条件、影响、待补信息、候选配置、条件回退和验收步骤。
- `*.json`：同一建议的机器可读结构，`schema_version: 3`、`kind: recommendations`、`review_only: true`。
- `*.verify.cli`：去重后的只读核查命令。
- `*.suggested.cfg` / `*.rollback.cfg`：全部注释化的配置草稿，不能整文件直接下发；TXT/JSON 内保留逐项 CLI。

`candidate` 是有本机证据支持、仍需确认业务意图的候选；`blocked` 缺少关键参数或有冲突；`investigate` 是定位、补采或核对设计的任务。空响应和部分配置不会推导“配置不存在”。所有目录 0700，文件 0600，可能包含内部设备及终端信息。

应用候选前重新采集并核对证据、版本、拓扑和审批窗口；原报告 SHA256 只用于定位本次证据，不能证明设备当前状态。分项验证效果；若命令超时或效果不明，先回读，不能自动重放。回退只在确认本次增量已生效且无并行修改时使用，业务通断须另行验收。只有独立 `apply` 命令可以下发受支持的类型化计划，且必须通过下述交互确认；不会自动保存 running-config。

当前修复规则针对 H3C：服务模板引用缺失/明确禁用、TKIP/WPA 兼容配置、AP 非 Run、射频管理 Down、历史客户端 IP 冲突及采集证据不足。Huawei 明确标记尚无修复规则，不输出 H3C 命令。

加固候选仅在已有 CCMP/RSN、明确模板启停状态、名称可安全渲染时生成。修改前停用模板，完成后恢复原启停状态；回退只恢复本次移除的 TKIP/WPA。该操作会中断相关 WLAN，必须先确认终端兼容性和维护窗口。服务模板引用缺失必须补齐 SSID、安全认证及 VLAN 意图，不能自动创建开放 WLAN。

历史冲突时间不含年份，不等同当前故障；需要对照新旧 MAC/AP、DHCP/静态地址和漫游。Radio Down 可能是频段规划，AP Idle 也需核对预期；不自动启用、清表、踢客户端或重启。

命令语法参考：[H3C WLAN 安全命令](https://www.h3c.com/en/d_202210/1709621_294551_0.htm)、[IP 冲突统计](https://www.h3c.com/en/d_202603/2774466_294551_0.htm)。现场软件版本仍须核对。

## 交互式下发

```sh
bundle exec ruby bin/wireless apply --plan /path/to/plan.json --item CHANGE_ID --env-file /path/to/.env
```

必须使用真实终端；不存在 `--yes`，管道输入不能确认。完整展示设备、前提、影响、配置与回退后，需准确输入 `APPLY <IP> <计划SHA256前12位> <CHANGE_ID>` 才连接设备。SSH 严格校验已知主机密钥，凭据沿用 NC_DEVICE_* / 平台 NC_*；环境文件沿用共享配置发现，也可用 --env-file 指定；空平台字段回退到通用凭据，平台 enable password 优先。

确认后先重读完整配置并核对已解析配置事实的指纹和动作前提；已解析事实变化、部分证据或未经支持的动作均拒绝写入。指纹不覆盖解析器尚未建模的配置行，不能替代全量配置审查。文件中的命令会由类型化动作重新渲染核对，不能编辑为任意脚本。每条命令前持久化意图，执行后保存回执状态。失败或中断立即停止并标记 uncertain，不自动重试、重连或回退；先人工回读确定实际效果。

成功只表示目标配置回读符合计划，仍需业务流量验收。执行日志位于 `wireless-executions/<UTC>/execution.json`，包含计划摘要和步骤状态、不含密码或原始回显。回退草稿只供审阅，不提供自动执行入口；计划也不执行保存配置。

plan.json 使用 schema_version: 3、kind: change_plan 和具名 changes，旁边的 plan.json.sha256 校验整个文件；每项变更仅包含单设备单项增量。旧报告及计划必须重新生成。应用一项后同设备其他旧计划会因配置指纹变化而过期，应重新采集/审查生成新计划，不能连续盲目运行旧计划。本入口只重新验证目标控制器的配置；终端兼容性、版本支持及业务意图仍由确认人核对。

当前可交互执行计划仅支持 H3C 已有 CCMP/RSN 替代协议、明确启停状态的 TKIP/WPA 移除；不能执行 AP 重启/开启射频、地址冲突清表或未知模板创建。
