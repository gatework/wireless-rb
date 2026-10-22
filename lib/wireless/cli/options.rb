# frozen_string_literal: true

require "ctx_cli/collection"
require "optparse"
require "ctx_cli/options"
require "ctx_cli/terminal"
require "ctx_cli/initializer"
require "net/connector/inventory/filters"
require "yaml"
require "ipaddr"

module Wireless
  module CLI
    # 采集入口的公开参数；凭据始终留在环境中，不传入解析库或 YAML。
    class Options
      FIELDS = (%w[platform ap_names devices netdisco inventory netdisco_config parallel directory dimensions ssh] + Net::Connector::Inventory::Filters::FIELDS).freeze
      SSH_FIELDS = %w[port command_timeout login_timeout host_key_policy known_hosts].freeze
      attr_reader :values, :flags, :environment

      # 参数先解析，帮助不构造共享加载器或读取任何配置。
      def initialize(argv, env:, out:, config: nil, env_file: nil, directory: nil, discovery: {}, command: "wireless collect")
        @env, @out, @discovery = env, out, discovery
        @cwd = discovery.fetch(:cwd, Dir.pwd)
        @directory, @command = directory || File.join(@cwd, "wireless-reports"), command
        @config, @env_file = config, env_file
        @overrides, @flags, @inventory_overrides = {}, {}, {}
        @parser = parser
        @parser.parse!(argv.dup).tap { |rest| raise ArgumentError, "不接受位置参数" unless rest.empty? }
      end

      # 实际文件及来源来自同一批次加载快照。
      def config = config_loader.config
      def env_file = config_loader.env_file
      def sources = config_loader.sources

      # 帮助和范例只打印文本，不读取文件或加载可选网络依赖。
      def informational?
        if flags[:help] || flags[:help_all]
          @out.puts @parser
          if flags[:help_all]
            @out.puts "环境默认：WIRELESS_CONFIG、WIRELESS_PLATFORM、WIRELESS_PARALLEL（或 NC_PARALLEL）、WIRELESS_DIRECTORY。"
            @out.puts "连接与清单默认：NC_HOST_KEY_POLICY、NC_KNOWN_HOSTS、ND_CACHE_TTL；Netdisco 使用 ND_URL 和 ND_USERNAME / ND_PASSWORD 或 ND_API_KEY。"
            @out.puts "凭据：NC_DEVICE_USERNAME / NC_DEVICE_PASSWORD，或 NC_H3C_WIRELESS_USERNAME / NC_H3C_WIRELESS_PASSWORD、NC_HUAWEI_USERNAME / NC_HUAWEI_PASSWORD；可选 NC_ENABLE_PASSWORD。"
            @out.puts "AP LLDP 独立凭据：WIRELESS_AP_PASSWORD，可选 WIRELESS_AP_USERNAME；须显式请求 lldp。"
            @out.puts "CLI > 进程环境 > YAML > .env > 默认；相对路径基于来源文件，CLI/进程路径基于启动目录。默认报告：#{@directory}"
            @out.puts "逐层发现：系统、用户配置目录、入口脚本目录、启动目录；每层 net-connector.yml 后 wireless.yml，显式文件最后叠加。"
          end
        elsif flags[:examples]
          @out.puts "常用示例（地址须替换为实际清单地址）：\n  初始化缺失文件后退出：\n    #{@command} --init --non-interactive\n  预览筛选清单：\n    #{@command} --host 192.0.2.10 --plan\n  按名称选择设备：\n    #{@command} --name wlc --exclude-name spare -p 4\n  自动化采集摘要：\n    #{@command} --dimensions access_points,clients --json --no-progress"
        else
          return false
        end
        true
      end

      # 自动化拒绝强制问答；帮助分支无需检查终端或消费输入。
      def validate_interaction!(input:, error:)
        if flags[:interactive] && !CtxCli::Terminal.tty?(input, error)
          raise CtxCli::Collection::Error, "--interactive 需要交互终端；自动化请使用 --init --non-interactive"
        end
      end

      # .env 仅构成当前批次快照，绝不修改调用者的 ENV 或 Hash。
      def load_environment
        config_loader.load_environment(allow_missing: flags[:init] == true)
        @environment = config_loader.environment
        self
      end

      # CLI > 原进程环境 > YAML > .env > 默认；路径在各源合并前解析。
      def load
        load_environment
        files = config_loader.load
        data = Net::Connector::Config.merge(files.data)
        specific = files.specific
        dynamic = %w[netdisco inventory netdisco_config]
        if specific["devices"].is_a?(Array) && specific["devices"].any? && dynamic.none? { |key| specific.key?(key) }
          data = data.reject { |key, _| %w[netdisco inventory].include?(key) }
        elsif specific["netdisco_config"] && (specific.keys & %w[netdisco inventory]).empty?
          data = data.reject { |key, _| %w[netdisco inventory].include?(key) }
        end
        raise ArgumentError, "YAML 须为映射，且只接受公开配置字段" unless (data.keys - FIELDS).empty?
        defaults = { "platform" => "h3c", "ap_names" => [], "devices" => [], "parallel" => 4,
          "directory" => @directory, "dimensions" => nil, "ssh" => ssh_defaults }
        process_values = public_environment(files.process_environment, dynamic: %w[netdisco inventory].any? { |key| data.key?(key) })
        file_defaults = public_environment(files.file_environment, dynamic: %w[netdisco inventory].any? { |key| data.key?(key) },
          higher: Net::Connector::Config.merge(data, process_values))
        @values = Net::Connector::Config.merge(defaults, file_defaults, data, process_values, @overrides)
        if !values["parallel"].is_a?(Integer) && values["parallel"].is_a?(String) && values["parallel"].match?(/\A[0-9]+\z/)
          values["parallel"] = Integer(values["parallel"], 10)
        end
        validate!
        netdisco_settings if values["netdisco"] || values["inventory"] || values["netdisco_config"]
        self
      end

      # 复用连接器的配置 schema、环境默认和清单策略，凭据不并入公开配置。
      def netdisco_settings
        return @netdisco_settings if @netdisco_settings
        require "net/connector/netdisco"
        schema = Net::Connector::Netdisco::Config
        sections = %w[netdisco inventory]
        data = values["netdisco_config"] ? external_inventory_data : values.slice(*sections)
        defaults = schema.parse_sections(data, sections: sections)
        keys = schema.environment_keys
        inventory_keys = schema.environment_keys(sections: sections)
        defaults = config_loader.file_environment.slice(*inventory_keys).merge(defaults).merge(config_loader.process_environment.slice(*inventory_keys))
        overrides = @inventory_overrides.transform_keys { |key| schema::FIELDS.fetch("netdisco").fetch(key).first }
        environment = @environment.reject { |key, _| keys.include?(key) || key == "NC_CONFIG" }
        @inventory_public = schema.from_environment(defaults.merge(overrides), sections: sections)
        @netdisco_settings = Net::Connector::Netdisco::Settings.new(env: environment, defaults: defaults, overrides: overrides).for_run(mode: :inventory)
      rescue LoadError
        raise LoadError, "Netdisco 清单需要 net-connector >= 0.17.1；请安装项目依赖", cause: nil
      end

      # 外部清单同样按文件来源解析路径，并在预检时固定本批配置。
      def external_inventory_data
        Net::Connector::Config.new(name: "backup", env: {}, directories: [], config: values.fetch("netdisco_config"),
          path_fields: %w[netdisco.cache_directory netdisco.db_sslrootcert],
          path_literals: { "netdisco.db_sslrootcert" => [ "system" ] }).load.data
      end
      private :external_inventory_data

      # 展示外部清单的有效公开字段，预览与执行共用本批快照。
      def public_values
        return values unless values["netdisco_config"]
        netdisco_settings
        values.merge("inventory_configuration" => @inventory_public)
      end

      # 只初始化缺失文件，排他创建防止覆盖现场配置；不读取设备清单。
      def initialize_files
        load_environment
        template = File.read(File.join(__dir__, "templates/wireless.yml"))
        public_defaults = { "directory" => @directory, "parallel" => 4 }
        process_values = public_environment(config_loader.process_environment, dynamic: true)
        public_defaults = Net::Connector::Config.merge(public_defaults,
          public_environment(config_loader.file_environment, dynamic: true, higher: process_values), process_values)
        template_data = YAML.safe_load(template)
        @values = Net::Connector::Config.merge(template_data, public_defaults, @overrides)
        parallel = values["parallel"]
        if parallel.is_a?(String) && parallel.match?(/\A[0-9]+\z/)
          values["parallel"] = Integer(parallel, 10)
        end
        validate!
        # 公共 NC_PARALLEL 保持继承；只有本工具显式覆盖才写入 YAML。
        parallel_source = [ config_loader.process_environment, config_loader.file_environment ].find do |source|
          source["WIRELESS_PARALLEL"] || source["NC_PARALLEL"]
        end
        overrides_parallel = @overrides.key?("parallel") || parallel_source&.fetch("WIRELESS_PARALLEL", nil)
        document = overrides_parallel ? values : values.reject { |key, _| key == "parallel" }
        template = template.lines("\n").select { |line| line.start_with?("#") }.join("") +
          Net::Connector::Config.dump(document, name: "wireless", path: config_loader.init_config)
        { config_loader.init_config => template, config_loader.init_env_file => File.read(File.join(__dir__, "templates/env.example")) }.each do |path, body|
          status = CtxCli::Initializer.new(prefix: ".wireless-init-").create(path: path, contents: body)
          @out.puts "#{status == :created ? '已创建' : '已保留'}：#{path}"
        end
        @out.puts "请检查配置及凭据后再次运行；本次未读取清单、未连接设备。"
      end

      # 默认仅在真实终端提供初始化选择；自动化从不消费 stdin。
      def missing?(input:, error:)
        config_loader.load
        return false unless config_loader.missing?
        terminal = CtxCli::Terminal.new(input: input, out: error)
        if terminal.tty? && flags[:interactive] != false
          answer = terminal.question("配置不存在：#{config}；是否创建配置与环境模板？[y/N] ")
          if answer&.match?(/\Ay(?:es)?\z/i)
            initialize_files
            return true
          end
        end
        raise ArgumentError, "配置不存在：#{config}；请执行 --init 后填写设备，或使用 --config 指定配置"
      end

      # 公开配置输出与实际清单复用身份预检；不为 --show-config 读取远端清单。
      def normalize_devices(rows)
        raise ArgumentError, "devices 须为数组" unless rows.is_a?(Array)
        targets = rows.map { |row| normalize_device(row) }
        raise ArgumentError, "设备清单包含重复管理地址" unless targets.map { |row| row.fetch("host") }.uniq.size == targets.size
        targets
      end

      private

      # 设备身份只接受公开字段，拒绝隐藏在 YAML 中的密码或连接参数。
      def normalize_device(row)
        unless row.is_a?(Hash) && (row.keys - %w[host name model platform]).empty? && row["host"].is_a?(String) && !row["host"].include?("/")
          raise ArgumentError, "devices 仅接受 host、name、model、platform，host 须为单个 IP"
        end
        host = IPAddr.new(row.fetch("host")).to_s
        %w[name model].each { |key| raise ArgumentError, "设备 #{key} 须为非空字符串" if row.key?(key) && !row[key].nil? && (!row[key].is_a?(String) || row[key].strip.empty?) }
        platform = row["platform"] || values.fetch("platform")
        raise ArgumentError, "设备 platform 无效" unless Wireless::SUPPORTED_PLATFORMS.include?(platform)
        { "platform" => platform, "host" => host, "name" => row["name"] || host, "model" => row["model"] }.freeze
      rescue IPAddr::Error
        raise ArgumentError, "设备 host 无效", cause: nil
      end

      # 显式声明短参数与长参数；不提供难以发现的兼容缩写。
      def parser
        OptionParser.new do |p|
          p.banner = "用法：#{@command} [选项]（只读 WIRELESS 采集）"
          CtxCli::Options.configuration(p, parallel_help: "设备并发 1～500；继承 NC_PARALLEL，未配置时 4") do |key, value|
            case key
            when :config then @config = File.expand_path(value, @cwd)
            when :env_file then @env_file = File.expand_path(value, @cwd)
            when :directory then @overrides["directory"] = File.expand_path(value, @cwd)
            when :parallel then @overrides["parallel"] = value
            end
          end
          p.on("--platform NAME", "默认平台 h3c / h3c_wireless / huawei") { |v| @overrides["platform"] = v }
          p.on("--ap-name LIST", "LLDP 仅选择指定 AP 名称，逗号分隔") { |v| (@overrides["ap_names"] ||= []).concat(list(v)) }
          p.on("--dimensions LIST", "逗号分隔维度；--help 查看支持项") { |v| @overrides["dimensions"] = list(v) }
          Net::Connector::Inventory::Filters.add_options(p) do |key, value|
            if value.is_a?(Array)
              (@overrides[key] ||= []).concat(value)
            else
              @overrides[key] = value
            end
          end
          CtxCli::Options.initialization(p, flags)
          p.on("--plan", "--inventory-only", "预览筛选清单，不连接设备") { flags[:inventory_only] = true }
          p.on("--cache-only", "只读已验证清单缓存") { inventory_override("cache_mode", "only") }
          p.on("--refresh-inventory", "强制刷新清单，失败按缓存策略处理") { inventory_override("cache_mode", "refresh") }
          p.on("--cache-mode MODE", %w[prefer only refresh], "清单缓存 prefer / only / refresh") { |v| inventory_override("cache_mode", v) }
          p.on("--source SOURCE", %w[http postgres], "清单来源 http / postgres") { |v| @inventory_overrides["source"] = v }
          p.on("--show-config", "查看公开有效配置") { flags[:show_config] = true }
          CtxCli::Options.output(p, flags)
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| flags[:scripts] = value }
          CtxCli::Options.information(p, flags)
          p.separator "维度：#{Wireless::SUPPORTED_DIMENSIONS.join(', ')}"
          p.separator "默认按各设备平台采集全部控制器维度；AP LLDP 须显式请求，Huawei 当前支持 access_points、clients。"
          p.separator "优先级：CLI > 进程环境 > YAML > .env > 默认。退出码：0 完整/预览；1 未完成/无目标；2 参数/持久化错误；130 取消。"
        end
      end

      # 列表中的空项属于输入错误，不能被静默删掉。
      def list(value) = CtxCli::Options.list(value)

      # 互斥缓存请求不能被参数出现顺序静默覆盖。
      def inventory_override(key, value)
        previous = @inventory_overrides[key]
        raise ArgumentError, "清单缓存选项互斥" if previous && previous != value
        @inventory_overrides[key] = value
      end

      # 共享配置加载只依赖轻量文件入口，缺少新版本明确报错。
      def config_loader
        @config_loader ||= begin
          require "net/connector/config"
          Net::Connector::Config.new(name: "wireless", env: @env, config: @config, env_file: @env_file,
            path_fields: %w[directory netdisco_config ssh.known_hosts netdisco.cache_directory netdisco.db_sslrootcert],
            env_path_keys: %w[WIRELESS_DIRECTORY NC_KNOWN_HOSTS ND_CACHE_DIRECTORY ND_DB_SSLROOTCERT],
            path_literals: { "netdisco.db_sslrootcert" => [ "system" ], "ND_DB_SSLROOTCERT" => [ "system" ] }, **@discovery)
        end
      rescue LoadError
        raise LoadError, "统一配置加载需要 net-connector >= 0.17.1；请安装项目依赖", cause: nil
      end

      # 各环境层仅编码宿主支持的公开字段，凭据始终留在环境快照。
      def public_environment(env, dynamic:, higher: {})
        result = {}
        { "WIRELESS_PLATFORM" => "platform", "WIRELESS_DIRECTORY" => "directory" }.each do |key, field|
          result[field] = env[key] if env.key?(key)
        end
        result["parallel"] = env["WIRELESS_PARALLEL"] || env["NC_PARALLEL"] if env.key?("WIRELESS_PARALLEL") || env.key?("NC_PARALLEL")
        { "NC_HOST_KEY_POLICY" => "host_key_policy", "NC_KNOWN_HOSTS" => "known_hosts" }.each do |key, field|
          (result["ssh"] ||= {})[field] = env[key] if env.key?(key)
        end
        if dynamic
          require "net/connector/netdisco"
          higher = Net::Connector::Config.merge(higher, "netdisco" => @inventory_overrides)
          result.merge!(Net::Connector::Netdisco::Config.from_environment(env, sections: %w[netdisco inventory], higher: higher))
        end
        result
      end

      # 内置 SSH 默认不从进程环境重复取值。
      def ssh_defaults
        { "host_key_policy" => "strict", "command_timeout" => 60, "login_timeout" => 15 }
      end

      # 先验证整批策略，避免在前面设备连接后才发现后面的非法配置。
      def validate!
        raise ArgumentError, "parallel 须为 1～500" unless values["parallel"].is_a?(Integer) && (1..500).cover?(values["parallel"])
        %w[platform directory].each { |key| raise ArgumentError, "#{key} 须为非空字符串" unless values[key].is_a?(String) && !values[key].strip.empty? }
        raise ArgumentError, "platform 须为 h3c、h3c_wireless 或 huawei" unless Wireless::SUPPORTED_PLATFORMS.include?(values["platform"])
        dimensions = values["dimensions"]
        unless dimensions.nil? || (dimensions.is_a?(Array) && dimensions.any? && dimensions.all?(String) && dimensions.uniq == dimensions && (dimensions - Wireless::SUPPORTED_DIMENSIONS.map(&:to_s)).empty?)
          raise ArgumentError, "dimensions 包含未知、重复或空维度"
        end
        values["devices"] = normalize_devices(values["devices"])
        inline = %w[netdisco inventory].any? { |key| values.key?(key) }
        %w[netdisco inventory].each do |key|
          raise ArgumentError, "#{key} 须为映射" if values.key?(key) && !values[key].is_a?(Hash)
        end
        if inline && (!values["devices"].empty? || values["netdisco_config"])
          raise ArgumentError, "内嵌 Netdisco、netdisco_config 与非空 devices 不能同时使用"
        end
        if @inventory_overrides.any?
          raise ArgumentError, "清单缓存/来源选项仅适用于 Netdisco 清单" unless inline || values["netdisco_config"]
          # 外部清单由 Settings 覆盖；内嵌清单同步显示有效公开值。
          values["netdisco"] = values.fetch("netdisco", {}).merge(@inventory_overrides) if inline
        end
        if values["netdisco"]
          %w[cache_directory].each do |key|
            path = values["netdisco"][key]
            values["netdisco"][key] = File.expand_path(path, @cwd) if path.is_a?(String)
          end
        end
        if values["netdisco_config"]
          raise ArgumentError, "netdisco_config 须为配置路径，且不能同时声明 devices" unless values["netdisco_config"].is_a?(String) && !values["netdisco_config"].empty? && values["devices"].empty?
          values["netdisco_config"] = File.expand_path(values["netdisco_config"], @cwd)
        end
        Net::Connector::Inventory::Filters::LISTS.each_key { |key| values[key] = values.fetch(key, []) }
        Net::Connector::Inventory::Filters.selection(values)
        items = values["ap_names"]
        raise ArgumentError, "ap_names 须为非空字符串数组" unless items.is_a?(Array) && items.all? { |v| v.is_a?(String) && !v.strip.empty? && !/[\x00-\x1f\x7f]/.match?(v) }
        ssh = values["ssh"]
        raise ArgumentError, "ssh 包含未知或敏感字段" unless ssh.is_a?(Hash) && (ssh.keys - SSH_FIELDS).empty?
        ssh = ssh_defaults.merge(ssh)
        raise ArgumentError, "host_key_policy 须为 strict 或 accept_new" unless %w[strict accept_new].include?(ssh["host_key_policy"])
        %w[command_timeout login_timeout].each { |key| raise ArgumentError, "#{key} 须为正数" unless ssh[key].is_a?(Numeric) && ssh[key].finite? && ssh[key].positive? }
        raise ArgumentError, "port 须为 1～65535" if ssh.key?("port") && (!ssh["port"].is_a?(Integer) || !(1..65535).cover?(ssh["port"]))
        if ssh.key?("known_hosts")
          raise ArgumentError, "known_hosts 须为路径" unless ssh["known_hosts"].is_a?(String) && !ssh["known_hosts"].empty?
          ssh["known_hosts"] = File.expand_path(ssh["known_hosts"], @cwd)
        end
        values["ssh"] = ssh
        values["directory"] = File.expand_path(values["directory"], @cwd)
      rescue IPAddr::Error
        raise ArgumentError, "hosts 须为 IP 或 CIDR，不展开地址、不扫描网段", cause: nil
      end
    end
  end
end
