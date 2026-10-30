# frozen_string_literal: true

require "ctx_driver"
require "ctx_parser/immutable"
require_relative "h3c/profile"
require_relative "observation"
require_relative "neighbor_parser"

module Wireless
  # AP 邻居采集拥有选择范围、凭据延迟读取和逐 AP 证据；只借用控制器会话。
  class ApCollection
    def initialize(clock: -> { Time.now.utc }, ap_session_factory: nil)
      unless ap_session_factory.nil? || ap_session_factory.respond_to?(:call)
        raise ArgumentError, "AP session factory must be callable"
      end
      @clock, @ap_session_factory = clock, ap_session_factory
    end

    # 回调前固定选择范围；输入错误在凭据读取或 AP 会话构造之前报告。
    def collect(session:, access_points:, credentials: nil, names: [])
      unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && !name.strip.empty? && !/[\x00-\x1f\x7f]/.match?(name) }
        raise ArgumentError, "Invalid AP selection"
      end
      unless access_points.nil? || (access_points.is_a?(Observation) && access_points.name == :access_points)
        raise ArgumentError, "AP collection requires an access point observation"
      end
      gather(session, access_points, credentials, CtxParser::Immutable.copy(names))
    end

    def inspect = "#<#{self.class.name}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)

    private

    # 独立采集 AP 邻居证据，并报告 AP 覆盖不完整的情况。
    def gather(session, aps, credentials_source, names)
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
          source = collected.fetch(:evidence)
          evidence << source.slice(:command, :sha256, :bytes, :observed_at, :status).merge(context: source.except(:command, :sha256, :bytes, :observed_at, :status))
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
        source = (result.evidence.first&.to_h || {}).except(:context).merge(source)
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

    # 构建明确不可用的 AP 观测，不改变控制器采集的独立事实。
    def unavailable_observation(name, status, code, **details)
      Observation.new(name: name, status: status, completed_at: @clock.call, issues: [ { code: code, **details } ])
    end
  end
end
