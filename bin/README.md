# Wireless 命令行

源码直接采集使用 `bin/wireless.rb`，无需 `collect` 子命令。它与正式 CLI 共用配置发现，不修改进程环境或启动目录。Ruby 要求 4.0.6 或更新版本。

```sh
bundle install
ruby bin/wireless.rb --help-all
ruby bin/wireless.rb --plan
ruby bin/wireless.rb
```

也可在 `bin/` 运行 `ruby wireless.rb`；从其他目录指定脚本绝对路径也可。入口直接加载相邻 `lib/`，沿用已选择的 RubyGems/Bundler，不搜索相邻源码。脚本默认读取 Netdisco 清单并采集已选控制器，不扫描地址。

首次没有配置时执行 `ruby bin/wireless.rb --init --non-interactive`，再填写用户配置目录中的 `.env` 与 `wireless.yml`。已有文件保留。配置加载及联网使用含 `Config` 的可选 `net-connector >= 0.14.2`，环境文件解析由该依赖提供；本仓库 Gemfile 已声明。

安装 gem 后仍使用 `wireless collect` / `wireless parse`，或源码统一入口 `ruby bin/wireless collect`。两者调用同一采集与配置实现，报告默认位于启动目录 `wireless-reports/`。

## Netdisco、环境默认与现场配置

初始化模板在一份 YAML 中声明清单来源和无线采集参数，无需再指向另一仓库：

```yaml
parallel: 4
directory: wireless-reports
dimensions: null
ssh:
  host_key_policy: accept_new
netdisco:
  source: http
  cache_enabled: true
  cache_mode: prefer
  cache_ttl: 259200
  cache_directory: .cache/wireless/inventory
  inventory_timeout: 300
  allow_insecure_http: false
inventory:
  include_vendors: [h3c_wireless]
  include_hosts: []
  exclude_hosts: []
  include_names: []
  exclude_names: []
  name_match: contains
devices: []
```

`netdisco` / `inventory` 字段复用 net-connector 的 schema、厂商识别、查询和缓存策略。HTTP 使用 `ND_URL`、`ND_USERNAME` / `ND_PASSWORD` 或 `ND_API_KEY`。PostgreSQL 使用 `source: postgres`、YAML 的 query 等参数和环境中的 `ND_DB_HOST` / `ND_DB_NAME` / `ND_DB_USER` / `ND_DB_PASS`。默认只选择识别为 `h3c_wireless` 的设备；Huawei 使用 `include_vendors: [huawei]` 并用名称/IP 限定控制器范围。支持模型规则 `device_rules`，不得把所有通用交换机映射成控制器。

`NC_PARALLEL`、`NC_HOST_KEY_POLICY`、`NC_KNOWN_HOSTS`、`ND_CACHE_TTL` 等规范环境变量采用 CLI > 进程环境 > YAML > .env > 默认的优先级。设备凭据沿用 `NC_DEVICE_USERNAME` / `NC_DEVICE_PASSWORD` 与按厂商覆盖；AP 凭据使用独立的 `WIRELESS_AP_*`。环境模板位于 `lib/wireless/cli/templates/env.example`，不复制备份或 TFTP 参数。

```sh
ruby bin/wireless.rb --plan --name wlc
ruby bin/wireless.rb --cache-only --inventory-only
ruby bin/wireless.rb --refresh-inventory --plan
ruby bin/wireless.rb --dimensions access_points,clients --host 192.0.2.10 -p 4
ruby bin/wireless.rb --show-config
```

`--cache-mode prefer|only|refresh`、`--cache-only`、`--refresh-inventory` 与 `--source http|postgres` 只适用于 Netdisco 清单。缓存 only 不读取远端，强刷与 only 互斥。`--show-config` 校验公开字段后输出，不获取清单。

YAML 与 `.env` 的已声明路径字段相对各自来源文件目录解析，CLI 与进程环境路径相对启动目录。低层路径不会被高层配置文件重新定位。

下文 `wireless collect` 的采集参数同样可直接传给 `ruby bin/wireless.rb`。

## 初始化与配置

```sh
ruby bin/wireless collect --init --non-interactive
```

在用户配置目录创建缺失的 `wireless.yml` 与 `.env`，权限 0600；用户配置目录为 `$XDG_CONFIG_HOME/net-connector`，未设置时为实际运行用户 `~/.config/net-connector`。显式 `--config` / `--env-file` 选择初始化位置。已有文件保留，然后立即退出，不读取清单或连接设备。模板统一位于 `lib/wireless/cli/templates/`，现场配置及报告不进入版本库或安装包。

缺失配置时，真实交互终端可选择创建；自动化直接提示 `--init`，不消费 stdin。`--interactive` 要求真实终端，`--non-interactive` 禁用问答。帮助与范例不读取配置、清单或凭据，不创建文件。

静态清单模式须删除 netdisco、inventory 两段后填写明确设备（与 Netdisco 来源互斥）：

```yaml
platform: h3c
parallel: 4
directory: wireless-reports
dimensions: null
ap_names: []
ssh:
  host_key_policy: strict
  command_timeout: 60
  login_timeout: 15
devices:
  - host: 192.0.2.10
    name: WLC-01
    platform: h3c
    model: WX-LAB
  - host: 192.0.2.11
    name: WLC-02
    platform: huawei
```

将文档地址替换为真实目标。设备仅接受 `host`、`name`、`model`、`platform`；地址须为单个 IP，规范化后不得重复。平台支持 `h3c`（连接器使用 `h3c_wireless`）、`h3c_wireless`、`huawei`。设备未声明平台时使用全局 platform，默认 H3C。设备参数和 YAML 不接受密码、任意命令或未知字段。

`dimensions: null` 或省略 dimensions 时，按每台设备的平台采集全部已支持的控制器维度，**不包含 AP LLDP**。H3C 支持 AP、radio、BSS、client、配置、AP 组、服务模板、802.1X、MAC 认证、阻断客户端、IP 冲突及 AP 型号；Huawei 当前支持 `access_points`、`clients`。可显式指定非空维度数组；不支持的维度保留 `unsupported`，不会以空结果冒充完整证据。AP/radio 等共享命令只查询一次，控制器之间并发，单控制器命令顺序执行。

公开参数优先级 **CLI > 进程环境 > YAML > .env > 默认**。环境变量包括 `WIRELESS_CONFIG`、`WIRELESS_PLATFORM`、`WIRELESS_PARALLEL`（缺失时使用 `NC_PARALLEL`）、`WIRELESS_DIRECTORY`。进程环境优先于 `.env` 且不被环境文件修改。每个入口依次读取 `/etc/net-connector`、`/usr/local/etc/net-connector`、用户配置目录、脚本目录、启动目录；重复目录只读取一次，不向父目录递归。每层先读取 `net-connector.yml` 的 `common` 与 `wireless`，再读取 `wireless.yml`；同目录 `.env` 逐层覆盖。`common` 仅承载 `netdisco` / `inventory` / `ssh`，`wireless` 内使用完整原生 YAML。显式 `--config` 或 `WIRELESS_CONFIG` 最后叠加，CLI 路径优先；`--env-file` 也最后叠加。自动候选缺失可忽略，显式文件缺失或格式错误会停止；`--init` 可创建新文件。YAML 递归合并映射，数组、标量和 nil 整体替换；单个文件禁止重复键和多个文档。YAML 及 `.env` 的路径按来源目录解析，CLI 和原进程环境路径按启动目录解析。`--show-config` 附公开 `sources` 文件顺序及字段来源，不显示环境文件内容或秘密。公共动态 Netdisco 不覆盖专用配置中明确的静态 devices；工具同时声明静态与动态来源仍拒绝。

凭据示例：

```dotenv
NC_DEVICE_USERNAME=operator
NC_DEVICE_PASSWORD='replace-me'
# NC_ENABLE_PASSWORD='replace-me'
# 平台覆盖：NC_H3C_WIRELESS_USERNAME / NC_H3C_WIRELESS_PASSWORD
#           NC_HUAWEI_USERNAME / NC_HUAWEI_PASSWORD
```

用户名必须明确，密码可省略以使用 SSH key/agent；命令不会交互索取密码。密码含 `#`、`$` 时使用单引号。预览及公开配置不要求设备凭据。核心默认 strict 主机密钥校验；初始化模板与 net-connector/examples 一致使用 accept_new；通过 ssh.known_hosts 提供密钥文件，或显式选用 accept_new，变更密钥仍被拒绝。可设置 ssh.port，不能在 YAML 中加入登录凭据。

## 筛选、预览与采集

```sh
ruby bin/wireless collect --plan --json --no-progress
ruby bin/wireless collect --show-config
ruby bin/wireless collect --hosts 192.0.2.0/24 --name wlc --exclude-name spare --plan
ruby bin/wireless collect --host 192.0.2.10 --dimensions access_points,radios,clients -p 4
ruby bin/wireless collect --verbose
ruby bin/wireless collect --json --quiet
```

`--plan` 与 `--inventory-only` 等价，不连接设备或创建报告。IP/CIDR 只匹配已有清单，不展开或扫描网段。同类 CLI 条件取并集并覆盖同类 YAML 条件；地址与名称条件取交集，排除优先；名称按忽略大小写的子串匹配。`--host` 是清单筛选，不能代替 devices。并发继承公共 `NC_PARALLEL`，未配置时为 4，范围 1～500，线程数及文件描述符在执行前检查。

可选复用 net-connector 的 Netdisco YAML：

```yaml
netdisco_config: /path/to/netdisco.yml
devices: []
```

与非空静态 devices 互斥，只选择 ready 的 `h3c_wireless` / `huawei` 设备并保留平台身份。不要将通用 `h3c` 交换机当作无线控制器。只校验并传递外部文件的 `netdisco` / `inventory` 分区，以及对应公共环境字段；清单字段或未知顶层名称有误仍会停止，其他已知分区的备份、拓扑、SSH、TFTP 策略不参与清单预检。Netdisco 的筛选和 `ND_*` 凭据由连接器处理；无线查询、SSH 参数与报告仍由本入口负责。

## AP LLDP

LLDP 只在显式请求时采集，目前适用于 H3C。入口复用 `Wireless::ApSession`，通过控制器嵌套接入 AP，不建立独立 AP SSH 会话。

```dotenv
WIRELESS_AP_PASSWORD='replace-me'
# WIRELESS_AP_USERNAME=operator
```

```sh
ruby bin/wireless collect --dimensions access_points,lldp --ap-name AP-01,AP-02
```

不继承控制器密码。`--ap-name` 是精确名称选择，省略时选择控制器清单中的全部 AP；依赖的 AP 清单会自动加入采集。AP 凭据仅在需要接入 AP 时读取；空 AP 清单无需凭据。AP 离线、缺少地址、凭据、登录失败、退出失败及选择范围不完整均保留明确诊断。每个控制器任务独占其新建会话，AP 适配器自行取得操作租约。

CLI 不启用 AP 远程控制台，也不修改设备配置；需要的接入前提由现场维护。AP 内仅执行固定分页设置、LLDP 查询及退出。无法确认返回控制器时关闭不确定会话，不自动重放。

## 离线解析

```sh
ruby bin/wireless parse --file controller.cfg --complete
ruby bin/wireless parse --dimension access_points --file aps.txt --complete --json
cat stations.txt | ruby bin/wireless parse --platform huawei --dimension clients --complete
ruby bin/wireless parse --dimension lldp --ap-name AP-01 --file lldp.txt --complete
```

默认读取 stdin。`--complete` 是调用方声明输入完整；省略时保留不完整证据，声明后也不会掩盖未知语法、计数冲突或分页残留。LLDP 解析要求 `--ap-name`，支持平台及维度见 `--help`。默认只显示状态、记录数与诊断代码；显式 `--json` 导出事实，可能包含配置敏感信息。

公共并发可在 `~/.config/net-connector/.env` 只设置一次，例如 `NC_PARALLEL=50`。YAML 的 `parallel` 是显式覆盖；要继续继承公共配置，应省略该字段。`--init` 不把公共并发或内置默认值固化进 YAML，后续公共值调整可直接生效；显式 `--parallel` 或本工具专用并发环境变量仍可初始化独立覆盖。

## 报告与退出码

采集与配置备份共用批次进度组件，进度、异常、结束摘要和报告路径统一写入 stderr。交互终端原地刷新登录/采集/排队、耗时及预计剩余；重定向时每 25 台及最后一台输出进度，异常设备即时提示。`--verbose` 增加逐台结果与安全命令事件；`--quiet` / `--no-progress` 关闭人类进度及摘要。`--json` 单独向 stdout 输出自动化摘要。终端输出故障不会重放设备查询，报告保留 `output_error` 并标记未完成。

报告保存到 `wireless-reports/<UTC 批次>/`，同秒不覆盖，包含 `summary.json`、`summary.txt` 与 `devices/<name>-<ip>.json/.txt`。设备 JSON 保存 Snapshot 的结构化事实、来源指纹和诊断；终端和批次摘要不包含回显或配置事实。这里保存的是结构化批次报告，核心库不写文件。

报告目录 0700、文件 0600；拒绝符号链接根目录及对其他用户开放的既有根目录，不自动修改既有权限。逐文件写临时文件并同步、原子替换及同步目录。写入失败明确报告；替换后同步失败标记持久性未确认，不重采。单设备完成即保存，中断或调度故障仍尝试保存已完成结果与 pending 清单。`completed` 是已登记结果数；`report_saved` 表示设备 JSON/TXT 均保存确认，false 时可能已有部分文件。

完整证据不代表无线网络健康。失败控制器不抹去其他设备事实，关闭失败保留已取得的维度，断链不自动重连或重放。

| 退出码 | 含义 |
| --- | --- |
| 0 | 全部所选证据完整，或帮助、初始化、有效预览 |
| 1 | 部分、失败或不支持的证据，或没有匹配设备 |
| 2 | 参数、配置、依赖、清单、调度或报告错误 |
| 130 | 用户中断，保留已保存结果 |

`bundle exec rake` 运行完整测试、lint、离线示例及命令帮助，不连接现场设备。传输集成测试使用本地 PTY，只证明本地协议集成，不替代现场验证。

## 修复建议

`wireless collect` 默认输出逐设备诊断，使用 `--scripts` 可选导出配置建议；`wireless review --batch DIR` 可离线补生成既有报告的候选配置、条件回退和只读验收命令。导出不会执行变更；独立 `apply --plan FILE` 必须在真实终端明确确认，配置漂移或失败即停止。详见[修复建议说明](../docs/remediation.md)。
