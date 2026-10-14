# frozen_string_literal: true

require 'json'

# spinel-aws-sdk-core: written for the package. The value rules of the gem's
# Aws::Json::Builder and Aws::Json::Parser, and the error code and message of
# Aws::Json::ErrorHandler, as functions the generated JSON-protocol code calls
# member by member.
module Aws
  module Runtime
    module Json
      # Json::Parser keeps a string as it came; each reader here returns one
      # type, so what JSON.parse returns stops at the generated parser.
      def self.string(value)
        value.nil? ? nil : value.to_s
      end

      def self.integer(value)
        value.nil? ? nil : value.to_i
      end

      def self.float(value)
        value.nil? ? nil : value.to_f
      end

      # Json::Parser: value.to_s == 'true'.
      def self.boolean(value)
        value.nil? ? nil : value.to_s == 'true'
      end

      # Json::Parser#time: a number is Time.at (local time); a String is the
      # gem's Util.deserialize_time, here only its epoch and ISO 8601 forms.
      def self.timestamp(value)
        return nil if value.nil?
        return Time.at(value.to_f) unless value.is_a?(String)

        t = value.to_s
        return Time.at(t.to_f).utc if t.match?(/\A[\d.]+\z/)

        Time.utc(t[0, 4].to_i, t[5, 2].to_i, t[8, 2].to_i, t[11, 2].to_i, t[14, 2].to_i, t[17, 2].to_i)
      end

      # Json::Parser: Base64.decode64.
      def self.unblob(value)
        value.nil? ? nil : value.to_s.unpack1('m')
      end

      # The gem's Util.serialize_epoch_seconds: whole seconds as an Integer,
      # otherwise seconds with milliseconds as a Float.
      def self.epoch(time)
        return time.to_i if time.nsec.zero?

        time.to_i + time.nsec / 1_000_000 / 1000.0
      end

      # Json::Builder: Base64.strict_encode64.
      def self.blob(value)
        [value.to_s].pack('m0')
      end

      # Json::Parser#structure: in a union, a key the model does not list
      # (other than __type) is kept as {"name" => key, "value" => value},
      # the last such key winning.
      def self.union_unknown(value, known)
        unknown = nil
        value.each do |key, item|
          unknown = { 'name' => key.to_s, 'value' => item } unless known.include?(key.to_s) || key.to_s == '__type'
        end
        unknown
      end

      # Json::ErrorHandler#extract_error: the code from __type, then code,
      # then the x-amzn-errortype header, cut at '#' and ':'
      # ("com.amazonaws.ssm#ParameterNotFound" is ParameterNotFound), else
      # Http<status>Error; the message from message, then Message, else ''.
      # A body that is not JSON gives Http<status>Error and ''.
      def self.error_code_and_message(status, body, error_type)
        fallback = "Http#{status}Error"
        begin
          json = JSON.parse(body)
        rescue JSON::ParserError
          return [fallback, '']
        end
        return [fallback, ''] unless json.is_a?(Hash)

        code = json['__type']
        code = json['code'] if code.nil?
        code = error_type if code.nil?
        code = code.nil? ? fallback : code.to_s.split('#').last.split(':').first
        message = json['message']
        message = json['Message'] if message.nil?
        message = json['error_description'] if message.nil?
        message = 'Request body must be less than 1 MB' if code == 'RequestEntityTooLarge'
        [code, message.nil? ? '' : message.to_s]
      end
    end
  end
end
