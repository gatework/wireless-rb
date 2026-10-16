# frozen_string_literal: true

require "net/connector"
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
      unless password.is_a?(String) && !password.strip.empty? && !/[\x00-\x1f\x7f]/.match?(password) &&
          (username.nil? || (username.is_a?(String) && !/[\x00-\x1f\x7f]/.match?(username)))
        raise ArgumentError, "Invalid AP credentials"
      end
      @controller, @password, @username = controller, password, username
      @usable = true
    end

    # 嵌套登录 AP 读取 LLDP，并确认返回原控制器提示符。
    def read(access_point:)
      return { error: :controller_session_lost, skipped: true } unless @usable && @controller.connected?
      return { error: :ap_not_online, skipped: true } unless Fields.online_status(access_point[:operational_status]) == "online"
      address = Fields.ip(access_point[:management_ip])
      return { error: :ap_address_unavailable, skipped: true } unless address && IPAddr.new(address).ipv4? && address != "0.0.0.0"

      outcome = {}
      @controller.with_operation(:wireless_ap_lldp) do
        original_prompt = prompt
        raise Error, :controller_prompt_mismatch unless DEVICE_PROMPT.match?(original_prompt)
        entered = false
        returned = false
        begin
          interactions = [ Net::Connector::Interaction.new(/password:\s*\z/i, "#{@password}\n", sensitive: true, limit: 1, capture: false) ]
          interactions.unshift(Net::Connector::Interaction.new(/(?:login|username):\s*\z/i, "#{@username}\n", sensitive: true, limit: 1, capture: false)) if @username
          login = execute("telnet #{address}", DEVICE_PROMPT, timeout: 10, interactions: interactions)
          confirm(login)
          returned = prompt == original_prompt
          # 只有提示符已切换到 AP 才确认登录，命令成功返回控制器不代表接入成功。
          entered = prompt != original_prompt && DEVICE_PROMPT.match?(prompt)
          raise Error, :ap_authentication_failed if AUTHENTICATION_FAILURE.match?(login.output)
          raise Error, :ap_connection_failed if CONNECTION_FAILURE.match?(login.output)
          raise Error, :ap_login_not_confirmed unless entered
          reader = CtxDriver::Reader.new(session: @controller)
          preparation = reader.read("screen-length disable")
          raise Error, preparation.failure.fetch(:code) unless preparation.success?

          result = reader.read(COMMAND)
          outcome[:result] = result
          raise Error, result.failure.fetch(:code) unless result.success?
        rescue Error, Net::Connector::Error => error
          outcome[:error] = error.is_a?(Error) ? error.code : Net::Connector::ErrorMetadata.code(error.code) || :collection_failed
        ensure
          begin
            # 已进入 AP 才发送退出；必须确认返回原提示符后才能继续复用控制器会话。
            if entered && @controller.connected?
              confirm(execute("quit", exact_prompt(original_prompt)))
              returned = prompt == original_prompt
            end
            @usable = returned && @controller.connected? && prompt == original_prompt
          rescue Error, Net::Connector::Error
            @usable = false
          end
          outcome[:cleanup_error] = :ap_exit_failed unless @usable
        end
      end
      outcome
    rescue ArgumentError, IPAddr::InvalidAddressError
      { error: :ap_address_unavailable, skipped: true }
    rescue Error, Net::Connector::Error => error
      @usable = false
      { error: error.is_a?(Error) ? error.code : Net::Connector::ErrorMetadata.code(error.code) || :collection_failed }
    ensure
      begin
        @controller.close if !@usable && @controller.connected?
      rescue Net::Connector::Error
        outcome[:cleanup_error] = :session_close_failed if outcome
      end
    end

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} usable=#{@usable}>"

    private

    # 渲染当前终端提示符，用于安全核对嵌套会话身份。
    def prompt = Net::Connector::TerminalRenderer.render(@controller.current_prompt.to_s).strip

    # 只有匹配原控制器提示符，才确认 AP 会话清理完成。
    def exact_prompt(value) = /(?:\A|(?<=[\r\n]))[ \t\x00]*#{Regexp.escape(value)}[ \t\x00]*[\r\n]*\z/

    # 通过连接器操作边界执行敏感 AP 交互。
    def execute(text, prompt, timeout: 30, interactions: [])
      command = Net::Connector::Command.new(text, prompt: prompt, timeout: timeout, interactions: interactions,
        sensitive: true, output_sensitive: true)
      @controller.execute_operation(Net::Connector::Script.new([ command ]), name: :wireless_ap_lldp, privilege: false)
    end

    # 要求恰好一条交互命令成功完成。
    def confirm(result)
      raise result.error, cause: nil unless result.success?
      raise Error, :ap_response_missing unless result.steps.one?
    end
  end
end
