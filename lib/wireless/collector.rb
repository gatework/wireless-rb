# frozen_string_literal: true

require_relative "parser_registry"
require "ctx_driver"
require "ctx_runner/collection"
require "ctx_runner/query"
require_relative "snapshot"
require_relative "ap_collection"

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
      collection = CtxRunner::Collection.new
      collection.open(connector) do |session|
        reader = CtxDriver::Reader.new(session: session, clock: @clock)
        collection.stage = :prepare
        preparation = reader.read(profile.preparation_command)
        error = preparation.failure&.fetch(:code)
        queries.each do |command, names|
          if error
            names.each { |name| observations[name] = unavailable_observation(name, :failed, error, skipped: true, stage: collection.stage) }
            next
          end
          collection.stage = :collect
          observations.merge!(collect_command(reader, command, names, profile))
        end
        if requested.include?(:lldp) && profile.commands.key?(:lldp)
          unavailable_code = error || reader.failure&.fetch(:code)
          observations[:lldp] = if unavailable_code
            unavailable_observation(:lldp, :failed, unavailable_code, skipped: true, stage: collection.stage)
          else
            ApCollection.new(clock: @clock, ap_session_factory: @ap_session_factory).collect(
              session: session, access_points: observations[:access_points], credentials: ap_credentials, names: ap_names)
          end
        end
      end
      if collection.failure
        code = collection.failure.fetch(:code)
        requested.each { |name| observations[name] ||= unavailable_observation(name, :failed, code, skipped: true, stage: collection.stage) }
        observations[:collection] = unavailable_observation(:collection, :failed, code)
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
      unavailable = ->(name, capture, details) do
        metadata = { started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence }
        unavailable_observation(name, :failed, details.fetch(:code), **details.except(:code), command: command, skipped: capture.skipped?).with(**metadata)
      end
      CtxRunner::Query.new(reader: reader, parser: profile).read(command, names: names, unavailable: unavailable) do |name, result, capture|
        Observation.new(name: name, **result.to_h, started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence)
      end
    end

    # 构建明确不可用的观测，不虚构成功的空结果。
    def unavailable_observation(name, status, code, **details)
      Observation.new(name: name, status: status, completed_at: @clock.call, issues: [ { code: code, **details } ])
    end
  end
end
