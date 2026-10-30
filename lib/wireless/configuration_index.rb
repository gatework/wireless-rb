# frozen_string_literal: true

require "ctx_parser/immutable"

module Wireless
  # 一份配置拥有一份名称索引；重复名称保留歧义，不能取第一条作为变更依据。
  class ConfigurationIndex
    attr_reader :configuration

    def self.coerce(value) = value.is_a?(self) ? value : new(value)

    def initialize(configuration)
      raise ArgumentError, "Configuration must be a mapping" unless configuration.is_a?(Hash)
      @configuration = CtxParser::Immutable.copy(configuration)
      templates = @configuration.fetch("service_templates", [])
      unless templates.is_a?(Array) && templates.all? { |row| row.is_a?(Hash) && row["name"].is_a?(String) }
        raise ArgumentError, "Service templates require names"
      end
      @templates = templates.group_by { |row| row.fetch("name") }.transform_values(&:freeze).freeze
      freeze
    end

    def template(name)
      matches = @templates.fetch(name, [])
      matches.first if matches.one?
    end

    def inspect = "#<#{self.class.name}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end
end
