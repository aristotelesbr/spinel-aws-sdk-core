# frozen_string_literal: true

# spinel-aws-sdk-core: written for the package. The retry rules of the gem's
# Aws::Plugins::RetryErrors (its legacy and standard handlers) and of
# Aws::Plugins::Retries (ErrorInspector, RetryQuota, ClockSkew), as plain
# objects the runtime's send loop calls.
module Aws
  module Runtime
    # The gem's Kernel.sleep in the retry backoff, in one place a test can
    # replace.
    def self.sleep(seconds)
      Kernel.sleep(seconds)
    end

    module Retries
      # The gem's Retries::ErrorInspector code sets.
      EXPIRED_CREDS = %w[
        InvalidClientTokenId UnrecognizedClientException InvalidAccessKeyId
        AuthFailure InvalidIdentityToken ExpiredToken ExpiredTokenException
      ].freeze
      THROTTLING_ERRORS = %w[
        Throttling ThrottlingException ThrottledException RequestThrottled
        RequestThrottledException ProvisionedThroughputExceededException
        TransactionInProgressException RequestLimitExceeded
        BandwidthLimitExceeded LimitExceededException TooManyRequestsException
        PriorRequestNotComplete SlowDown EC2ThrottledException
      ].freeze
      CHECKSUM_ERRORS = %w[CRC32CheckFailed BadDigest].freeze
      NETWORKING_ERRORS = %w[
        RequestTimeout InternalError RequestTimeoutException IDPCommunicationError
      ].freeze
      CLOCK_SKEW_ERRORS = %w[
        RequestTimeTooSkewed RequestExpired InvalidSignatureException
        SignatureDoesNotMatch AuthFailure RequestInTheFuture
      ].freeze

      # One failed attempt, as the gem's ErrorInspector sees it: a service
      # error (by its class's code) with an HTTP status, or a networking
      # error.
      class Failure
        attr_reader :name, :status, :server_time

        def initialize(name, status, networking, server_time)
          @name = name
          @status = status
          @networking = networking
          @server_time = server_time
        end

        def expired_credentials?
          EXPIRED_CREDS.include?(@name) || @name.match?(/expired/i)
        end

        def throttling?
          THROTTLING_ERRORS.include?(@name) || @name.match?(/throttl/i) || @status == 429
        end

        def networking?
          @networking || NETWORKING_ERRORS.include?(@name)
        end

        def checksum? = CHECKSUM_ERRORS.include?(@name)

        def server? = @status >= 500 && @status <= 599

        # The server's Date is more than five minutes from this clock.
        def clock_skewed?
          !@server_time.nil? && (Time.now.utc - @server_time).abs > ClockSkew::THRESHOLD
        end

        def clock_skew? = CLOCK_SKEW_ERRORS.include?(@name) && clock_skewed?

        def retryable?(refreshable_credentials)
          server? || throttling? || networking? || checksum? ||
            (expired_credentials? && refreshable_credentials) || clock_skew?
        end
      end

      # The gem's Retries::RetryQuota, with the costs of its current default
      # (not AWS_NEW_RETRIES_2026).
      class Quota
        INITIAL_RETRY_TOKENS = 500
        LEGACY_RETRY_COST = 5
        TIMEOUT_RETRY_COST = 10
        NO_RETRY_INCREMENT = 1

        def initialize
          @max_capacity = INITIAL_RETRY_TOKENS
          @available_capacity = INITIAL_RETRY_TOKENS
        end

        def checkout_capacity(failure)
          amount = failure.networking? ? TIMEOUT_RETRY_COST : LEGACY_RETRY_COST
          return 0 if amount > @available_capacity

          @available_capacity -= amount
          amount
        end

        def release(amount)
          return if @available_capacity == @max_capacity

          @available_capacity += amount || NO_RETRY_INCREMENT
          @available_capacity = @max_capacity if @available_capacity > @max_capacity
        end
      end

      # The gem's Retries::ClockSkew: per endpoint, the correction applied
      # when signing and the last estimated skew.
      class ClockSkew
        THRESHOLD = 5 * 60

        def initialize
          @corrections = {}
          @estimated = {}
        end

        def clock_correction(endpoint) = @corrections[normalized(endpoint)] || 0

        def estimated_skew(endpoint) = @estimated[normalized(endpoint)]

        def update_clock_correction(endpoint, server_time)
          return if server_time.nil?

          now = Time.now.utc
          return unless (now - server_time).abs > THRESHOLD

          @corrections[normalized(endpoint)] = server_time - now
        end

        def update_estimated_skew(endpoint, server_time)
          return if server_time.nil?

          @estimated[normalized(endpoint)] = server_time - Time.now.utc
        end

        private

        def normalized(endpoint)
          uri = URI.parse(endpoint)
          return endpoint if uri.scheme.nil? || uri.host.nil?

          "#{uri.scheme}://#{uri.host}:#{uri.port}"
        end
      end

      MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

      # An HTTP Date header (Tue, 07 Oct 2026 18:00:00 GMT) as a UTC Time,
      # or nil when it is missing or not in that form.
      def self.server_time(date)
        return nil if date.nil?

        parts = date.split(' ')
        return nil unless parts.length == 6

        month = MONTHS.index(parts[2])
        clock = parts[4].split(':')
        return nil if month.nil? || clock.length != 3

        Time.utc(parts[3].to_i, month + 1, parts[1].to_i, clock[0].to_i, clock[1].to_i, clock[2].to_i)
      end
    end
  end
end

module Seahorse
  module Client
    # The gem's Seahorse::Client::NetworkingError: the error a call raises
    # when the connection fails, after its retries.
    class NetworkingError < StandardError
      attr_reader :original_error

      def initialize(error, msg = nil)
        super(msg || error.message)
        @original_error = error
      end
    end
  end
end
