# Wireless 开发指南

本文件适用于本仓库。本地目录为 wireless，gem/远端项目名为 wireless-rb；修改前核对 Git 状态，保留所有已有工作。

## 职责与结构

- `H3c/Huawei::Profile` 声明命令与视图；各厂商 `parsers/` 保留 CLI 命令映射的名称、类和目录。
- `H3c::Document` 保留来源与作用域；`ConfigurationBuilder` 组织实体、型号、Radio 和模板绑定；`RecordParser` 处理运行字段、身份和诊断。
- `Fields`、`Terminal` 管理严格值转换与终端残留校验；`Config/RuntimeParser` 选择解析策略，不负责设备连接。
- `Collector` 编排控制器查询与 AP 依赖；`ApCollection` 负责 AP 选择、延迟凭据、邻居回执与覆盖汇总；`ApSession` 处理 AP 转接，`ctx_driver` 保存回执证据，net-connector/expect-pty 管理底层对话与资源。
- `Observation/Snapshot` 保存不可变事实；`Projection/Coverage` 区分资产应用与证据新鲜度；`Recommendations/ChangePlan` 分离建议和受支持的模板安全增量。
- CLI parse/collect/review/apply 负责配置、私有报告、单项确认与执行日志，不在解析器中执行设备动作。

## 核心契约

- 区分 complete/partial/failed/unsupported/not_requested；显式空清单仍需完整性证据。未知身份、计数不匹配、重复记录和终端损坏不能成为健康空表。
- AP、组、型号、Radio/频段和以太网作用域不能混合；未支持的父块不能把子声明提升到外层。模板认证及配置秘密不进入普通事实。
- 共享命令只执行、解析一次，再投影各维度。连接器恰好提供一次会话；重复回调不重放，缺少回调不能报告完整。
- LLDP 选择基于 AP 清单；无匹配时不访问凭据、不登录 AP。单 AP 失败保留其他 AP 事实，明确选择范围、尝试状态、摘要和错误阶段。
- 采集结果与资产应用相互独立；部分列表不能用于删除未出现资产，旧资产或失败查询不能刷新覆盖时间。
- 外部回调前固定请求和身份，结果深度快照不能冻结调用方容器。不依赖 Ruby 全局分隔符，字节/编码/终端处理保持严格边界。
- 可执行计划必须来自唯一完整配置；外部传入的建议不替代此证据。每台设备同次报告的计划共享配置指纹，下次报告重新计算。
- apply 回读并校验指纹、确认单项后发送，最终回读配置；不自动重放、回退或据 CLI 成功断言业务验收完成。
- 报告目录 0700、文件 0600；先发布未完成检查点，目录同步失败保留未确认状态。错误和诊断不得泄露原始回显、口令及回调异常消息。

## 开发与验证

- 使用项目 `.ruby-version`、gemspec、锁文件与 RuboCop；沿用中文代码注释和现有 RSpec 约定。新抽象应保护业务不变量，不机械拆分或统一厂商命名。
- 根目录 `bundle exec rake` 执行完整测试、lint、离线示例和 CLI 帮助；macOS 必要时用 `zsh -ic 'bundle exec rake'`。
- 缺陷先用回归复现，优先复用既有测试。覆盖字段失败隔离、重复身份、未知作用域、取消、资源所有权和已完成副作用。
- `benchmark/tables.rb` 测表格/配置解析；`benchmark/review.rb` 测建议到计划序列化，明确排除文件 IO。用 `bundle exec ruby -Ilib benchmark/review.rb`；基线用独立 `-I/path/to/lib`，核对实际源码位置，比较语义、规模、耗时与对象分配。
- 构建后运行 `ruby script/verify_package.rb pkg/wireless-rb-<version>.gem`；另支持连接器/expect 候选包。源码联调、隔离包、实机结果分别报告。
- 修改示例与 CLI 后运行实际 checkout 的普通入口；配置遵循共享服务的来源与优先级，不新增平行解析逻辑。
- 更新 CHANGELOG 与相关文档。当前优化授权不包含提交、推送、发布或调整可见性。

## 公共业务流程

采集会话约束、共享查询与事实外壳由 `ctx_runner` 提供；VXLAN/Wireless 的批量交付、报告检查点和变更执行也由 Runner 统一维护。领域规则、厂商命令、健康评估及操作租约留在当前模块，不复制公共状态机。

源码联调使用 `CTX_RUNNER_PATH=../ctx_runner bundle exec rake`；普通安装验证不设置该变量。首次发布依赖顺序为 ctx_parser → ctx_driver → ctx_runner → 消费模块。未发布 Runner 时先构建安装候选包，隔离包验证显式传入候选，不能依靠相邻源码路径。

## 公共 CLI

配置读取、私有初始化、终端边界和公共参数使用 ctx_cli；不要复制对应实现。领域策略与设备能力留在当前仓库，ctx_runner 继续决定业务完成状态。`CTX_CLI_PATH=../ctx_cli` 显式源码联调；普通入口与安装验证使用候选 gem，不能隐式探测相邻目录。
包验证的第五个位置参数为 ctx_cli 候选；前四个仍为当前包、net-connector、expect-pty、ctx_runner。首次发布前须构建安装依赖候选；未发布版本不得靠在线索引假定可用。
