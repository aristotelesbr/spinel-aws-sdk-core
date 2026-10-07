# Configured endpoints: AWS_ENDPOINT_URL_STS, AWS_ENDPOINT_URL, a profile's
# endpoint_url and its services section, the :endpoint option over all of
# them, and AWS_IGNORE_CONFIGURED_ENDPOINT_URLS. Then, through
# AWS_ENDPOINT_URL_STS and a local server, the two credential paths that
# build their own STS client: a profile with role_arn and source_profile, and
# the AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE environment.
require "socket"
require "tmpdir"
require "aws-sdk-core"

%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION
   AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS AWS_IGNORE_CONFIGURED_ENDPOINT_URLS
   AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_SESSION_NAME
   AWS_RETRY_MODE AWS_MAX_ATTEMPTS].each { |name| ENV.delete(name) }

def assumed(action, key)
  "<#{action}Response><#{action}Result><Credentials><AccessKeyId>#{key}</AccessKeyId>" \
    "<SecretAccessKey>secret</SecretAccessKey><SessionToken>token</SessionToken>" \
    "<Expiration>2099-01-01T00:00:00Z</Expiration></Credentials><AssumedRoleUser>" \
    "<AssumedRoleId>AROAEXAMPLE:s</AssumedRoleId><Arn>arn:aws:sts::123456789012:assumed-role/app/s</Arn>" \
    "</AssumedRoleUser></#{action}Result></#{action}Response>"
end

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
replies = [assumed("AssumeRole", "ASIAPROFILE"), assumed("AssumeRoleWithWebIdentity", "ASIAEKS")]
requests = []
thread = Thread.new do
  replies.each do |reply|
    conn = server.accept
    line = conn.gets.strip
    headers = {}
    while (h = conn.gets) && h != "\r\n"
      name, value = h.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = conn.read(headers["content-length"].to_i)
    requests << [line, headers["authorization"].nil? ? "unsigned" : headers["authorization"][/Credential=[^\/]+/], body[/Action=\w+/]]
    conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\n" \
               "Content-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
    conn.close
  end
end

local = "http://127.0.0.1:#{port}"
dir = Dir.tmpdir + "/spinel-aws-endpoints-#{port}"
Dir.mkdir(dir) unless Dir.exist?(dir)
File.write(dir + "/config", <<~INI)
  [default]
  region = us-east-1
  endpoint_url = https://default.example.com

  [profile svc]
  region = us-east-1
  services = local

  [services local]
  sts =
    endpoint_url = https://sts-only.example.com

  [profile app]
  region = us-east-1
  role_arn = arn:aws:iam::123456789012:role/app
  source_profile = base
  role_session_name = from-profile
INI
File.write(dir + "/credentials", <<~INI)
  [base]
  aws_access_key_id = AKIDBASE
  aws_secret_access_key = SECRETBASE
INI
ENV["AWS_CONFIG_FILE"] = dir + "/config"
ENV["AWS_SHARED_CREDENTIALS_FILE"] = dir + "/credentials"

def endpoint_of(options = {})
  client = Aws::STS::Client.new({ stub_responses: true }.merge(options))
  client.get_caller_identity.context.http_request.endpoint.to_s
end

puts "profile endpoint_url: #{endpoint_of}"
puts "services section: #{endpoint_of(profile: "svc")}"
ENV["AWS_ENDPOINT_URL"] = "https://global.example.com"
puts "AWS_ENDPOINT_URL: #{endpoint_of}"
ENV["AWS_ENDPOINT_URL_STS"] = "https://sts-env.example.com"
puts "AWS_ENDPOINT_URL_STS: #{endpoint_of}"
puts ":endpoint option: #{endpoint_of(endpoint: "https://option.example.com")}"
ENV["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"] = "true"
puts "ignored: #{endpoint_of}"
ENV.delete("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS")
puts "ignored by option: #{endpoint_of(ignore_configured_endpoint_urls: true)}"
ENV.delete("AWS_ENDPOINT_URL")

ENV["AWS_ENDPOINT_URL_STS"] = local
ENV["AWS_REGION"] = "us-east-1"
ENV["AWS_PROFILE"] = "app"
profile_creds = Aws::CredentialProviderChain.new.resolve
puts "profile role: #{profile_creds.class} #{profile_creds.credentials.access_key_id}"
ENV.delete("AWS_PROFILE")

ENV["AWS_ROLE_ARN"] = "arn:aws:iam::123456789012:role/eks"
ENV["AWS_WEB_IDENTITY_TOKEN_FILE"] = __dir__ + "/fixtures/web-identity-token"
ENV["AWS_ROLE_SESSION_NAME"] = "pod"
eks_creds = Aws::CredentialProviderChain.new.resolve
puts "eks: #{eks_creds.class} #{eks_creds.credentials.access_key_id}"
thread.join

requests.each { |line, auth, action| puts "request: #{line} #{auth} #{action}" }
File.delete(dir + "/config")
File.delete(dir + "/credentials")
Dir.rmdir(dir)
