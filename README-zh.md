# wireless-rb

[English](README.md) | [源码](https://github.com/gatework/wireless-rb) | [变更记录](CHANGELOG.md)

以纯 Ruby 解析无线控制器配置和运行观察。厂商命令解析器建模 AP、Radio、客户端和服务配置，采集事实与库存持久化分开。

## 能力

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

模块运行依赖：[`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver), [`net-connector`](https://github.com/gatework/net-connector)。 gemspec 的运行依赖不添加版本约束；应用应提交自己的 `Gemfile.lock`，保持部署可复现。使用本库不需要启动 Rails 或配置兄弟模块的本地路径。

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

`Configuration.new.parse(text, complete: false)` 解析控制器配置。`RuntimeParser.new(model: nil).parse(name, text, platform: "h3c", complete: false)` 解析单个运行维度；`parse_many` 为同一命令的多个维度共享解析。`NeighborParser` 为邻居观察补充 AP 上下文。

输入完整性由调用方确认。未知语法、身份重复、数量矛盾和截断输出保持部分或失败。配置中的最大发射功率不能当作当前测量功率；PSK、密码、认证 URL 不可进入快照。

`Collector#collect(connector:, target:, platform:, model: nil, dimensions:, ap_connection: nil, ap_names: [])` 使用注入的 connector。内置 `ApSession` 通过显式运行依赖 `net-connector` 处理中转会话；请求 LLDP 时必须通过 `ap_connection` 显式提供 AP 凭据。宿主负责设备身份和连接设置，解析器不会推断 AP console 开启或 AP 凭据。Rails 库存投影、锁、加密、API 和 `Wireless::Sync` 属于宿主，不随本 gem 发布。

详细厂商语义、历史验证记录和 Motor 专用集成说明保留在[架构参考](docs/architecture-zh.md)。其中宿主集成代码需要 Motor，不属于独立 gem API。适配层位于 [Motor 仓库](https://github.com/gatework/motor/tree/main/backend/lib) 的 `backend/lib/baseline`、`backend/lib/vxlan` 和 `backend/lib/wireless`。

生命周期 connector 是宿主适配器，提供 `open { |session| }`，VXLAN 和 Wireless 还要求 `platform`；原生 `Net::Connector::Base` 实例并不提供这一宿主生命周期协议。已连接的原生会话可传入 `CtxDriver::Reader` 或 `CtxChecker::Collector#collect_session`，不会隐式连接或重试。

## 开发与测试

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` 执行 RSpec、RuboCop 及离线示例。测试放在 `spec/`，沿用项目 RSpec 约定；样例采用合成或脱敏证据。新增解析格式时补充成功、不完整、不支持及非法输入回归。离线测试不代表所有设备版本均通过实机验证。

使用声明的最低 Ruby 版本检查兼容性。方法用途统一使用简明中文注释；复杂实现还需说明业务规则、实现思路及关键分支。保持公开返回值与错误契约。真实回显和凭据不可进入示例、fixture、日志或发布包。

## 发布

本目录可独立维护为 [wireless-rb](https://github.com/gatework/wireless-rb) 仓库。更新 `VERSION` 和 `CHANGELOG.md`，运行上述验证与构建命令，检查包内文件，再创建 `vVERSION` 标签。

CI 在 Linux、macOS 上执行测试、lint、示例、构建和隔离安装。`main` 的 CI 通过后推送 `vVERSION` 标签，工作流将已验证的 Linux 产物发布到 RubyGems 和 GitHub Release，附带 `SHA256SUMS` 并回读下载字节。GitHub `release` environment 可配置 `RUBYGEMS_API_KEY` secret；未配置时使用 RubyGems Trusted Publishing，绑定本仓库、`release.yml` 和 `release` environment。失败时重跑失败的发布 job，以复用原 CI 产物；同版本已存在时必须校验字节一致。详见[发布说明](docs/release.md)。

先发布依赖模块。标签、构建成功或工作流文件都不等于已经发布，需单独确认 RubyGems 的实际结果。版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
