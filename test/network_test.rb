# Aws::STS::Client over HTTP against a local server: the request the client
# sends (headers, signature, body), the response it reads, an error
# response, where the region and credentials come from, and the regional
# endpoints.
require "socket"
require "openssl"
require "aws-sdk-core"

ENV["AWS_CONFIG_FILE"] = __dir__ + "/fixtures/no-such-config"
ENV["AWS_SHARED_CREDENTIALS_FILE"] = __dir__ + "/fixtures/no-such-credentials"
%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
   AWS_REGION AMAZON_REGION AWS_DEFAULT_REGION].each { |name| ENV.delete(name) }

IDENTITY = "<GetCallerIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\">" \
           "<GetCallerIdentityResult><Arn>arn:aws:iam::123456789012:user/ari</Arn>" \
           "<UserId>AIDAEXAMPLE</UserId><Account>123456789012</Account></GetCallerIdentityResult>" \
           "<ResponseMetadata><RequestId>req-1</RequestId></ResponseMetadata></GetCallerIdentityResponse>"
DENIED = "<ErrorResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><Error><Type>Sender</Type>" \
         "<Code>AccessDenied</Code><Message>not authorized</Message></Error><RequestId>req-2</RequestId></ErrorResponse>"

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
replies = [[200, IDENTITY], [403, DENIED], [200, IDENTITY], [200, IDENTITY]]
requests = []
thread = Thread.new do
  replies.each do |status, reply|
    conn = server.accept
    line = conn.gets.strip
    headers = {}
    while (h = conn.gets) && h != "\r\n"
      name, value = h.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = conn.read(headers["content-length"].to_i)
    requests << [line, headers, body]
    reason = status == 200 ? "OK" : "Forbidden"
    conn.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: text/xml\r\n" \
               "Content-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
    conn.close
  end
end

def describe(label, request, port)
  line, headers, body = request
  puts "#{label}: #{line}"
  # user-agent names the SDK build; connection is how each transport keeps
  # (or closes) the socket. Neither is part of the request the service reads.
  puts "  headers: #{(headers.keys - ["user-agent", "connection"]).sort.join(" ")}"
  puts "  content-type: #{headers["content-type"]}"
  puts "  accept-encoding: #{headers["accept-encoding"].inspect}"
  puts "  host: #{headers["host"] == "127.0.0.1:#{port}"}"
  puts "  invocation id: #{headers["amz-sdk-invocation-id"].match?(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/)}"
  puts "  date: #{headers["x-amz-date"].match?(/\A\d{8}T\d{6}Z\z/)}"
  puts "  content sha256: #{headers["x-amz-content-sha256"] == OpenSSL::Digest::SHA256.hexdigest(body)}"
  puts "  authorization: #{headers["authorization"].sub(/\d{8}/, "DATE").sub(/Signature=\h{64}/, "Signature=SIG")}"
  puts "  body: #{body}"
end

def signature_valid?(request, port, key, secret, region)
  _line, headers, body = request
  signed = headers.reject { |name, _| %w[authorization user-agent accept-encoding accept content-length connection].include?(name) }
  signer = Aws::Sigv4::Signer.new(service: "sts", region: region, access_key_id: key, secret_access_key: secret)
  signer.sign_request(http_method: "POST", url: "http://127.0.0.1:#{port}/", headers: signed,
                      body: body).headers["authorization"] == headers["authorization"]
end

endpoint = "http://127.0.0.1:#{port}"
sts = Aws::STS::Client.new(region: "sa-east-1", endpoint: endpoint,
                           credentials: Aws::Credentials.new("AKID", "SECRET"))
resp = sts.get_caller_identity
puts "account: #{resp.account} #{resp.arn} #{resp.user_id}"
puts "endpoint: #{resp.context.http_request.endpoint.to_s.sub(port.to_s, "PORT")}"

begin
  sts.get_caller_identity
rescue Aws::Errors::ServiceError => e
  puts "error: #{e.class} #{e.code} #{e.message}"
end

ENV["AWS_REGION"] = "eu-west-1"
by_option_keys = Aws::STS::Client.new(endpoint: endpoint, access_key_id: "AKIDOPT", secret_access_key: "SECRETOPT")
by_option_keys.get_caller_identity

ENV["AWS_ACCESS_KEY_ID"] = "AKIDENV"
ENV["AWS_SECRET_ACCESS_KEY"] = "SECRETENV"
Aws::STS::Client.new(endpoint: endpoint).get_caller_identity
thread.join

describe("first", requests[0], port)
puts "  signature valid: #{signature_valid?(requests[0], port, "AKID", "SECRET", "sa-east-1")}"
puts "error request: #{requests[1][0]} #{requests[1][2]}"
puts "env region: #{requests[2][1]["authorization"].sub(/\d{8}/, "DATE")[/Credential=[^,]+/]}"
puts "  signature valid: #{signature_valid?(requests[2], port, "AKIDOPT", "SECRETOPT", "eu-west-1")}"
puts "env credentials: #{requests[3][1]["authorization"].sub(/\d{8}/, "DATE")[/Credential=[^,]+/]}"
puts "  signature valid: #{signature_valid?(requests[3], port, "AKIDENV", "SECRETENV", "eu-west-1")}"

%w[us-east-1 sa-east-1 cn-north-1 us-gov-west-1 us-iso-east-1 us-isob-east-1
   eu-isoe-west-1 us-isof-south-1 eusc-de-east-1 aws-global].each do |region|
  client = Aws::STS::Client.new(region: region, stub_responses: true)
  puts "#{region}: #{client.get_caller_identity.context.http_request.endpoint}"
end

ENV.delete("AWS_REGION")
begin
  Aws::STS::Client.new(credentials: Aws::Credentials.new("A", "B"))
rescue Aws::Errors::MissingRegionError => e
  puts "no region: #{e.message}"
end
