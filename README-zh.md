# wireless-rb

[English](README.md) | [源码](https://github.com/gatework/wireless-rb) | [变更记录](CHANGELOG.md)

以纯 Ruby 解析无线控制器配置和运行观察。厂商命令解析器建模 AP、Radio、客户端和服务配置，采集事实与库存持久化分开。

## 命令行入口

新增 `wireless collect` / `wireless parse`，配置、初始化、筛选、并发、进度、私有逐设备报告及退出码与 VXLAN CLI 保持一致。

```sh
ruby bin/wireless.rb --help-all
ruby bin/wireless.rb --plan
ruby bin/wireless.rb
ruby bin/wireless collect --help-all
ruby bin/wireless collect --init --non-interactive
ruby bin/wireless collect --plan
ruby bin/wireless parse --dimension access_points --file aps.txt --complete
```

源码直接运行 `ruby bin/wireless.rb`，与 `wireless collect` 共用逐层配置发现：系统、用户配置目录、入口脚本目录、启动目录，显式配置最后叠加。值优先级为 CLI > 进程环境 > YAML > .env > 默认。初始化写用户配置目录或显式路径，报告默认写启动目录 `wireless-reports/`。支持 H3C 与 Huawei；AP LLDP 须显式启用并使用独立 AP 凭据。宿主配置及采集使用含 `Config` 的可选 `net-connector >= 0.18.0`，环境文件解析由该依赖提供；纯解析仍独立。详见[命令行使用说明](bin/README.md)。


## 能力

- H3C BSS/客户端的 `VLAN ID` 保存为 `vlan`，`Service VLAN ID` 保存为 `service_vlan`；省电开关为 `power_save`，省电模式为 `power_save_mode`。已修正此前合并别名的行为，调用方应按字段语义读取。多行 `cipher-suite` / `security-ie` 累积启用成员，单值字段的冲突仍保持不完整。
- H3C 配置、AP、Radio、BSS、客户端、AP 组、服务模板及认证观察。
- Huawei 已支持的 AP/客户端运行格式；未支持维度明确标识。
- 同一命令共享解析，每个结果视图独立保留完整性。
- 通过内置 net-connector AP 会话适配器可选采集 AP 邻居。

## 安装

要求 **Ruby 4.0.6 或更新版本**。在应用的 `Gemfile` 中添加：

```ruby
gem "wireless-rb", require: "wireless"
```

然后执行 `bundle install`；也可直接执行 `gem install wireless-rb`。Ruby 加载入口为 `wireless`，公开命名空间为 `Wireless`；gem 包名与 Ruby 命名空间分别维护。

模块使用 [`ctx_parser`](https://github.com/gatework/ctx_parser) 和 [`ctx_driver`](https://github.com/gatework/ctx_driver)，gemspec 不限定依赖版本。离线解析及注入控制器会话的采集均不安装或加载 `net-connector`。应用应提交自己的 `Gemfile.lock`，保持部署可复现；使用本库不需要启动 Rails 或配置兄弟模块的本地路径。

发布产物和校验值见 [GitHub Releases](https://github.com/gatework/wireless-rb/releases)，已发布版本以 [RubyGems](https://rubygems.org/gems/wireless-rb) 为准。

## 离线示例

在开发检出目录安装依赖后执行：

```sh
bundle exec ruby examples/offline.rb
```

示例使用合成数据，不访问网络。完整代码见 [examples/offline.rb](examples/offline.rb)：

```ruby
require "wireless"

# 使用合成 H3C AP 回显；配置上限不代表实时功率测量。
output = <<~CLI
  Total number of APs : 1
  AP name : AP-EXAMPLE
  AP ID : 7
  MAC address : 0200-0000-0007
  IP address : 192.0.2.7
  State : Run
  Radio 1 :
   Admin state : Up
   Radio type : 802.11ax 6GHz
   Channel : 1(auto)
   Channel bandwidth : 80MHz
   Operating bandwidth : 40MHz
   Channel usage(%) : 0
   Noise floor : -90 dBm
   Max power : 20
CLI
observations = Wireless::RuntimeParser.new.parse_many(
  %i[access_points radios], output, platform: "h3c", complete: true
)
observations.each do |name, observation|
  puts "#{name}: #{observation.status}, records=#{observation.records.size}"
end
# 两个视图共用一次解析，各自保留完整性状态。
```

## 公开契约与限制

非法平台、型号、维度参数及非布尔 `complete` 抛出 `ArgumentError`；设备正文格式错误返回失败观测。

`NeighborParser#parse` 对非法 AP 名称及非文本输入同样抛出 `ArgumentError`；平台不支持的维度返回 `unsupported`。`Observation` 时间戳只接受 `Time` 或 `nil`，通过 `with` 替换时同样校验。

`Config.new.parse(text, complete: false)` 解析控制器配置。`RuntimeParser.new(model: nil).parse(name, text, platform: "h3c", complete: false)` 解析单个运行维度；`parse_many` 为同一命令的多个维度共享解析。`NeighborParser` 为邻居观察补充 AP 上下文。

输入完整性由调用方确认。未知语法、身份重复、数量矛盾和截断输出保持部分或失败。配置中的最大发射功率不能当作当前测量功率；PSK、密码、认证 URL 不可进入快照。

省略 `dimensions` 时按平台 Profile 选择控制器维度；AP LLDP 仍须显式请求。显式选择平台未支持的维度时保留 `unsupported`。`Collector#collect(connector:, target:, platform:, model: nil, dimensions: nil, ap_credentials: nil, ap_names: [])` 使用宿主注入的 connector，普通采集仅要求会话提供 `connected?` 和 `send_commands`。AP LLDP 通过 `Collector.new(ap_session_factory: factory)` 显式注入；factory 接收 `controller:` 和按需解析的 `ap_credentials` 关键字，返回提供 `read(access_point:)` 的对象。需要查询 AP 但未注入工厂时，仅 LLDP 返回 `ap_session_required`，不读取 AP 凭据，也不影响控制器清单。

采集器在打开连接前固定平台和型号 Profile，共享查询只解析一次。每次采集只接受一次会话回调；宿主重复回调时不重放控制器或 AP 查询，保留首次观测，并将采集故障标记为 `session_reentered`。

内置 AP 登录适配器可选使用。宿主须自行声明 `gem "net-connector", ">= 0.13.0", require: false`，使用 `ctx_driver >= 0.2.2`，并显式加载和注入：

```ruby
require "wireless"
require "wireless/ap_session"

collector = Wireless::Collector.new(
  ap_session_factory: ->(controller:, **credentials) { Wireless::ApSession.new(controller: controller, **credentials) }
)
```

适配器要求通过 `ap_credentials` 显式提供 AP 密码，可选用户名；自定义适配器可自行管理凭据。`read` 返回包含 `result: CtxDriver::Capture`、可选的 Symbol 错误代码 `error:` / `cleanup_error:` / `close_error:`（或 `nil`），以及可选布尔值 `skipped:` 的 Hash。格式错误的回执返回 `invalid_command_result`；非 Symbol 错误代码归一化为该代码，同时保留已取得的有效邻居事实。控制器和 AP 凭据、会话生命周期归宿主或适配器管理，解析器不推断 AP console 或凭据。

AP 接入复用已连接的控制器及其操作租约，不另建 AP 传输连接。登录、只读查询、确认返回及失败关闭都在同一租约中；控制器忙碌时不关闭或破坏其他操作。只有仍处于已确认的 AP 提示符时才发送 `quit`，取消继续传播，退出与关闭故障独立保留。空 AP 清单不解析凭据，也不创建适配器。

详细厂商语义、历史验证记录和 Motor 专用集成说明保留在[架构参考](docs/architecture-zh.md)。其中宿主集成代码需要 Motor，不属于独立 gem API。适配层位于 [Motor 仓库](https://github.com/gatework/motor/tree/main/backend/lib) 的 `backend/lib/baseline`、`backend/lib/vxlan` 和 `backend/lib/wireless`。

生命周期 connector 是宿主适配器，提供 `open { |session| }`，VXLAN 和 Wireless 还要求 `platform`；原生 `Net::Connector::Base` 实例并不提供这一宿主生命周期协议。已连接的原生会话可传入 `CtxDriver::Reader` 或 `CtxChecker::Collector#collect_session`，不会隐式连接或重试。

运行字段或同一配置声明块内的单值设置发生冲突时，移除歧义事实，相关来源保持不完整；同块后续声明不能恢复该值。独立的顺序配置块保留各自的来源快照。未知父级下的无线声明不能被当作空配置。观测名称必须为 Symbol；观测、快照和投影的显示字符串（包括 `PP.pp`）只含元数据。空覆盖范围保持未知，新鲜度时间窗必须为有限非负数。

Radio 信道、带宽、功率和开关，以及服务模板的 PSK、AKM、加密套件和安全 IE 设置必须位于对应配置视图。位置错误的命令保留为不支持的来源证据，不能在外层对象中生成事实；视图依据见 [H3C 命令参考](https://www.h3c.com/en/d_202004/1286221_294551_0.htm)。

## 领域术语

H3C `Online time` 保存为 `online_seconds`，AP 的 `System uptime` 保存为 `uptime_seconds`，两者对应[不同的设备字段](https://www.h3c.com/cn/d_202606/2850182_30005_0.htm)。显式认证模式优先于域引用；组合和回退模式保留顺序，不归并为单一认证方式，依据 [H3C 认证命令参考](https://www.h3c.com/en/d_202106/1418918_294551_0.htm)。LLDP 的不透明机箱标识保留大小写，明确为 MAC 类型时才归一化。

H3C 命令解析器使用 `H3c::Parser` 校验命令回显，使用 `H3c::RecordParser` 读取带字段标签的记录。`H3c::AuthenticationFields` 复用认证字段定义，`H3c::Document` 保留配置来源行；Huawei 使用 `Huawei::Profile` 和 `Huawei::Parsers` 命令解析器，遵循相同参数契约。

AP、射频、BSS 和关联客户端具有不同身份。测量转换方法明确返回单位：`Fields.duration_seconds`、`Fields.rates_mbps`、`Fields.channel_width_mhz`。`Fields.frequency_band` 需要无歧义的频段标签或频段专属 PHY 证据；仅有信道号或通用 `802.11ax` 标签时保持未知。参见 [Cisco 的 6 GHz 信道示例](https://www.cisco.com/c/en/us/support/docs/wireless/catalyst-9166-series-access-points/220526-configure-and-verify-wi-fi-6e-band-opera.html)。

Radio 能力详情按子节保存：`details[:vht_mcs]`、`[:ht_mcs]`、`[:he_mcs]` 和 `[:operational_rates]` 分别拥有 `supported`、`mandatory` 等同名标签。AP 总数只证明 AP 覆盖；缺少 Radio 回显的 AP 会使 Radio 视图保持不完整，AP 视图仍可完整。AP LLDP 适配器须返回对应命令的回执，AP 身份和尝试状态由采集器确定。

`authentication_type` 是已识别认证配置的摘要。PSK 与 Portal 等可叠加机制分别保留在 `configuration[:akm_modes]` 和 `configuration[:portal]`；核查全部启用机制的基线应读取这些字段。

## 开发与测试

共享类按实际职责命名，平台信息放在命名空间中。直接对应设备命令的解析器保留文件名和类名。

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` 执行 RSpec、RuboCop 及离线示例。测试放在 `spec/`，沿用项目 RSpec 约定；样例采用合成或脱敏证据。新增解析格式时补充成功、不完整、不支持及非法输入回归。离线测试不代表所有设备版本均通过实机验证。

使用声明的最低 Ruby 版本检查兼容性。方法用途统一使用简明中文注释；复杂实现还需说明业务规则、实现思路及关键分支。保持公开返回值与错误契约。真实回显和凭据不可进入示例、fixture、日志或发布包。

运行 `bundle exec ruby -Ilib benchmark/tables.rb`，比较 500、2,000、5,000 条合成模板、绑定及 LLDP 续行，以及 100,000 行终端回显的完整扫描和首行报错开销。每组核对解析结果，报告三次采样中最快的耗时和对象分配数；这些结果不代表设备或网络性能。

## 发布

本目录可独立维护为 [wireless-rb](https://github.com/gatework/wireless-rb) 仓库。更新 `VERSION` 和 `CHANGELOG.md`，运行上述验证与构建命令，检查包内文件，再创建 `vVERSION` 标签。

CI 在 Linux、macOS 上执行测试、lint、示例、构建和隔离安装。`main` 的 CI 通过后推送 `vVERSION` 标签，工作流将已验证的 Linux 产物发布到 RubyGems 和 GitHub Release，附带 `SHA256SUMS` 并回读下载字节。GitHub `release` environment 可配置 `RUBYGEMS_API_KEY` secret；未配置时使用 RubyGems Trusted Publishing，绑定本仓库、`release.yml` 和 `release` environment。失败时重跑失败的发布 job，以复用原 CI 产物；同版本已存在时必须校验字节一致。详见[发布说明](docs/release.md)。

先发布依赖模块。标签、构建成功或工作流文件都不等于已经发布，需单独确认 RubyGems 的实际结果。版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 修复建议

`wireless collect` 默认输出逐设备诊断，使用 `--scripts` 可选导出配置建议；`wireless review --batch DIR` 可离线补生成既有报告的候选配置、条件回退和只读验收命令。导出不会执行变更；独立 `apply --plan FILE` 必须在真实终端明确确认，配置漂移或失败即停止。详见[修复建议说明](docs/remediation.md)。
