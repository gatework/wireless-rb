# frozen_string_literal: true

require_relative "parser_registry"
require "ctx_driver"
require_relative "runtime_parser"
require_relative "snapshot"
require_relative "ap_session"
require_relative "neighbor_parser"

module Wireless
  # 按单控制器顺序采集，去重共享查询，并区分失败与跳过维度。
  class Collector
    H3C_COMMANDS = H3c::Profile::COMMANDS.except(:lldp).freeze
    HUAWEI_COMMANDS = { access_points: "display ap all", clients: "display station all" }.freeze
    DEFAULT_DIMENSIONS = H3C_COMMANDS.keys.freeze

    # 注入为顺序命令观测生成时间戳的时钟。
    def initialize(clock: -> { Time.now.utc })
      @clock = clock
    end

    # 通过调用方持有的连接器顺序采集请求维度。
    def collect(connector:, target:, platform:, model: nil, dimensions: DEFAULT_DIMENSIONS, ap_connection: nil, ap_names: [])
      platform = platform.to_s
      raise ArgumentError, "Target must be a hash" unless target.is_a?(Hash)

      unless dimensions.is_a?(Array) && dimensions.any? && dimensions.uniq == dimensions &&
          (dimensions - (DEFAULT_DIMENSIONS + [ :lldp ])).empty? && ap_names.is_a?(Array) &&
          ap_names.all? { |name| name.is_a?(String) && !name.strip.empty? && !/[\x00-\x1f\x7f]/.match?(name) }
        raise ArgumentError, "Invalid wireless dimensions or AP selection"
      end
      requested = dimensions.dup
      # LLDP 需要 AP 清单提供身份；组和服务模板需要配置证据补充关联关系。
      requested |= [ :access_points ] if requested.include?(:lldp)
      requested |= [ :configuration ] if (requested & %i[ap_groups service_templates]).any?
      profile = ParserRegistry.fetch(platform, model: model) unless platform == "huawei"
      commands = profile ? profile.commands.except(:lldp) : HUAWEI_COMMANDS
      observations = requested.reject { |name| commands.key?(name) || (name == :lldp && platform != "huawei") }
        .to_h { |name| [ name, unavailable(name, :unsupported, :unsupported_platform_dimension) ] }
      queries = if profile
        profile.queries(requested & commands.keys)
      else
        commands.slice(*requested).group_by { |_name, command| command }.transform_values { |entries| entries.map(&:first) }
      end
      actual = connector.platform.to_s
      unless actual == platform || ([ actual, platform ] - %w[h3c h3c_wireless]).empty?
        raise ArgumentError, "Wireless platform differs from the device connector"
      end
      stage = :connect
      begin
        connector.open do |session|
          reader = CtxDriver::Reader.new(session: session, clock: @clock)
          stage = :prepare
          preparation = reader.read(platform == "huawei" ? "screen-length 0 temporary" : "screen-length disable")
          error = preparation.failure&.fetch(:code)
          queries.each do |command, names|
            if error
              names.each { |name| observations[name] = unavailable(name, :failed, error, skipped: true, stage: stage) }
              next
            end
            stage = :collect
            observations.merge!(read(reader, command, names, platform, model: model))
          end
          if requested.include?(:lldp) && platform != "huawei"
            unavailable_code = error || reader.failure&.fetch(:code)
            observations[:lldp] = if unavailable_code
              unavailable(:lldp, :failed, unavailable_code, skipped: true, stage: stage)
            else
              # 仅在显式请求 LLDP 且会话准备成功后读取 AP 凭据，避免无关采集访问秘密。
              credentials = (ap_connection.respond_to?(:call) ? ap_connection.call : ap_connection) || {}
              neighbors(session, observations[:access_points], credentials, ap_names)
            end
          end
          stage = :close
        end
      rescue StandardError => error
        raise unless CtxDriver::Failure.connection_error?(error, connector)

        code = CtxDriver::Failure.code(error, :connection_failed)
        requested.each { |name| observations[name] ||= unavailable(name, :failed, code, skipped: true, stage: stage) }
        observations[:collection] = unavailable(:collection, :failed, stage == :close ? :session_close_failed : code)
      end
      status = observations.values.all?(&:complete?) ? :complete : observations.values.any?(&:available?) ? :partial : :failed
      observations[:collection] ||= Observation.new(name: :collection, status: status, completed_at: @clock.call)
      Snapshot.new(target: target, dimensions: observations, observed_at: @clock.call)
    end

    private

    # 单条命令负责自身解析失败；无关查询保留已完成事实。
    def read(reader, command, names, platform, model:)
      capture = reader.read(command)
      metadata = { started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence }
      unless capture.success?
        return failed_observations(names, capture.failure, command: command, skipped: capture.skipped?, **metadata)
      end
      begin
        RuntimeParser.new(model: model).parse_many(names, capture.body, platform: platform, complete: true)
          .transform_values { |observation| observation.with(**metadata) }
      rescue StandardError => error
        details = CtxDriver::Failure.details(error, fallback: :command_processing_failed, stage: :parse)
        failed_observations(names, details, command: command, **metadata)
      end
    end

    # 共享查询的各视图使用相同的安全失败及来源元数据。
    def failed_observations(names, failure, command:, skipped: false, **metadata)
      names.to_h do |name|
        [ name, unavailable(name, :failed, failure.fetch(:code), **failure.except(:code), command: command, skipped: skipped).with(**metadata) ]
      end
    end

    # 独立采集 AP 邻居证据，并报告 AP 覆盖不完整的情况。
    def neighbors(session, aps, credentials, names)
      return unavailable(:lldp, :failed, :access_points_unavailable) unless aps&.available?
      return unavailable(:lldp, :failed, :ap_credentials_required) unless credentials[:password].is_a?(String) && !credentials[:password].strip.empty?
      ap_session = ApSession.new(controller: session, **credentials)
      started = @clock.call
      records, issues, evidence = [], [], []
      selected = aps.records.select { |ap| names.empty? || names.include?(ap[:name]) }
      # 所选 AP 全部查询成功也不代表覆盖整台控制器，过滤范围和父清单缺失须独立报告。
      issues << { code: :partial_access_point_coverage } unless aps.complete?
      issues << { code: :ap_scope_filtered } if selected.size != aps.records.size
      (names - selected.map { |ap| ap[:name] }).each { |name| issues << { code: :ap_not_found, ap_name: name } }
      selected.each do |ap|
        collected = read_neighbor(ap_session, ap)
        records.concat(collected.fetch(:records))
        issues.concat(collected.fetch(:issues))
        evidence << collected.fetch(:evidence)
      end
      status = issues.empty? ? :complete : records.any? || evidence.any? { |entry| entry[:status] == :complete } ? :partial : :failed
      Observation.new(name: :lldp, status: status, records: records, issues: issues, evidence: evidence,
        started_at: started, completed_at: @clock.call)
    rescue ArgumentError
      unavailable(:lldp, :failed, :invalid_ap_credentials)
    end

    # 单个 AP 脚本或解析失败不能丢弃其他 AP 的邻居观测。
    def read_neighbor(ap_session, ap)
      stage = :execute
      source = { kind: :ap_lldp_result, ap_name: ap[:name], command: ApSession::COMMAND,
        attempted: true, status: :failed, neighbor_count: 0 }
      outcome = ap_session.read(access_point: ap)
      result = outcome[:result]
      stage = :response
      source[:attempted] = !outcome[:skipped]
      source.merge!(result.evidence.first || {}) if result
      stage = :parse
      parsed = result&.success? ? NeighborParser.new(model: ap[:model]).parse(result.body, ap_name: ap[:name], complete: true) : nil
      issues = parsed ? parsed.issues.map { |issue| issue.merge(ap_name: ap[:name]) } : []
      %i[error cleanup_error].each { |key| issues << { code: outcome[key], ap_name: ap[:name] } if outcome[key] }
      issues << { code: :ap_collection_failed, ap_name: ap[:name] } if !parsed && issues.empty?
      source.merge!(
        status: outcome[:error] || outcome[:cleanup_error] ? :failed : parsed&.status || :failed,
        neighbor_count: parsed&.records&.size || 0)
      { records: parsed&.records || [], issues: issues, evidence: source }
    rescue StandardError => error
      details = CtxDriver::Failure.details(error,
        fallback: { execute: :command_execution_failed, response: :invalid_command_result, parse: :command_processing_failed }.fetch(stage), stage: stage)
      { records: [], issues: [ details.merge(ap_name: ap[:name]) ], evidence: source }
    end

    # 构建明确不可用的观测，不虚构成功的空结果。
    def unavailable(name, status, code, **details)
      Observation.new(name: name, status: status, completed_at: @clock.call, issues: [ { code: code, **details } ])
    end
  end
end
