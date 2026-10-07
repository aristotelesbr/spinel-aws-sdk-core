# Aws::STS::Client with stub_responses: default data, data from a Hash, a
# sequence, an error code, a raw HTTP response (success and error XML), and
# the request body each call serializes.
require "aws-sdk-core"

sts = Aws::STS::Client.new(stub_responses: true)

resp = sts.get_caller_identity
puts "default: #{resp.account} #{resp.arn} #{resp.user_id}"
puts "data: #{resp.data.class} #{resp.data.to_h}"
puts "successful: #{resp.successful?} #{resp.error.inspect}"

role = sts.assume_role(role_arn: "arn:aws:iam::123456789012:role/app", role_session_name: "app")
puts "assume_role: #{role.credentials.access_key_id} #{role.credentials.expiration.class} #{role.packed_policy_size}"
puts "user: #{role.assumed_role_user.arn}"

sts.stub_responses(:get_caller_identity, { account: "123456789012", arn: "arn:aws:iam::123456789012:user/ari" })
resp = sts.get_caller_identity
puts "hash: #{resp.account} #{resp.arn} #{resp.user_id.inspect}"

sts.stub_responses(:get_caller_identity, { account: "111" }, { account: "222" })
puts "sequence: #{sts.get_caller_identity.account} #{sts.get_caller_identity.account} #{sts.get_caller_identity.account}"

sts.stub_responses(:get_caller_identity, "ExpiredTokenException")
begin
  sts.get_caller_identity
rescue Aws::STS::Errors::ServiceError => e
  puts "error: #{e.class} #{e.code} #{e.message}"
end

sts.stub_responses(:get_caller_identity, "SomethingNew")
begin
  sts.get_caller_identity
rescue Aws::Errors::ServiceError => e
  puts "unknown error: #{e.code} #{e.message}"
end

xml = <<~XML
  <GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
    <GetCallerIdentityResult>
      <Arn>arn:aws:iam::123456789012:user/ari</Arn>
      <UserId>AIDAEXAMPLE</UserId>
      <Account>123456789012</Account>
    </GetCallerIdentityResult>
    <ResponseMetadata><RequestId>01234567-89ab-cdef-0123-456789abcdef</RequestId></ResponseMetadata>
  </GetCallerIdentityResponse>
XML
sts.stub_responses(:get_caller_identity, { status_code: 200, headers: {}, body: xml })
resp = sts.get_caller_identity
puts "xml: #{resp.account} #{resp.arn} #{resp.user_id}"

error_xml = <<~XML
  <ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
    <Error><Type>Sender</Type><Code>AccessDenied</Code><Message>User is not authorized &amp; denied</Message></Error>
    <RequestId>01234567-89ab-cdef-0123-456789abcdef</RequestId>
  </ErrorResponse>
XML
sts.stub_responses(:get_caller_identity, { status_code: 403, headers: {}, body: error_xml })
begin
  sts.get_caller_identity
rescue Aws::Errors::ServiceError => e
  puts "xml error: #{e.code} #{e.message}"
end

role = sts.assume_role(role_arn: "arn:aws:iam::123456789012:role/app", role_session_name: "app",
                       duration_seconds: 900, policy_arns: [{ arn: "arn:a" }, { arn: "arn:b" }],
                       tags: [{ key: "team", value: "core" }])
puts "body: #{role.context.http_request.body.read}"
