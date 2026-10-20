# 独立 Wireless 的职责边界

当前 gem 的业务链路为 `CLI Options → Collect → Collector → Profile/Parser → Observation/Snapshot → Review/Recommendations → Report`。核心负责无线事实与证据；宿主负责设备清单、凭据、并发、输出和持久化。

| 对象 | 职责 |
| --- | --- |
| `ParserRegistry` / 平台 `Profile` | 选择平台及型号策略，声明共享命令与对应解析器 |
| `Collector` | 固定一次请求和策略，拥有一次控制器采集流程，按命令顺序读取 |
| `ApSession` | 显式 AP 中转会话、提示符确认与退出恢复，独立校验回执 |
| `Observation` / `Snapshot` | 不可变事实、完整性与来源；默认调试展示只含元数据 |
| `Projection` | 提供宿主可用的投影状态，不执行数据库写入 |
| CLI `Options` / `Collect` / `Report` | 有效配置、设备批次及私有报告发布 |

子职责的目录与常量对应：`cli/review/report.rb` 定义 `CLI::Review::Report`，`cli/connector.rb` 定义 `CLI::Connector`。审查模块编排业务产物，`CLI::Report` 拥有批次目录与原子发布；采集连接适配器拥有控制器会话。测试目录跟随实现目录组织。

同一命令的多个维度使用一次解析，Collector 复用请求开始时选定的 Profile。连接器重复 yield 不重放查询、不覆盖首次事实；单台控制器内 AP 邻居采集保持顺序，独立控制器可以并发。AP 读取失败与退出失败分别保留为安全代码，其他已确认记录仍保留。

CLI 与配置备份、VXLAN 共用 `Net::Connector::Config`、`Collect::Progress`、`Parallel::Pool` 和 `Resources`。资源预检按实际活跃设备数计算，失败发生在创建报告和连接设备之前；取消必须先回收线程再完成摘要。公共连接器仅由宿主按需加载，纯解析不读取环境、不创建连接、不持久化事实。报告保存与采集完整性分别记录，保存或显示故障不能变成成功。

验证入口为 `bundle exec rake`，包含解析、控制器/AP 生命周期、CLI、报告故障与离线示例。基准与替身会话只能证明本地处理和控制流程；实机平台与版本需另行验证。安装、配置及命令详见 [README-zh.md](../README-zh.md) 和 [CLI 说明](../bin/README.md)。

## 历史宿主集成

> 以下保留模块从 Motor 提取前的领域设计、覆盖范围、限制与验证记录，供迁移和故障分析使用。
> 当前独立 gem 的安装、依赖、开发与发布入口以 [README-zh.md](../README-zh.md) 为准。
> 涉及 `Motor::*`、`Sync`、`Baseline::Check`、数据库、Rails、Rake 运维任务及私有实机证据的内容均属于 Motor 宿主集成，不随 gem 提供；历史验证记录不代表当前用户设备已经验证。

# 无线设备采集与入库

Motor 自有的无线业务实现，参考 Netstack 已验证的命令、字段及完整性规则，按现有 Rails 模型重新组织。数据模型继续使用 `Motor::WirelessAp` 等现有类，不新增表或字段。

## 实现方案

`Motor::Device → Motor::Devices::Connector → Wireless::Collector / CtxDriver::Reader → Configuration / RuntimeParser / NeighborParser → Snapshot → Sync → AssetInventory / DetailInventory`

- 公共 `Connector` 管理凭据、严格主机密钥校验和会话生命周期；[`CtxDriver::Reader`](https://github.com/gatework/ctx_driver) 通过宿主注入的会话执行单条查询、验证响应并记录来源摘要。每台控制器使用一个会话顺序采集，共享命令只执行、解析一次；单脚本失败不丢弃其他结果，断线后不自动重连。AP 子会话由 `Collector.new(ap_session_factory: factory)` 注入，每个 AP 的邻居读取和解析分别隔离失败。内置 `ApSession` 仅在宿主自行安装 net-connector 0.13.0 及以上版本，并使用 ctx_driver 0.2.2 及以上版本 并显式 `require "wireless/ap_session"` 后可用；默认加载、配置解析和普通控制器采集均不引入传输库。
- 解析结果使用与数据库字段对应的 Hash。H3C 覆盖 AP、Radio、BSS、Client、AP 组、服务模板、802.1X，以及快照中的 MAC 认证和阻断客户端。Huawei 保留已验证的 AP、Client 表格格式，其他维度明确标记不支持。
- 配置事实和运行测量分开保存；配置中的最大功率不能当作当前发射功率。PSK、密码、原始配置及认证 URL 不进入快照或错误信息。
- AP LLDP 需要显式请求和注入 AP 会话工厂；内置适配器使用控制器中转和显式 AP 凭据。确认 AP 提示符后才读取，退出时确认原控制器提示符；若已返回控制器则不再发送 quit，遇到其他提示符则隔离连接。进入 AP、读取、退出及失败关闭均位于同一次控制器租约中，不建立独立 AP 连接；控制器忙碌时不夺取或关闭其他操作。取消继续传播，原始取消不会被清理阶段的第二次取消覆盖；退出和关闭失败分别保留为 cleanup_error 和 close_error。不自动开启 AP console。
- 外部 I/O 完成后锁控制器，复核控制器、原快照和资产版本，原子提交资产、配置明细、快照及 revision。采集事实与库存投影分开：缺父 AP/Radio 的合法记录保留在原始快照，库存投影记录 `parent_unavailable`，其他独立实体继续入库；存在依赖未满足的维度禁止清理缺失项。身份歧义、模型校验和数据库异常仍使整个事务回滚。AP 档案只标记缺失，人工管理字段保留。
- 管理 API、Netdisco 同步和既有 Rake 任务名不变。`Motor::Wireless::CliSync` 委托新实现。虚拟控制器及信道继续查询现有表。


H3C 具体策略位于 [`lib/wireless/h3c`](../lib/wireless/h3c/profile.rb)，10 条命令分别实现为 `parsers/display_*.rb`。`H3c::Parser` 管理平台输入边界，`H3c::RecordParser` 读取标签字段并划分记录；`H3c::AuthenticationFields` 复用认证字段和身份定义，各命令类保留自己的格式规则。`Profile` 统一声明命令、解析类及型号覆盖，`ParserRegistry` 识别 `h3c` / `h3c_wireless`。公共抽象及型号扩展见 [`../ctx_parser`](https://github.com/gatework/ctx_parser)。

`H3c::Document` 组织配置来源行、横幅与完整性诊断。配置与运行命令共用 `H3c::CommandOutput` 的编码和命令错误边界；配置保留原始换行，运行表格规范化为 LF。共享 `Wireless::Terminal` 在字段清理前检测分页和编辑控制：运行回显受损时拒绝生成事实，配置文档则逐行标记无效来源，保留其他配置及其捕获；横幅内容仍作为普通文本隔离。`DisplayCurrentConfiguration` 解释语法，`H3c::ConfigurationBuilder` 维护实体身份、AP 组/型号/Radio 的合法归属及模板认证类型。嵌套记录与来源路径由 `ConfigurationBuilder::Scope` 一起构建，逐行状态和捕获复用 `CtxParser::Configuration`，不在厂商类内重复实现。

顶层声明只在配置根节点识别。AP、型号或 Radio 内出现 `sysname`、`wlan ap-group`、`wlan service-template` 等顶层声明时，保留未知诊断，不提升为全局对象；配置及共享的组/模板维度均为部分结果，入库保留已有完整明细。重复实体保留首条并标记为部分结果。

AP/Radio 共用 `display wlan ap all verbose` 的一次解析，分别保存完整性；配置/AP组/模板同样共享一次配置解析。LLDP 命令类只接受回显，外部 AP 名称由 `NeighborParser` 注入。采集器把控制器型号或 AP 自身型号传入对应策略。

## 验证范围

离线 fixture 验证字段、语法覆盖、重复身份、截断、显式空清单及秘密过滤；替身会话验证登录策略、命令顺序和断线；真实 PostgreSQL 验证关联、部分更新、重复投递、删除、并发冲突及回滚。这些验证与真实设备联调分别报告。

## 调用与兼容

```ruby
result = ::Wireless::Sync.new.call(controller: Motor::Device.find(device_id))
result.counts
result.observation.complete? # 原始采集完整性
result.complete?             # 采集与库存投影都完成
result.projection.dimensions # 各库存维度的 applied/deferred 和安全诊断

# 显式采集 AP 邻居；使用已保存的加密 AP 凭据。
::Wireless::Sync.new.call(controller: device, dimensions: [:lldp])

# 筛选 AP 时该维度保持 partial，避免删除未采集 AP 的邻居。
::Wireless::Sync.new.call(controller: device, dimensions: [:lldp], ap_names: ["AP-LAB-01"],
  ap_credentials: { password: ap_password })

# 离线解析不建立会话、不写数据库。
::Wireless::Config.new.parse(configuration_text, complete: true)
::Wireless::RuntimeParser.new.parse(:clients, client_output, platform: "h3c", complete: true)
```

固定 AP 密码保存在现有 `Motor::EncryptedConfig` 的内部键 `network.wireless_ap`，值为 `password` 和可选 `username`。现有 Active Record Encryption 加密该值，配置中心通用接口不公开此内部键；不新增字段或第二套密钥存储。凭据仅在显式 LLDP 请求时读取，调用参数优先，不进入观察记录、默认检查输出和日志。

保留 `Motor::Wireless::CliSync` 和 `motor:netstack:wireless[device_id]` 运维入口。内部 Ruby 调用从 `Motor::Netstack::Wireless::Sync` 改为 `::Wireless::Sync`；返回值包含 `observation/counts/revision/projection`，不再返回 Netstack 的 `reconciliation/assessment`。Rake 同时报告采集和投影状态；依赖未满足时保存可用事实后以非零状态退出。其他业务的 Netstack 依赖保留。

新观察按维度名称保存 `name/status/records/issues/evidence/started_at/completed_at`。历史快照无需回填；首次新采集按维度更新，失败时原 `last_complete` 仍保留旧 JSON 形状。未请求维度保持原样，不能把旧完整数据当作本次成功。

库存投影结果保存在现有 `controller.motor_settings["wireless_cli"]["projection"]`，无需新表。每维度记录采样时间、观察/应用/延后数量、未解析父关联总数和最多 20 条身份诊断；原始采集维度仍保留自身的完整性。后续成功投影会替换旧的阻塞诊断，未请求维度不变。

控制器、AP 和 Radio API 增加 `coverage`，分别显示最新采集状态、采样时间、最后完整时间和投影状态。最新失败、部分、未请求或过期证据不能支持 `healthy`；独立已知故障仍报告，并同时展示覆盖不足。控制器逐实体计算新鲜度，一个新 AP 不会使旧 AP 恢复为在线。没有 CLI 快照的既有 Netdisco 库存保持旧健康视图，并显式标记 `source=inventory/state=untracked`，不宣称 CLI 完整覆盖。旧快照没有投影元数据时兼容原子入库成功的历史行为；已有投影条目与最新采集时间不匹配则报告 `projection_time_unconfirmed`。

AP 列表按当前页批量聚合 Radio/BSS/Client 数量、SSID 客户分布及 Radio 利用率，查询数不随页内 AP 数量线性增加。Radio 列表和 AP 详情共用控制器证据，不按 Radio 重复读取快照。其他清单与同步全库存的锁定策略保持不变。

当前限制：筛选 AP 的 LLDP 结果仍以整体 `partial` 保存，不能表达“选定 AP 范围内完整”，因此不会删除该范围的旧邻居；这避免影响未采集 AP，但定向刷新后的陈旧链接仍需后续范围模型解决。CLI 与 Netdisco 尚未建立跨来源优先级，`coverage` 明确表示 CLI 证据，不能将两个来源的时间混为一份实时快照。

Rails 自动加载本目录，开发容器更新后需重启 Rails/Sidekiq 以加载新路径。现有 API、权限、后台 i18n 和表结构不变。

```sh
bundle exec rspec spec/vendor/wireless spec/services/motor/wireless spec/requests/wireless_spec.rb \
  spec/lib/motor/netstack/collection_spec.rb spec/lib/motor/netstack/concurrency_spec.rb
bundle exec rails zeitwerk:check
bundle exec rubocop
```

## IP 冲突与 AP 型号能力

默认 H3C 采集包含 `display wlan statistics client-ip-conflict`（`client_ip_conflicts`）和
`display wlan ap-model all`（`ap_models`）。也可通过 `dimensions: %i[client_ip_conflicts ap_models]` 单独采集。
解析器按设备接受的完整命令名注册；`dis` 是设备 CLI 的缩写。

两类记录通过 `Wireless::Sync` 原子保存至现有 `Motor::WirelessSnapshot.observations` JSONB，
路径分别是 `client_ip_conflicts.latest.records` 和 `ap_models.latest.records`，无需 migration。
失败或部分结果保留 `last_complete`；未请求的维度不变。型号能力不创建 AP 资产或运行 Radio。
冲突记录包含 IPv4/IPv6、新旧 MAC/AP ID 和 `occurred_at`（设备原始 `MM-DD HH:MM:SS`，不推断年份或时区）。
型号记录包含厂商、许可、Radio 能力和硬件版本对应的软件/镜像信息。
完整传输的冲突表头且无数据行表示空表；空回显、未知行、非法字段和重复身份不会作为完整结果。

格式依据 H3C 官方 [IP snooping 命令参考](https://www.h3c.com/en/d_202603/2774466_294551_0.htm)
及 [AP management 命令参考](https://www.h3c.com/en/d_202509/2658869_294551_0.htm)。
fixtures 为依据文档构造的离线数据，不是现场设备采集。
