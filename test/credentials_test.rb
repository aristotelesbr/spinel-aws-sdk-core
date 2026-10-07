# Static credentials, the shared credentials and config files, and the
# provider chain resolving from them, read from test/fixtures.
require "aws-sdk-core"

ENV.delete("AWS_ACCESS_KEY_ID")
ENV.delete("AWS_SECRET_ACCESS_KEY")
ENV.delete("AWS_SESSION_TOKEN")
ENV.delete("AWS_PROFILE")
ENV.delete("AWS_REGION")
ENV.delete("AWS_DEFAULT_REGION")
ENV["AWS_SHARED_CREDENTIALS_FILE"] = __dir__ + "/fixtures/credentials"
ENV["AWS_CONFIG_FILE"] = __dir__ + "/fixtures/config"

static = Aws::Credentials.new("AKID", "SECRET", "TOKEN")
puts "static: #{static.set?} #{static.access_key_id} #{static.session_token}"
puts "empty: #{Aws::Credentials.new(nil, nil).set?}"

default = Aws::SharedCredentials.new
puts "default: #{default.profile_name} #{default.credentials.access_key_id} #{default.credentials.session_token.inspect}"
dev = Aws::SharedCredentials.new(profile_name: "dev")
puts "dev: #{dev.profile_name} #{dev.credentials.access_key_id} #{dev.credentials.session_token}"

config = Aws::SharedConfig.new(config_enabled: true)
puts "config: #{config.region} #{config.max_attempts} #{config.retry_mode}"
puts "dev config: #{config.region(profile: "dev")}"
puts "missing: #{config.sts_regional_endpoints.inspect}"

chain = Aws::CredentialProviderChain.new.resolve
puts "chain: #{chain.class} #{chain.credentials.access_key_id}"

ENV["AWS_ACCESS_KEY_ID"] = "AKIDENV"
ENV["AWS_SECRET_ACCESS_KEY"] = "SECRETENV"
env_chain = Aws::CredentialProviderChain.new.resolve
puts "env chain: #{env_chain.class} #{env_chain.credentials.access_key_id}"
