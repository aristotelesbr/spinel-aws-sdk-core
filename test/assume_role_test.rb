# AssumeRoleCredentials and AssumeRoleWebIdentityCredentials calling STS on a
# local server: the request each one sends (AssumeRole signed with the base
# credentials, AssumeRoleWithWebIdentity unsigned), the credentials they
# build, the account taken from the role ARN, a refresh near expiration, an
# error while assuming, and a stubbed client passed in.
require "socket"
require "aws-sdk-core"

ENV["AWS_CONFIG_FILE"] = __dir__ + "/fixtures/no-such-config"
ENV["AWS_SHARED_CREDENTIALS_FILE"] = __dir__ + "/fixtures/no-such-credentials"
%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION
   AWS_RETRY_MODE AWS_MAX_ATTEMPTS].each { |name| ENV.delete(name) }

def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

def assumed(action, key, expiration)
  "<#{action}Response><#{action}Result><Credentials><AccessKeyId>#{key}</AccessKeyId>" \
    "<SecretAccessKey>secret-#{key}</SecretAccessKey><SessionToken>token-#{key}</SessionToken>" \
    "<Expiration>#{iso(expiration)}</Expiration></Credentials><AssumedRoleUser>" \
    "<AssumedRoleId>AROAEXAMPLE:app</AssumedRoleId><Arn>arn:aws:sts::123456789012:assumed-role/app/app</Arn>" \
    "</AssumedRoleUser><PackedPolicySize>6</PackedPolicySize></#{action}Result></#{action}Response>"
end

later = Time.now + 3600
soon = Time.now + 120
denied = "<ErrorResponse><Error><Type>Sender</Type><Code>AccessDenied</Code>" \
         "<Message>not allowed to assume</Message></Error></ErrorResponse>"
replies = [
  [200, assumed("AssumeRole", "ASIAONE", later)],
  [200, assumed("AssumeRole", "ASIASOON", soon)],
  [200, assumed("AssumeRole", "ASIAAGAIN", later)],
  [200, assumed("AssumeRoleWithWebIdentity", "ASIAWEB", later)],
  [403, denied],
]

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
requests = []
thread = Thread.new do
  replies.each do |status, reply|
    conn = server.accept
    conn.gets
    headers = {}
    while (h = conn.gets) && h != "\r\n"
      name, value = h.split(":", 2)
      headers[name.downcase] = value.strip
    end
    requests << [headers, conn.read(headers["content-length"].to_i)]
    conn.write("HTTP/1.1 #{status} X\r\nContent-Type: text/xml\r\n" \
               "Content-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
    conn.close
  end
end

endpoint = "http://127.0.0.1:#{port}"
base = Aws::Credentials.new("AKIDBASE", "SECRETBASE")
role = Aws::AssumeRoleCredentials.new(role_arn: "arn:aws:iam::123456789012:role/app",
                                      role_session_name: "app", duration_seconds: 900,
                                      region: "us-east-1", endpoint: endpoint, credentials: base)
creds = role.credentials
puts "assume role: #{creds.access_key_id} #{creds.secret_access_key} #{creds.session_token} #{creds.account_id}"
puts "  expiration: #{role.expiration.class} #{role.expiration.to_i == later.to_i}"
puts "  set: #{role.set?}"

soon_role = Aws::AssumeRoleCredentials.new(role_arn: "arn:aws:iam::123456789012:role/app",
                                           role_session_name: "app", region: "us-east-1",
                                           endpoint: endpoint, credentials: base)
puts "near expiration: #{soon_role.credentials.access_key_id}"

token_file = __dir__ + "/fixtures/web-identity-token"
web = Aws::AssumeRoleWebIdentityCredentials.new(role_arn: "arn:aws:iam::123456789012:role/web",
                                                web_identity_token_file: token_file,
                                                role_session_name: "web", region: "us-east-1",
                                                endpoint: endpoint)
puts "web identity: #{web.credentials.access_key_id} #{web.credentials.account_id}"

begin
  Aws::AssumeRoleCredentials.new(role_arn: "arn:aws:iam::123456789012:role/nope",
                                 role_session_name: "app", region: "us-east-1",
                                 endpoint: endpoint, credentials: base)
rescue Aws::Errors::ServiceError => e
  puts "denied: #{e.class} #{e.message}"
end
thread.join

requests.each_with_index do |(headers, body), i|
  auth = headers["authorization"]
  signed = auth.nil? ? "unsigned" : auth[/Credential=[^\/]+/]
  puts "request #{i + 1}: #{signed} #{body.sub(/WebIdentityToken=[^&]+/, "WebIdentityToken=TOKEN")}"
end

stubbed = Aws::STS::Client.new(stub_responses: {
  assume_role: { credentials: { access_key_id: "ASIASTUB", secret_access_key: "s", session_token: "t",
                                expiration: Time.utc(2030, 1, 2, 3, 4, 5) },
                 assumed_role_user: { assumed_role_id: "id", arn: "arn:aws:sts::210987654321:assumed-role/x/y" } }
})
from_stub = Aws::AssumeRoleCredentials.new(role_arn: "arn:aws:iam::210987654321:role/x",
                                           role_session_name: "y", client: stubbed)
puts "stubbed client: #{from_stub.credentials.access_key_id} #{from_stub.credentials.account_id} #{from_stub.expiration.utc}"
