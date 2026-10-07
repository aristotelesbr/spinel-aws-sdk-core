# frozen_string_literal: true

require 'stringio'
require 'uri'
require 'net/http'
require 'securerandom'
require 'openssl'
require 'aws-sigv4'
require_relative 'runtime/retries'

# spinel-aws-sdk-core: written for the package, not copied from the gem. The
# gem builds each call from its API model at run time (Seahorse handlers,
# plugins, Struct classes, Delegator responses). The generated service code
# does that work ahead of time, one method per operation, and calls only the
# small runtime below, which follows the gem's rules where it says so.
module Aws
  # The gem's Aws::EmptyStructure, the data of a response or error that has
  # no members.
  class EmptyStructure
    def to_h = {}
    def empty? = true
  end

  module Runtime
    # A service error read from the wire or from a stub, before the service's
    # Errors.error turns it into the class for its code.
    class ErrorResponse < StandardError
      attr_reader :code, :context

      def initialize(code, context, message)
        @code = code
        @context = context
        super(message)
      end
    end

    # The gem's DynamicErrors#error_class_constant: the constant name a code
    # gets, as a String.
    def self.error_constant(code)
      constant = code.to_s
      constant = constant.gsub(/https?:.*$/, '')
      constant = constant.gsub(/[^a-zA-Z0-9]/, '')
      constant = 'Error' + constant unless constant.match(/^[a-z]/i)
      constant[0].upcase + constant[1..-1]
    end

    # The request side of a call, as the gem's context.http_request shows it.
    class HttpRequest
      attr_reader :body, :endpoint

      def initialize(body, endpoint)
        @body = StringIO.new(body)
        @endpoint = URI.parse(endpoint)
      end
    end

    # The parts of the gem's Seahorse::Client::RequestContext a response
    # exposes.
    class Context
      attr_reader :http_request, :retries

      def initialize(body, endpoint, retries)
        @http_request = HttpRequest.new(body, endpoint)
        @retries = retries
      end
    end

    # The DNS suffix of a region's partition, as aws-partitions' region
    # patterns give it; an unknown region is in the aws partition.
    def self.dns_suffix(region)
      if region.start_with?('cn-') then 'amazonaws.com.cn'
      elsif region.start_with?('us-isob-') then 'sc2s.sgov.gov'
      elsif region.start_with?('us-isof-') then 'csp.hci.ic.gov'
      elsif region.start_with?('us-iso-') then 'c2s.ic.gov'
      elsif region.start_with?('eu-isoe-') then 'cloud.adc-e.uk'
      elsif region.start_with?('eusc-') then 'amazonaws.eu'
      else 'amazonaws.com'
      end
    end

    # The query protocol's request body, by the gem's Aws::Query::ParamList
    # rules: parameters sorted by name, names and values escaped as
    # Seahorse::Util.uri_escape does.
    module Query
      def self.member(values, name)
        values.nil? ? nil : values[name]
      end

      def self.body(pairs)
        params = {}
        pairs.each { |name, value| params[name] = value }
        params.keys.sort.map { |name| "#{escape(name)}=#{escape(params[name])}" }.join('&')
      end

      # The gem's Aws::Util.serialize_date_time.
      def self.timestamp(time)
        time.nsec.zero? ? time.utc.iso8601 : time.utc.iso8601(3)
      end

      # CGI.escape, with a space as %20 and ~ left as is.
      def self.escape(string)
        out = +''
        string.to_s.each_byte do |byte|
          if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
             (byte >= 48 && byte <= 57) || byte == 45 || byte == 46 || byte == 95 || byte == 126
            out << byte.chr
          else
            out << format('%%%02X', byte)
          end
        end
        out
      end
    end

    # A small XML reader for query responses: elements, their text and
    # the five predefined entities. Attributes, comments and the XML
    # declaration are skipped.
    module Xml
      class Node
        attr_reader :name, :children
        attr_accessor :text

        def initialize(name)
          @name = name
          @children = []
          @text = +''
        end

        def child(name)
          @children.find { |c| c.name == name }
        end
      end

      def self.parse(xml)
        root = Node.new('#document')
        stack = [root]
        pos = 0
        while pos < xml.length
          open = xml.index('<', pos)
          if open.nil?
            stack.last.text << decode(xml[pos..-1])
            break
          end
          stack.last.text << decode(xml[pos...open]) if open > pos
          close = xml.index('>', open)
          raise ArgumentError, 'unterminated XML tag' if close.nil?
          tag = xml[(open + 1)...close]
          pos = close + 1
          next if tag.start_with?('?') || tag.start_with?('!')
          if tag.start_with?('/')
            stack.pop
          else
            self_closing = tag.end_with?('/')
            name = tag.sub(%r{/\z}, '').split(/\s+/).first
            node = Node.new(name)
            stack.last.children << node
            stack.push(node) unless self_closing
          end
        end
        root.children.first
      end

      def self.decode(text)
        text.gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"')
            .gsub('&apos;', "'").gsub('&amp;', '&')
      end

      def self.text(node)
        node.nil? ? nil : node.text
      end

      def self.integer(node)
        node.nil? ? nil : node.text.to_i
      end

      # An ISO 8601 time, as STS sends it: 2026-10-07T18:00:00Z, with optional
      # fractional seconds.
      def self.timestamp(node)
        return nil if node.nil?

        t = node.text
        Time.utc(t[0, 4].to_i, t[5, 2].to_i, t[8, 2].to_i, t[11, 2].to_i, t[14, 2].to_i, t[17, 2].to_i)
      end
    end

    # One stubbed response, as the gem's ClientStubs#convert_stub sorts it:
    # a String is an error code, a Hash with exactly :status_code, :headers
    # and :body is a raw HTTP response, any other Hash is response data.
    class Stub
      attr_reader :error_code, :data, :status_code, :body

      def initialize(stub)
        @error_code = nil
        @data = nil
        @status_code = nil
        @body = nil
        if stub.is_a?(String)
          @error_code = stub
        elsif stub.size == 3 && stub.key?(:status_code) && stub.key?(:headers) && stub.key?(:body)
          @status_code = stub[:status_code]
          @body = stub[:body]
        else
          @data = stub
        end
      end

      def data? = !@data.nil?
      def error? = !@error_code.nil?
    end

    # The base of every generated client: options, stubs and the transport.
    class Client
      STUB_ERROR_MESSAGE = 'stubbed-response-error-message'
      CONTENT_TYPE = 'application/x-www-form-urlencoded; charset=utf-8'
      USER_AGENT = 'aws-sdk-ruby3/3.257.0 ua/2.1 lang/spinel'

      def initialize(options, endpoint_prefix, signing_name, service_id = endpoint_prefix)
        @options = options
        @endpoint_prefix = endpoint_prefix
        @signing_name = signing_name
        @service_id = service_id
        @retries = 0
        @stubs = {}
        stubs = options[:stub_responses]
        if stubs.is_a?(Hash)
          stubs.each { |operation, given| stub_responses(operation, given) }
        end
        @region = resolve_region
        @credentials = resolve_credentials
        @configured_endpoint = resolve_configured_endpoint
        resolve_retries
      end

      # The gem's RegionalEndpoint#resolve_region: the option, then
      # AWS_REGION, AMAZON_REGION and AWS_DEFAULT_REGION, then the shared
      # config. With stub_responses, the gem's StubResponses region: the
      # option or 'us-stubbed-1'.
      def resolve_region
        region = @options[:region]
        return region || 'us-stubbed-1' if stub_responses?

        region = ENV.values_at('AWS_REGION', 'AMAZON_REGION', 'AWS_DEFAULT_REGION').compact.first if region.nil?
        region = nil if region == ''
        region = Aws.shared_config.region(profile: @options[:profile]) if region.nil?
        raise Aws::Errors::MissingRegionError if region.nil? || region == ''

        region
      end

      # The gem's RegionalEndpoint#resolve_custom_config_endpoint:
      # AWS_ENDPOINT_URL_<SERVICE ID>, then AWS_ENDPOINT_URL, then the
      # profile's services section or endpoint_url, unless
      # ignore_configured_endpoint_urls (option, environment or profile).
      def resolve_configured_endpoint
        ignore = @options[:ignore_configured_endpoint_urls]
        if ignore.nil?
          value = ENV['AWS_IGNORE_CONFIGURED_ENDPOINT_URLS'] ||
                  Aws.shared_config.ignore_configured_endpoint_urls(profile: @options[:profile])
          ignore = !value.nil? && value.downcase == 'true'
        end
        return nil if ignore

        ENV["AWS_ENDPOINT_URL_#{@service_id.gsub(' ', '_').upcase}"] ||
          ENV['AWS_ENDPOINT_URL'] ||
          Aws.shared_config.configured_endpoint(profile: @options[:profile], service_id: @service_id)
      end

      # The gem's CredentialsConfiguration: the :credentials option, then
      # :access_key_id and :secret_access_key, then the provider chain. With
      # stub_responses, the gem's stubbed credentials.
      def resolve_credentials
        return @options[:credentials] if @options.key?(:credentials)
        if @options[:access_key_id]
          return Aws::Credentials.new(@options[:access_key_id], @options[:secret_access_key], @options[:session_token])
        end
        return Aws::Credentials.new('stubbed-akid', 'stubbed-secret') if stub_responses?

        Aws::CredentialProviderChain.new.resolve
      end

      # The :endpoint option, a configured endpoint, or the service's
      # regional endpoint as the gem's endpoint rules build it.
      def endpoint
        return @options[:endpoint].to_s if @options[:endpoint]
        return @configured_endpoint unless @configured_endpoint.nil?
        return "https://#{@endpoint_prefix}.amazonaws.com" if @region == 'aws-global'

        "https://#{@endpoint_prefix}.#{@region}.#{Runtime.dns_suffix(@region)}"
      end

      def stub_responses?
        !@options[:stub_responses].nil? && @options[:stub_responses] != false
      end

      # The gem's ClientStubs#stub_responses.
      def stub_responses(operation_name, *stubs)
        unless stub_responses?
          raise 'stubbing is not enabled; enable stubbing in the constructor '\
                'with `:stub_responses => true`'
        end
        list = []
        stubs.flatten.each { |stub| list << Stub.new(stub) }
        @stubs[operation_name.to_sym] = list
      end

      private

      # The gem's ClientStubs#next_stub: none gives nil (the operation's
      # default data), one is used every time, more are used in order and
      # the last one stays.
      def next_stub(operation_name)
        list = @stubs[operation_name]
        return nil if list.nil? || list.empty?
        return list.first if list.length == 1

        list.shift
      end

      def request_context(body)
        Context.new(body, endpoint, @retries)
      end

      # The body XML of a raw HTTP stub, or the error it describes.
      def stub_xml(stub, body)
        raise ErrorResponse.new(stub.error_code, request_context(body), STUB_ERROR_MESSAGE) if stub.error?

        xml_or_error(stub.status_code.to_i, stub.body.to_s, body)
      end

      # Sends the query body, signed unless the operation is unauthenticated,
      # retrying as the gem's legacy handler (the default) or standard handler
      # does, and returns the 2xx body or raises the last error.
      def send_query(body, signed = true)
        @retries = 0
        capacity = nil
        loop do
          url = endpoint
          status, xml, date, network_error = transmit(body, url, signed)
          server_time = Retries.server_time(date)
          if network_error.nil? && status >= 200 && status < 300
            @retry_quota.release(capacity) if @retry_mode == 'standard'
            return xml
          end

          code, message = network_error ? [nil, nil] : error_code_and_message(status, xml)
          name = network_error ? 'Seahorse::Client::NetworkingError' : Runtime.error_constant(code)
          failure = Retries::Failure.new(name, status, !network_error.nil?, server_time)
          refreshable = !@credentials.nil? && @credentials.respond_to?(:refresh!)
          if @retry_mode == 'standard'
            @clock_skew.update_clock_correction(url, server_time) if failure.clock_skew?
            @clock_skew.update_estimated_skew(url, server_time)
            retry_now = failure.retryable?(refreshable) && @retries < @max_attempts - 1
            if retry_now
              capacity = @retry_quota.checkout_capacity(failure)
              retry_now = capacity > 0
            end
            Runtime.sleep(Kernel.rand * [2**@retries, 20].min) if retry_now
          else
            retry_now = failure.retryable?(refreshable) && @retries < @retry_limit
            Runtime.sleep(2**@retries * @retry_base_delay) if retry_now
          end
          unless retry_now
            raise Seahorse::Client::NetworkingError.new(network_error) if network_error

            raise ErrorResponse.new(code, request_context(body), message)
          end

          @retries += 1
          @credentials.refresh! if failure.expired_credentials? && refreshable
        end
      end

      # One POST: [status, body, Date header, networking error].
      def transmit(body, url, signed)
        uri = URI.parse(url)
        headers = {
          'content-type' => CONTENT_TYPE,
          'amz-sdk-invocation-id' => SecureRandom.uuid
        }
        headers['amz-sdk-request'] = sdk_request_header(url) if @retry_mode == 'standard'
        skew = @correct_clock_skew ? @clock_skew.clock_correction(url) : 0
        headers['x-amz-date'] = (Time.now.utc + skew).strftime('%Y%m%dT%H%M%SZ') if skew != 0
        request = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
        headers.each { |name, value| request[name] = value }
        if signed
          raise Aws::Errors::MissingCredentialsError if @credentials.nil?

          signer = Aws::Sigv4::Signer.new(service: @signing_name, region: @region,
                                          credentials_provider: @credentials)
          signature = signer.sign_request(http_method: 'POST', url: url, headers: headers, body: body)
          signature.headers.each { |name, value| request[name] = value unless name == 'host' }
        end
        request['user-agent'] = USER_AGENT
        request['accept-encoding'] = ''
        request['accept'] = '*/*'
        request.body = body

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = @options[:http_open_timeout] || 15
        http.read_timeout = @http_read_timeout
        begin
          # One request per session, opened and closed here.
          http.start
          begin
            response = http.request(request)
          ensure
            http.finish
          end
        # The gem's Seahorse::Client::NetHttp::Handler::NETWORK_ERRORS;
        # SocketError (a failed DNS lookup) is matched by name.
        rescue EOFError, IOError, Timeout::Error,
               Errno::ECONNABORTED, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL,
               Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ECONNREFUSED,
               OpenSSL::SSL::SSLError => e
          return [0, '', nil, e]
        rescue StandardError => e
          raise unless %w[SocketError Socket::ResolutionError].include?(e.class.name)

          return [0, '', nil, e]
        end
        [response.code.to_i, response.body.to_s, response['date'], nil]
      end

      # The gem's standard handler header: the attempt, the maximum, and a
      # deadline once the endpoint's clock skew has been estimated.
      def sdk_request_header(url)
        header = "attempt=#{@retries + 1}; max=#{@max_attempts}"
        skew = @clock_skew.estimated_skew(url)
        unless skew.nil?
          header += "; ttl=#{(Time.now.utc + @http_read_timeout + skew).strftime('%Y%m%dT%H%M%SZ')}"
        end
        header
      end

      # A 2xx body, or the query protocol's <ErrorResponse> as an error.
      def xml_or_error(status, xml, body)
        return xml if status >= 200 && status < 300

        code, message = error_code_and_message(status, xml)
        raise ErrorResponse.new(code, request_context(body), message)
      end

      def error_code_and_message(status, xml)
        error = Xml.parse(xml)
        detail = error.nil? ? nil : error.child('Error')
        code = Xml.text(detail.nil? ? nil : detail.child('Code')) || "Http#{status}Error"
        [code, Xml.text(detail.nil? ? nil : detail.child('Message'))]
      end

      # The gem's RetryErrors resolution: the option, then the environment,
      # then the shared config, then the default. Options the package does not
      # carry raise rather than be ignored.
      def resolve_retries
        %i[retry_jitter retry_backoff retry_max_delay adaptive_retry_wait_to_fill].each do |name|
          raise NotImplementedError, "the :#{name} option is not supported" unless @options[name].nil?
        end
        if ENV.fetch('AWS_NEW_RETRIES_2026', 'false').downcase == 'true'
          raise NotImplementedError, 'AWS_NEW_RETRIES_2026 is not supported'
        end

        @retry_mode = @options[:retry_mode] || resolve_retry_mode
        raise NotImplementedError, 'the adaptive retry mode is not supported' if @retry_mode == 'adaptive'

        @max_attempts = @options[:max_attempts] || resolve_max_attempts
        @retry_limit = @options[:retry_limit] || 3
        @retry_base_delay = @options[:retry_base_delay] || 0.3
        @correct_clock_skew = @options[:correct_clock_skew].nil? ? resolve_correct_clock_skew : @options[:correct_clock_skew]
        @http_read_timeout = @options[:http_read_timeout] || 60
        @retry_quota = Retries::Quota.new
        @clock_skew = Retries::ClockSkew.new
      end

      def resolve_retry_mode
        value = ENV['AWS_RETRY_MODE'] || Aws.shared_config.retry_mode(profile: @options[:profile]) || 'legacy'
        if value != 'legacy' && value != 'standard' && value != 'adaptive'
          raise ArgumentError,
                'Must provide either `legacy`, `standard`, or `adaptive` for '\
                'retry_mode profile option or for ENV[\'AWS_RETRY_MODE\']'
        end
        value
      end

      def resolve_max_attempts
        value = ENV['AWS_MAX_ATTEMPTS'] || Aws.shared_config.max_attempts(profile: @options[:profile])
        return 3 if value.nil?

        value = value.to_i
        if value <= 0
          raise ArgumentError,
                'Must provide a positive integer for max_attempts profile '\
                'option or for ENV[\'AWS_MAX_ATTEMPTS\']'
        end
        value
      end

      def resolve_correct_clock_skew
        value = ENV['AWS_CORRECT_CLOCK_SKEW'] ||
                Aws.shared_config.correct_clock_skew(profile: @options[:profile]) || 'true'
        if value != 'true' && value != 'false'
          raise ArgumentError,
                'Must provide either `true` or `false` for '\
                'correct_clock_skew profile option or for '\
                'ENV[\'AWS_CORRECT_CLOCK_SKEW\']'
        end
        value == 'true'
      end
    end
  end
end

module Seahorse
  module Client
    # The gem's response delegates to its data through Delegator; here each
    # generated operation subclasses it with one reader per member.
    class Response
      attr_reader :data, :context
      attr_accessor :error

      def initialize(data, context)
        @data = data
        @error = nil
        @context = context
      end

      def successful? = @error.nil?
    end
  end
end
