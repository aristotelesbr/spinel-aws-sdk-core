# frozen_string_literal: true

require 'stringio'
require 'uri'
require 'net/http'
require 'securerandom'
require 'aws-sigv4'

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

      def initialize(options, endpoint_prefix, signing_name)
        @options = options
        @endpoint_prefix = endpoint_prefix
        @signing_name = signing_name
        @retries = 0
        @stubs = {}
        stubs = options[:stub_responses]
        if stubs.is_a?(Hash)
          stubs.each { |operation, given| stub_responses(operation, given) }
        end
        @region = resolve_region
        @credentials = resolve_credentials
      end

      # The gem's RegionalEndpoint#resolve_region: the option, then
      # AWS_REGION, AMAZON_REGION and AWS_DEFAULT_REGION, then the shared
      # config. With stub_responses and no region, the gem's 'us-stubbed-1'.
      def resolve_region
        region = @options[:region]
        region = ENV.values_at('AWS_REGION', 'AMAZON_REGION', 'AWS_DEFAULT_REGION').compact.first if region.nil?
        region = nil if region == ''
        region = Aws.shared_config.region(profile: @options[:profile]) if region.nil?
        region = 'us-stubbed-1' if region.nil? && stub_responses?
        raise Aws::Errors::MissingRegionError if region.nil? || region == ''

        region
      end

      # The gem's CredentialsConfiguration: the :credentials option, then
      # :access_key_id and :secret_access_key, then the provider chain. With
      # stub_responses, the gem's stubbed credentials.
      def resolve_credentials
        return @options[:credentials] if @options[:credentials]
        if @options[:access_key_id]
          return Aws::Credentials.new(@options[:access_key_id], @options[:secret_access_key], @options[:session_token])
        end
        return Aws::Credentials.new('stubbed-akid', 'stubbed-secret') if stub_responses?

        Aws::CredentialProviderChain.new.resolve
      end

      # The :endpoint option, or the service's regional endpoint as the
      # gem's endpoint rules build it.
      def endpoint
        return @options[:endpoint].to_s if @options[:endpoint]
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

      # Signs the query body with aws-sigv4 and POSTs it to the endpoint, with
      # the headers the gem sends.
      def send_query(body)
        url = endpoint
        uri = URI.parse(url)
        headers = {
          'content-type' => CONTENT_TYPE,
          'amz-sdk-invocation-id' => SecureRandom.uuid
        }
        signer = Aws::Sigv4::Signer.new(service: @signing_name, region: @region,
                                        credentials_provider: @credentials)
        signature = signer.sign_request(http_method: 'POST', url: url, headers: headers, body: body)

        request = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
        headers.each { |name, value| request[name] = value }
        signature.headers.each { |name, value| request[name] = value unless name == 'host' }
        request['user-agent'] = USER_AGENT
        request['accept-encoding'] = ''
        request['accept'] = '*/*'
        request.body = body

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = @options[:http_open_timeout] || 15
        http.read_timeout = @options[:http_read_timeout] || 60
        # One request per session, opened and closed here.
        http.start
        begin
          response = http.request(request)
        ensure
          http.finish
        end
        xml_or_error(response.code.to_i, response.body.to_s, body)
      end

      # A 2xx body, or the query protocol's <ErrorResponse> as an error.
      def xml_or_error(status, xml, body)
        return xml if status >= 200 && status < 300

        error = Xml.parse(xml)
        detail = error.nil? ? nil : error.child('Error')
        code = Xml.text(detail.nil? ? nil : detail.child('Code')) || "Http#{status}Error"
        message = Xml.text(detail.nil? ? nil : detail.child('Message'))
        raise ErrorResponse.new(code, request_context(body), message)
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
