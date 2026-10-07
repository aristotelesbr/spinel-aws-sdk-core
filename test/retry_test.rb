# Retries against a local server: the legacy mode (the gem's default) and
# the standard mode, which errors each one retries, the delays it waits, the
# amz-sdk-request header, clock skew correction, networking errors and how
# the mode and attempts are configured. Sleeping is intercepted, and the
# standard mode's random factor is fixed at 0.5.
require "socket"
require "aws-sdk-core"

$sleeps = []
module Kernel
  def self.sleep(seconds)
    $sleeps << seconds
    0
  end

  def self.rand(*_args)
    0.5
  end
end

# The package waits through Aws::Runtime.sleep; the gem calls Kernel.sleep.
module Aws
  module Runtime
    def self.sleep(seconds)
      $sleeps << seconds
      0
    end
  end
end

ENV["AWS_CONFIG_FILE"] = __dir__ + "/fixtures/no-such-config"
ENV["AWS_SHARED_CREDENTIALS_FILE"] = __dir__ + "/fixtures/no-such-credentials"
%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION
   AWS_RETRY_MODE AWS_MAX_ATTEMPTS AWS_CORRECT_CLOCK_SKEW].each { |name| ENV.delete(name) }

def error_xml(code)
  "<ErrorResponse><Error><Type>Sender</Type><Code>#{code}</Code><Message>#{code} happened</Message></Error></ErrorResponse>"
end

OK = "<GetCallerIdentityResponse><GetCallerIdentityResult><Account>123456789012</Account>" \
     "</GetCallerIdentityResult></GetCallerIdentityResponse>"
MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
DAYS = %w[Sun Mon Tue Wed Thu Fri Sat].freeze

def http_date(time)
  t = time.utc
  format("%s, %02d %s %04d %02d:%02d:%02d GMT", DAYS[t.wday], t.day, MONTHS[t.month - 1], t.year, t.hour, t.min, t.sec)
end

# Each reply: [status, body, date header or nil].
fail500 = [500, error_xml("InternalFailure"), nil]
ahead = http_date(Time.now + 3600)
skewed = [400, error_xml("SignatureDoesNotMatch"), ahead]
replies = [
  fail500, fail500, fail500, fail500,                 # legacy: 4 calls, all fail
  fail500, [200, OK, nil],                            # legacy: fails once, then succeeds
  [403, error_xml("AccessDenied"), nil],              # legacy: not retried
  [400, error_xml("Throttling"), nil], [200, OK, nil], # legacy: throttling retried
  fail500, fail500,                                   # legacy, retry_limit 1: 2 calls
  fail500, fail500, fail500,                          # standard: 3 calls
  fail500, fail500, fail500, fail500, [200, OK, nil], # standard, AWS_MAX_ATTEMPTS=5
  skewed, [200, OK, nil],                             # legacy: skew retried, not corrected
  skewed, [200, OK, nil],                             # standard: skew corrected
]

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
requests = []
thread = Thread.new do
  replies.each do |status, reply, date|
    conn = server.accept
    conn.gets
    headers = {}
    while (h = conn.gets) && h != "\r\n"
      name, value = h.split(":", 2)
      headers[name.downcase] = value.strip
    end
    conn.read(headers["content-length"].to_i)
    requests << headers
    extra = date ? "Date: #{date}\r\n" : ""
    conn.write("HTTP/1.1 #{status} X\r\nContent-Type: text/xml\r\n#{extra}" \
               "Content-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
    conn.close
  end
end

def client(port, options = {})
  Aws::STS::Client.new({ region: "us-east-1", endpoint: "http://127.0.0.1:#{port}",
                         credentials: Aws::Credentials.new("AKID", "SECRET") }.merge(options))
end

def call(label, sts, requests)
  $sleeps.clear
  result = begin
    "ok #{sts.get_caller_identity.account}"
  rescue Aws::Errors::ServiceError => e
    "#{e.class} #{e.code}"
  end
  puts "#{label}: #{result}; sleeps #{$sleeps.inspect}"
end

call("legacy 500", client(port), requests)
call("legacy 500 then ok", client(port), requests)
call("legacy denied", client(port), requests)
call("legacy throttling", client(port), requests)
call("legacy retry_limit 1", client(port, retry_limit: 1), requests)
first_standard = requests.size
call("standard 500", client(port, retry_mode: "standard"), requests)
puts "  headers: #{requests[first_standard, 3].map { |h| h["amz-sdk-request"] }.inspect}"
ENV["AWS_MAX_ATTEMPTS"] = "5"
call("standard max 5", client(port, retry_mode: "standard"), requests)
ENV.delete("AWS_MAX_ATTEMPTS")
puts "  legacy header: #{requests[0]["amz-sdk-request"].inspect}"

def amz_time(s) = Time.utc(s[0, 4].to_i, s[4, 2].to_i, s[6, 2].to_i, s[9, 2].to_i, s[11, 2].to_i, s[13, 2].to_i)

# How far the retry's X-Amz-Date moved from the first attempt's, in seconds.
def date_shift(requests, start)
  (amz_time(requests[start + 1]["x-amz-date"]) - amz_time(requests[start]["x-amz-date"])).to_i
end

skew_start = requests.size
call("legacy skew", client(port), requests)
puts "  legacy corrected: #{date_shift(requests, skew_start) > 3000}"
skew_start = requests.size
call("standard skew", client(port, retry_mode: "standard"), requests)
puts "  standard corrected: #{date_shift(requests, skew_start) > 3000}"
thread.join

closed = TCPServer.new("127.0.0.1", 0)
closed_port = closed.addr[1]
closed.close
$sleeps.clear
begin
  client(closed_port).get_caller_identity
rescue StandardError => e
  puts "networking: #{e.class}; sleeps #{$sleeps.inspect}"
end

ENV["AWS_RETRY_MODE"] = "sometimes"
begin
  client(port)
rescue ArgumentError => e
  puts "bad mode: #{e.message}"
end
ENV.delete("AWS_RETRY_MODE")
