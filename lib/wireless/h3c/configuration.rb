# frozen_string_literal: true

module Wireless
  module H3c
    # 维护实体身份、归属及认证类型，不解析 CLI 文本或管理来源游标。
    class Configuration
      Scope = Data.define(:kind, :record, :path) do
        # 解析当前配置块内的设置。
        def settings = %i[ap_groups service_templates].include?(kind) ? record[:configuration] : record

        # 解析已配置 AP 型号及其声明能力。
        def model(name)
          raise ArgumentError, "AP model outside group" unless kind == :ap_groups
          descend(:model, [ :model_profiles, name ], radios: {})
        end

        # 在所属 AP 或型号作用域内解析 Radio 块。
        def radio(identity)
          unless %i[access_points ap_groups model global_configuration virtual_ap_group].include?(kind)
            raise ArgumentError, "Invalid Radio owner"
          end
          if kind == :ap_groups && /\A\d+\z/.match?(identity)
            raise ArgumentError, "Group radio requires a model"
          end

          collection = identity.end_with?("g") ? :band_defaults : :radios
          keys = [ collection, identity ]
          keys.unshift(:configuration) if kind == :ap_groups
          descend(:radio, keys, service_templates: [])
        end

        # 在声明的配置作用域内解析 AP 以太网设置。
        def ethernet(name)
          raise ArgumentError, "Invalid Ethernet owner" unless %i[access_points model].include?(kind)
          descend(:ethernet, [ :ethernet_ports, name ])
        end

        # 汇总已解析记录，并报告未解决或不完整的来源状态。
        def finish
          record[:authentication_type] = authentication if kind == :service_templates
          record
        end

        private

        # 分析子设置，同时保留父结果路径。
        def descend(kind, keys, **defaults)
          parent = keys[0...-1].reduce(record) { |value, key| value[key] ||= {} }
          child = parent[keys.last] ||= defaults
          self.class.new(kind: kind, record: child, path: path + keys)
        end

        # 解析实际生效的认证方法及外部服务器引用。
        def authentication
          mode = settings[:client_security_authentication_mode]
          return "dot1x" if mode == "dot1x" || settings[:akm_modes].include?("dot1x") || settings[:dot1x_domain]
          return "mab" if mode == "mac" || settings[:mac_authentication_domain]
          return "psk" if settings[:akm_modes].include?("psk") || settings[:has_preshared_key]
          return "portal" if settings[:portal]&.key?(:enable_method)
          nil
        end
      end

      attr_reader :data

      # 初始化无线实体集合及配置诊断。
      def initialize
        @data = { access_points: {}, ap_groups: [], service_templates: [], global_settings: {}, blacklist: [], whitelist: [] }
      end

      # 使用实体集合作为身份索引，首条重复记录仅供部分结果保留。
      def entity(kind, name, model: nil, type: nil)
        collection = data.fetch(kind)
        duplicate = kind == :access_points ? collection.key?(name) : collection.any? { |record| record[:name] == name }
        raise ArgumentError, "Duplicate wireless configuration identity" if duplicate

        record = case kind
        when :ap_groups
          { name: name, ap_names: [], serial_ids: [], vlan_ids: [], model_profiles: {}, configuration: type ? { type: type } : {} }
        when :service_templates
          { name: name, ssid: nil, vlan_id: nil, enabled: nil, configuration: { akm_modes: [], cipher_suites: [], security_ies: [] } }
        when :access_points
          { name: name, model: model, radios: {} }
        end
        identity = kind == :access_points ? name : collection.size
        kind == :access_points ? collection[name] = record : collection << record
        Scope.new(kind: kind, record: record, path: [ kind, identity ])
      end

      # 解析支持的控制器全局无线配置。
      def global(kind = :global, identity: nil)
        record = data[:global_settings]
        path = [ :global_settings ]
        unless %i[global global_configuration].include?(kind)
          record = record[kind] ||= {}
          path << kind
        end
        if kind == :virtual_ap_group
          record = record[identity] ||= {}
          path << identity
        end
        Scope.new(kind: kind, record: record, path: path)
      end

      # 展示对象身份与状态，避免泄露原始回显或凭据。
      def inspect = "#<#{self.class} aps=#{data[:access_points].size} groups=#{data[:ap_groups].size} templates=#{data[:service_templates].size}>"
    end
  end
end
