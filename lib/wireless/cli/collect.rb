# frozen_string_literal: true

require "ctx_cli/collection"
require "wireless"
require "ctx_runner/batch"
require_relative "options"
require_relative "report"
require_relative "connector"

module Wireless
  module CLI
    # 批量入口拥有配置、清单、并行与报告，不向核心库引入宿主依赖。
    class Collect
      # 可注入清单、传输与执行器，离线集成验证不需要任何真实设备。
      def initialize(env: ENV, out: $stdout, error: $stderr, input: $stdin, connector_factory: nil, executor: nil, ap_session_factory: nil, **options)
        @env, @out, @error, @input = env, out, error, input
        @connector_factory, @executor = connector_factory, executor
        @ap_session_factory = ap_session_factory
        @defaults = options
      end

      # 公共入口编排顺序与失败收尾；以下方法是显式领域适配协议。
      def run(argv)
        progress = ->(options) do
          require "net/connector/collect/progress"
          Net::Connector::Collect::Progress.new(io: @error, enabled: !options.flags[:quiet], verbose: options.flags[:verbose])
        end
        CtxCli::Collection.new(adapter: self, options: ->(arguments) { Options.new(arguments, env: @env, out: @out, **@defaults) },
          progress: progress, batch: CtxRunner::Batch, label: "WIRELESS", report_error: Report::Error,
          failure_code: ->(error) { CtxDriver::Failure.code(error, :collection_failed) },
          out: @out, error: @error, input: @input).run(argv)
      end

      # 只在需要库存或网络执行时加载可选依赖，帮助和静态预览保持独立。
      def load_network
        require "net/connector"
      rescue LoadError
        raise LoadError, "联网采集需要 net-connector >= 0.20.0；请在宿主 Gemfile 添加或 gem install net-connector", cause: nil
      end

      # YAML 静态设备或显式 Netdisco 来源二选一；选中地址的所有冲突记录在连接前拒绝。
      def inventory(options, progress:)
        values = options.values
        selection = Net::Connector::Inventory::Filters.selection(values)
        rows = if values["netdisco_config"] || values["netdisco"] || values["inventory"]
          progress.reading_inventory
          settings = options.netdisco_settings
          policy = settings.snapshot(mode: :inventory)
          devices = Net::Connector::Netdisco::Catalog.new(settings: settings).devices(policy: policy)
          devices.filter_map(&:issue).tally.each { |code, count| progress.notice("Inventory: #{code}=#{count}") }
          devices.filter_map do |device|
            next unless %i[h3c_wireless huawei].include?(device.vendor)
            platform = device.vendor.to_s
            if device.issue == :duplicate_host && policy.rules.selected?(device.host, device.vendor, name: device.name, model: device.model) &&
                selection.selected?(device.host, platform, name: device.name || device.host, model: device.model)
              raise CtxCli::Collection::Error, "Duplicate management address in selected inventory"
            end
            next unless device.ready?
            { "host" => device.host, "name" => device.name || device.host, "model" => device.model, "platform" => platform }
          end
        else
          values.fetch("devices")
        end
        targets = options.normalize_devices(rows)
        total = targets.size
        selected = targets.select do |device|
          selection.selected?(device.fetch("host"), device.fetch("platform"), name: device["name"], model: device["model"])
        end
        [ selected, total ]
      end

      # 所有设备先完成凭据、端点与资源预检，再允许创建报告和连接。
      def prepare(devices, options)
        credentials = devices.to_h { |device| [ device.fetch("host"), credentials!(device, options) ] }
        load_network unless @connector_factory && @executor
        unless @connector_factory
          devices.each { |device| Net::Connector::Configuration.new(host: device.fetch("host"), **credentials.fetch(device.fetch("host"))).validate_endpoint! }
        end
        unless @executor
          require "net/connector/resources"
          begin
            Net::Connector::Resources.prepare!(parallel: [ devices.size, options.values.fetch("parallel") ].min)
          rescue ArgumentError
            raise CtxCli::Collection::Error, "本机文件描述符额度不足；请提高终端 ulimit -n 或降低 --parallel。已停止，未连接设备。", cause: nil
          end
        end
        credentials
      end

      def report(options)
        Report.new(options.values.fetch("directory"), scripts: options.flags[:scripts] == true)
      rescue ArgumentError
        raise CtxCli::Collection::Error, "报告目录无效；请使用真实私有目录、权限0700，并检查目录路径。", cause: nil
      end
      def after_collect(report, options) = report.finish_collected_review

      # 缺失用户名时不尝试连接；密码允许省略以支持明确的 SSH key/agent。
      def credentials!(device, options)
        require "net/connector/credentials"
        credentials = Net::Connector::Credentials.new(env: options.environment).resolve(platform: (device.fetch("platform") == "huawei" ? :huawei : :h3c_wireless))
        raise CtxCli::Collection::Error, "Set NC_DEVICE_USERNAME or platform NC_*_USERNAME; provide a password through the environment or use an SSH key/agent" unless credentials
        options.values.fetch("ssh").transform_keys(&:to_sym).merge(credentials)
      end

      # 空白环境值视为缺失，不修改或回显凭据。
      def secret(options, name)
        value = options.environment[name]
        value unless value.nil? || value.strip.empty?
      end

      # 每个任务使用独立 Collector 和会话；公共执行器负责有界并发和线程回收。
      def execute(devices, options, &block)
        parallel = options.values.fetch("parallel")
        return @executor.call(devices, parallel, &block) if @executor
        Net::Connector::Parallel::Pool.new(parallel: parallel).map(devices, &block)
      end

      # 单台失败保留其他设备和已获得维度；报告持久化失败交由批次终止处理。
      def collect(device, options, context:, progress:)
        credentials = context.fetch(device.fetch("host")).merge(on_event: progress.method(:event))
        connector = @connector_factory ? @connector_factory.call(device, credentials) : Connector.new(device, credentials)
        platform = device.fetch("platform")
        dimensions = options.values["dimensions"]&.map(&:to_sym)
        ap_factory = @ap_session_factory
        if dimensions&.include?(:lldp) && %w[h3c h3c_wireless].include?(platform) && !ap_factory
          require "wireless/ap_session"
          ap_factory = ->(**settings) { Wireless::ApSession.new(**settings) }
        end
        snapshot = Wireless::Collector.new(ap_session_factory: ap_factory).collect(connector: connector, target: device, platform: platform,
          model: device["model"], dimensions: dimensions, ap_names: options.values.fetch("ap_names"),
          ap_credentials: -> { { password: secret(options, "WIRELESS_AP_PASSWORD"), username: secret(options, "WIRELESS_AP_USERNAME") } })
        snapshot
      end

      private :load_network, :credentials!, :secret
    end
  end
end
