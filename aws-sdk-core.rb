# frozen_string_literal: true

# spinel-aws-sdk-core: the gem's aws-sdk-core.rb autoloads every part and
# loads Seahorse, aws-partitions and jmespath. This entry requires only the
# parts the package carries, in an order where each one's dependencies come
# first, and keeps the gem's Aws.shared_config.
require_relative 'aws-sdk-core/errors'
require_relative 'aws-sdk-core/credential_provider'
require_relative 'aws-sdk-core/refreshing_credentials'
require_relative 'aws-sdk-core/credentials'
require_relative 'aws-sdk-core/ini_parser'
require_relative 'aws-sdk-core/shared_credentials'
require_relative 'aws-sdk-core/shared_config'
require_relative 'aws-sdk-core/assume_role_credentials'
require_relative 'aws-sdk-core/assume_role_web_identity_credentials'
require_relative 'aws-sdk-core/credential_provider_chain'
require_relative 'aws-sdk-core/runtime'

module Aws
  class << self

    # @api private
    def shared_config
      enabled = ENV["AWS_SDK_CONFIG_OPT_OUT"] ? false : true
      @shared_config ||= SharedConfig.new(config_enabled: enabled)
    end

  end
end

# aws-sdk-sts is included to support Aws::AssumeRoleCredentials
require_relative 'aws-sdk-sts'
