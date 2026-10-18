# frozen_string_literal: true

require_relative "../record_parser"

module Wireless
  module H3c
    module Parsers
      # 型号能力与发现的 AP 资产及 Radio 分开保存。
      class DisplayWlanApModelAll < RecordParser
        MODEL_FIELDS = { "alias" => :alias, "vendor name" => :vendor_name, "vendor id" => :vendor_id,
          "license weight" => :license_weight, "license type" => :license_type, "radio count" => :radio_count, "type" => :type }.freeze
        RADIO_FIELDS = { "mode" => :modes, "default mode" => :default_mode, "bss count" => :bss_count }.freeze
        VERSION_FIELDS = { "software version" => :software_version, "default software version" => :default_software_version,
          "image name" => :image_name }.freeze
        INTEGER_FIELDS = %i[vendor_id license_weight license_type radio_count bss_count].freeze

        private

        # 解释当前命令记录，保留不完整行诊断。
        def parse_text(text, complete:)
          records, issues = [], []
          lines = text.lines("\n")
          model = section = nil
          mapping = MODEL_FIELDS
          read_fields(text, issues).each do |label, raw, line|
            with_field_validation(issues, line) do
              if label == "ap model"
                raise ArgumentError, "Missing AP model" unless raw
                model = { model: raw, radios: [], versions: [] }
                records << model
                section, mapping = model, MODEL_FIELDS
              elsif model && (match = /\Aradio (\d+)\z/.match(label)) && raw.nil?
                section = { radio_id: Fields.integer(match[1]).to_s }
                model[:radios] << section
                mapping = RADIO_FIELDS
              elsif model && label == "version support list" && raw.nil?
                section, mapping = nil, VERSION_FIELDS
              elsif model && (match = /\Ahardware version (.+)\z/.match(label)) && raw.nil?
                section = { hardware_version: lines[line - 1].strip[/\AHardware version (.+?)\s*:/i, 1] }
                model[:versions] << section
                mapping = VERSION_FIELDS
              elsif section && (field = mapping[label])
                assign_value(section, field, convert_model_field(field, raw), issues, line)
              else
                issues << { code: :unrecognized_field, line: line }
              end
            end
          end
          records.each { |record| check_model_completeness(record, issues) }
          Fields.result(records, issues: issues, complete: complete, total: reported_record_total(text, "AP models", issues), identity: [ :model ])
        end

        # 根据声明字段类型归一化型号能力值。
        def convert_model_field(field, raw)
          return Fields.integer(raw) if INTEGER_FIELDS.include?(field)
          return raw&.split(/\s*,\s*/) if field == :modes

          field == :type ? raw&.sub(/\A:\s*/, "") : raw
        end

        # 输出可作为权威事实的型号能力前，先校验其有效性。
        def check_model_completeness(record, issues)
          radios = record[:radios]
          if record[:radio_count].nil? || record[:radio_count] != radios.size ||
              radios.any? { |radio| %i[modes default_mode bss_count].any? { |key| radio[key].nil? } }
            issues << { code: :incomplete_model, model: record[:model] }
          end
          if record[:versions].any? { |version| VERSION_FIELDS.values.any? { |key| version[key].nil? } }
            issues << { code: :incomplete_version, model: record[:model] }
          end
          [ [ radios, :radio_id ], [ record[:versions], :hardware_version ] ].each do |rows, key|
            issues << { code: :duplicate_identity, model: record[:model] } if rows.map { |row| row[key] }.uniq.size != rows.size
          end
        end
      end
    end
  end
end
