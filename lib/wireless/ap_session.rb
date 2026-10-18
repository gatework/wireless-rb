# frozen_string_literal: true

# 可选入口单独声明最低连接器版本，核心解析不激活此依赖。
gem "net-connector", ">= 0.13.0"
require "net/connector"
gem "ctx_driver", ">= 0.2.2"
require "ctx_driver"
require_relative "fields"

module Wireless
  # Wireless 负责 AP 接入业务；net-connector 负责交互、超时、敏感输出与互斥。
  class ApSession
    DEVICE_PROMPT = /(?:\A|(?<=[\r\n]))[ \t\x00]*<[^<>\r\n]+>[ \t\x00]*[\r\n]*\z/
    CONNECTION_FAILURE = /Connection\s+(?:refused|timed\s+out|closed|reset|was\s+closed)|No\s+route\s+to\s+host|Unable\s+to\s+connect/i
    AUTHENTICATION_FAILURE = /Login\s+incorrect|Authentication\s+failed/i
    COMMAND = "display lldp neighbor-information verbose".freeze
    class Error < StandardError
      attr_reader :code

      # 保留稳定 AP 失败代码，不包含凭据或设备正文。
      def initialize(code)
        @code = code
        super("AP session failed")
      end
    end

    # 校验 AP 凭据，借用控制器会话进行嵌套接入。
    def initialize(controller:, password:, username: nil)
      unless %i[connected? current_prompt with_operation execute_operation close].all? { |method| controller.respond_to?(method) }
        raise ArgumentError, "Controller must provide an existing operation-capable session"
      end
      unless password.is_a?(String) && !password.strip.empty? && !/[\x00-\x1f\x7f]/.match?(password) &&
          (username.nil? || (username.is_a?(String) && !username.strip.empty? && !/[\x00-\x1f\x7f]/.match?(username)))
        raise ArgumentError, "Invalid AP credentials"
      end
      @controller, @password, @username = controller, password.dup.freeze, username&.dup&.freeze
      @usable = true
    end

    # 借用控制器操作租约；进入 AP、查询、退出和失败关闭均不能与其他查询交错。
    def read(access_point:)
      return { error: :controller_session_lost, skipped: true } unless @usable
      return { error: :ap_address_unavailable, skipped: true } unless access_point.is_a?(Hash)
      return { error: :ap_not_online, skipped: true } unless Fields.online_status(access_point[:operational_status]) == "online"
      address = ap_ipv4_address(access_point)
      return { error: :ap_address_unavailable, skipped: true } unless address

      outcome = {}
      acquired = false
      @controller.with_operation(:wireless_ap_lldp) do
        acquired = true
        unless @usable && @controller.connected?
          @usable = false
          next outcome.merge!(error: :controller_session_lost, skipped: true)
        end
        capture_ap_lldp(address, outcome)
      end
      outcome
    rescue StandardError => error
      # 未取得租约时不改变共享控制器状态，也不能关闭其他操作持有的连接。
      outcome ||= {}
      outcome[:error] ||= error_code(error)
      outcome[:skipped] = true unless acquired
      outcome
    end

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} usable=#{@usable}>"

    private

    # 地址验证只发生在接入前；后续协议错误不能被误报成未尝试的地址失败。
    def ap_ipv4_address(access_point)
      address = Fields.ip_address(access_point[:management_ip])
      address if address && IPAddr.new(address).ipv4? && address != "0.0.0.0"
    rescue ArgumentError, IPAddr::Error
      nil
    end

    # 同一次控制器租约覆盖完整嵌套操作，未确认返回前始终视为不可复用。
    def capture_ap_lldp(address, outcome)
      original_prompt = rendered_prompt
      raise Error, :controller_prompt_mismatch unless DEVICE_PROMPT.match?(original_prompt)

      ap_prompt = nil
      returned = false
      @usable = false
      begin
        login = execute_sensitive_command("telnet #{address}", DEVICE_PROMPT, timeout: 10, interactions: login_interactions)
        require_single_command_success(login)
        current = rendered_prompt
        returned = current == original_prompt
        ap_prompt = current if !returned && DEVICE_PROMPT.match?(current)
        raise Error, :ap_authentication_failed if AUTHENTICATION_FAILURE.match?(login.output)
        raise Error, :ap_connection_failed if CONNECTION_FAILURE.match?(login.output)
        raise Error, :ap_login_not_confirmed unless ap_prompt

        reader = CtxDriver::Reader.new(session: @controller)
        preparation = reader.read("screen-length disable")
        raise Error, preparation.failure.fetch(:code) unless preparation.success?
        raise Error, :ap_session_lost unless rendered_prompt == ap_prompt

        result = reader.read(COMMAND)
        raise Error, :ap_session_lost if result.success? && rendered_prompt != ap_prompt
        outcome[:result] = result
        raise Error, result.failure.fetch(:code) unless result.success?
      rescue StandardError => error
        outcome[:error] = error_code(error)
      ensure
        original_error = $!
        begin
          restore_controller_or_close(original_prompt, ap_prompt, returned, outcome)
        rescue Exception # rubocop:disable Lint/RescueException -- 清理期间的二次取消不能覆盖原有取消，所有异常仍向外传播。
          raise original_error, cause: original_error.cause if original_error
          raise
        end
      end
    end

    # 登录凭据只进入有次数限制的敏感交互，不构造独立 AP 连接。
    def login_interactions
      values = [ Net::Connector::Interaction.new(/password:\s*\z/i, "#{@password}\n", sensitive: true, limit: 1, capture: false) ]
      if @username
        values.unshift(Net::Connector::Interaction.new(/(?:login|username):\s*\z/i, "#{@username}\n", sensitive: true, limit: 1, capture: false))
      end
      values
    end

    # 仅从已确认的 AP 提示符退出；已回控制器时不再发送 quit。
    def restore_controller_or_close(original_prompt, ap_prompt, returned, outcome)
      if @controller.connected?
        current = rendered_prompt
        if ap_prompt && current == original_prompt
          returned = true
        elsif ap_prompt && current == ap_prompt
          require_single_command_success(execute_sensitive_command("quit", exact_prompt_pattern(original_prompt)))
          returned = rendered_prompt == original_prompt
        end
        @usable = returned && @controller.connected? && rendered_prompt == original_prompt
      end
    rescue StandardError
      @usable = false
    ensure
      unless @usable
        outcome[:cleanup_error] = :ap_exit_failed
        close_controller(outcome)
      end
    end

    # 关闭仍位于控制器租约中；退出与关闭失败独立保存，不覆盖已取得的观测。
    def close_controller(outcome)
      @controller.close
    rescue StandardError
      outcome[:close_error] = :session_close_failed
    end

    # 所有失败只暴露稳定代码，不把连接器消息或凭据写入领域观测。
    def error_code(error)
      error.is_a?(Error) ? error.code : CtxDriver::Failure.code(error, :collection_failed)
    end

    # 渲染当前终端提示符，用于安全核对嵌套会话身份。
    def rendered_prompt = Net::Connector::Terminal::Text.render(@controller.current_prompt.to_s).strip

    # 只有匹配原控制器提示符，才确认 AP 会话清理完成。
    def exact_prompt_pattern(value) = /(?:\A|(?<=[\r\n]))[ \t\x00]*#{Regexp.escape(value)}[ \t\x00]*[\r\n]*\z/

    # 通过连接器操作边界执行敏感 AP 交互。
    def execute_sensitive_command(text, prompt, timeout: 30, interactions: [])
      command = Net::Connector::Command.new(text, prompt: prompt, timeout: timeout, interactions: interactions,
        sensitive: true, output_sensitive: true)
      @controller.execute_operation(Net::Connector::Script.new([ command ]), name: :wireless_ap_lldp, privilege: false)
    end

    # 要求恰好一条交互命令成功完成。
    def require_single_command_success(result)
      raise result.error, cause: nil unless result.success?
      raise Error, :ap_response_missing unless result.steps.one?
    end
  end
end
