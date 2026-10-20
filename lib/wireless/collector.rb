# frozen_string_literal: true

require_relative "parser_registry"
require "ctx_driver"
require_relative "snapshot"
require_relative "neighbor_parser"

module Wireless
  # 按单控制器顺序采集，去重共享查询，并区分失败与跳过维度。
  class Collector
    H3C_COMMANDS = H3c::Profile::COMMANDS.except(:lldp).freeze
    DEFAULT_DIMENSIONS = H3C_COMMANDS.keys.freeze

    # 注入时钟和可选 AP 会话工厂；核心采集不加载具体传输。
    def initialize(clock: -> { Time.now.utc }, ap_session_factory: nil)
      raise ArgumentError, "AP session factory must be callable" unless ap_session_factory.nil? || ap_session_factory.respond_to?(:call)

      @clock, @ap_session_factory = clock, ap_session_factory
    end

    # 通过调用方持有的连接器顺序采集请求维度。
    def collect(connector:, target:, platform:, model: nil, dimensions: nil, ap_credentials: nil, ap_names: [])
      platform = platform.to_s.dup.freeze
      model = model.dup.freeze if model.is_a?(String)
      raise ArgumentError, "Target must be a hash" unless target.is_a?(Hash)

      profile = ParserRegistry.fetch(platform, model: model)
      dimensions = profile.commands.keys - [ :lldp ] if dimensions.nil?

      unless dimensions.is_a?(Array) && dimensions.any? && dimensions.uniq == dimensions &&
          (dimensions - SUPPORTED_DIMENSIONS).empty? && ap_names.is_a?(Array) &&
          ap_names.all? { |name| name.is_a?(String) && !name.strip.empty? && !/[\x00-\x1f\x7f]/.match?(name) }
        raise ArgumentError, "Invalid wireless dimensions or AP selection"
      end
      # 外部连接和适配器回调前保存身份与选择范围。
      target = CtxParser::Immutable.copy(target)
      ap_names = ap_names.map { |name| name.dup.freeze }.freeze
      requested = dimensions.dup
      # LLDP 需要 AP 清单提供身份；组和服务模板需要配置证据补充关联关系。
      requested |= [ :access_points ] if requested.include?(:lldp)
      requested |= [ :configuration ] if (requested & %i[ap_groups service_templates]).any?
      commands = profile.commands.except(:lldp)
      observations = requested.reject { |name| commands.key?(name) || (name == :lldp && profile.commands.key?(:lldp)) }
        .to_h { |name| [ name, unavailable_observation(name, :unsupported, :unsupported_platform_dimension) ] }
      queries = profile.queries(requested & commands.keys)
      unless compatible_platform?(connector.platform, profile, model)
        raise ArgumentError, "Wireless platform differs from the device connector"
      end
      stage = :connect
      session_started = false
      begin
        connector.open do |session|
          # 宿主重复回调不能重放查询或覆盖首次事实。
          if session_started
            observations[:collection] = unavailable_observation(:collection, :failed, :session_reentered)
            next
          end
          session_started = true
          reader = CtxDriver::Reader.new(session: session, clock: @clock)
          stage = :prepare
          preparation = reader.read(profile.preparation_command)
          error = preparation.failure&.fetch(:code)
          queries.each do |command, names|
            if error
              names.each { |name| observations[name] = unavailable_observation(name, :failed, error, skipped: true, stage: stage) }
              next
            end
            stage = :collect
            observations.merge!(collect_command(reader, command, names, profile))
          end
          if requested.include?(:lldp) && profile.commands.key?(:lldp)
            unavailable_code = error || reader.failure&.fetch(:code)
            observations[:lldp] = if unavailable_code
              unavailable_observation(:lldp, :failed, unavailable_code, skipped: true, stage: stage)
            else
              collect_ap_neighbors(session, observations[:access_points], ap_credentials, ap_names)
            end
          end
          stage = :close
        end
      rescue StandardError => error
        raise unless CtxDriver::Failure.connection_error?(error, connector)

        code = CtxDriver::Failure.code(error, :connection_failed)
        requested.each { |name| observations[name] ||= unavailable_observation(name, :failed, code, skipped: true, stage: stage) }
        observations[:collection] = unavailable_observation(:collection, :failed, stage == :close ? :session_close_failed : code)
      end
      # 连接器未交付会话也不能把空观测视为完整采集。
      requested.each { |name| observations[name] ||= unavailable_observation(name, :failed, :session_not_opened, skipped: true) }
      status = observations.values.all?(&:complete?) ? :complete : observations.values.any?(&:available?) ? :partial : :failed
      observations[:collection] ||= Observation.new(name: :collection, status: status, completed_at: @clock.call)
      Snapshot.new(target: target, dimensions: observations, observed_at: @clock.call)
    end

    private

    # 连接器与请求通过同一 Registry 解析别名；未知平台沿用明确的不匹配错误。
    def compatible_platform?(platform, profile, model)
      ParserRegistry.fetch(platform, model: model).class == profile.class
    rescue ArgumentError
      false
    end

    # 单条命令负责自身解析失败；无关查询保留已完成事实。
    def collect_command(reader, command, names, profile)
      capture = reader.read(command)
      metadata = { started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence }
      unless capture.success?
        return failed_observations(names, capture.failure, command: command, skipped: capture.skipped?, **metadata)
      end
      begin
        profile.parse_many(names, capture.body, complete: true, command: command).to_h do |name, result|
          [ name, Observation.new(name: name, **result.to_h, **metadata) ]
        end
      rescue StandardError => error
        details = CtxDriver::Failure.details(error, fallback: :command_processing_failed, stage: :parse)
        failed_observations(names, details, command: command, **metadata)
      end
    end

    # 共享查询的各视图使用相同的安全失败及来源元数据。
    def failed_observations(names, failure, command:, skipped: false, **metadata)
      names.to_h do |name|
        [ name, unavailable_observation(name, :failed, failure.fetch(:code), **failure.except(:code), command: command, skipped: skipped).with(**metadata) ]
      end
    end

    # 独立采集 AP 邻居证据，并报告 AP 覆盖不完整的情况。
    def collect_ap_neighbors(session, aps, credentials_source, names)
      return unavailable_observation(:lldp, :failed, :access_points_unavailable) unless aps&.available?
      started = @clock.call
      records, issues, evidence = [], [], []
      selected_names = names.to_h { |name| [ name, true ] }
      selected = aps.records.select { |ap| selected_names.empty? || selected_names.key?(ap[:name]) }
      # 空清单和未匹配的选择不需要登录 AP，也不能因此访问凭据。
      issues << { code: :partial_access_point_coverage } unless aps.complete?
      issues << { code: :ap_scope_filtered } if selected.size != aps.records.size
      (names - selected.map { |ap| ap[:name] }).each { |name| issues << { code: :ap_not_found, ap_name: name } }
      if selected.any?
        return unavailable_observation(:lldp, :failed, :ap_session_required) unless @ap_session_factory
        credentials = (credentials_source.respond_to?(:call) ? credentials_source.call : credentials_source) || {}
        return unavailable_observation(:lldp, :failed, :invalid_ap_connection) unless credentials.is_a?(Hash)
        ap_session = @ap_session_factory.call(**credentials, controller: session)
        return unavailable_observation(:lldp, :failed, :invalid_ap_session) unless ap_session.respond_to?(:read)
        selected.each do |ap|
          collected = read_ap_neighbors(ap_session, ap)
          records.concat(collected.fetch(:records))
          issues.concat(collected.fetch(:issues))
          evidence << collected.fetch(:evidence)
        end
      end
      status = issues.empty? ? :complete : records.any? || evidence.any? { |entry| entry[:status] == :complete } ? :partial : :failed
      Observation.new(name: :lldp, status: status, records: records, issues: issues, evidence: evidence,
        started_at: started, completed_at: @clock.call)
    rescue ArgumentError
      unavailable_observation(:lldp, :failed, :invalid_ap_credentials)
    rescue StandardError => error
      details = CtxDriver::Failure.details(error, fallback: :ap_session_setup_failed, stage: :ap_setup)
      unavailable_observation(:lldp, :failed, details.fetch(:code), **details.except(:code))
    end

    # 单个 AP 脚本或解析失败不能丢弃其他 AP 的邻居观测。
    def read_ap_neighbors(ap_session, ap)
      stage = :execute
      source = { kind: :ap_lldp_result, ap_name: ap[:name], command: H3c::Profile::COMMANDS.fetch(:lldp),
        attempted: true, status: :failed, neighbor_count: 0 }
      outcome = ap_session.read(access_point: ap)
      stage = :response
      unless outcome.is_a?(Hash) && (!outcome.key?(:skipped) || [ true, false ].include?(outcome[:skipped]))
        raise TypeError, "AP outcome must be a hash with a boolean skipped flag"
      end
      result = outcome[:result]
      source[:attempted] = !outcome[:skipped]
      unless result.nil?
        unless result.is_a?(CtxDriver::Capture) && result.command == source[:command] && !(outcome[:skipped] && result.success?)
          raise TypeError, "AP capture must match the requested LLDP command"
        end
        # 回执补充摘要与时间；AP 身份、命令和尝试状态始终由本次请求确定。
        source = (result.evidence.first || {}).merge(source)
        source[:attempted] = false if result.skipped?
      end
      # 适配器错误只接受稳定代码；非法字段不泄露正文，也不丢弃已取得的邻居事实。
      failure_codes = %i[error cleanup_error close_error].filter_map do |key|
        code = outcome[key]
        next if code.nil?
        code.is_a?(Symbol) ? code : :invalid_command_result
      end.uniq
      stage = :parse
      parsed = result&.success? ? NeighborParser.new(model: ap[:model]).parse(result.body, ap_name: ap[:name], complete: true) : nil
      issues = parsed ? parsed.issues.map { |issue| issue.merge(ap_name: ap[:name]) } : []
      issues << safe_ap_failure_details(result.failure).merge(ap_name: ap[:name]) if result && !result.success?
      failure_codes.each do |code|
        issues << { code: code, ap_name: ap[:name] } if issues.none? { |issue| issue[:code] == code }
      end
      issues << { code: :ap_collection_failed, ap_name: ap[:name] } if !parsed && issues.empty?
      source.merge!(
        status: failure_codes.any? ? :failed : parsed&.status || :failed,
        neighbor_count: parsed&.records&.size || 0)
      { records: parsed&.records || [], issues: issues, evidence: source }
    rescue StandardError => error
      details = CtxDriver::Failure.details(error,
        fallback: { execute: :command_execution_failed, response: :invalid_command_result, parse: :command_processing_failed }.fetch(stage), stage: stage)
      { records: [], issues: [ details.merge(ap_name: ap[:name]) ], evidence: source }
    end

    # 仅保留驱动诊断契约中的安全字段，不传播适配器附加的原始消息。
    def safe_ap_failure_details(failure)
      details = { code: failure[:code].is_a?(Symbol) ? failure[:code] : :ap_collection_failed }
      details[:stage] = failure[:stage] if failure[:stage].is_a?(Symbol)
      type = failure[:error_type]
      details[:error_type] = type if type.is_a?(String) && CtxDriver::Failure::ERROR_TYPE.match?(type)
      details
    end

    # 构建明确不可用的观测，不虚构成功的空结果。
    def unavailable_observation(name, status, code, **details)
      Observation.new(name: name, status: status, completed_at: @clock.call, issues: [ { code: code, **details } ])
    end
  end
end
