# frozen_string_literal: true

# spinel-aws-sdk-core: written for the package. The gem's Aws::Waiters::Waiter
# polls through a Poller that walks the waiter's acceptors and JMESPath at run
# time, and stops with catch/throw. Here a generated waiter class checks its
# acceptors in plain Ruby and hands this loop one attempt at a time.
module Aws
  module Waiters
    class Waiter
      # options: :max_attempts, :delay, and :before_attempt and :before_wait
      # (a callable or an Array of them), as the gem's.
      def initialize(options = {})
        @max_attempts = options[:max_attempts]
        @delay = options[:delay]
        @before_attempt = Waiter.callables(options[:before_attempt])
        @before_wait = Waiter.callables(options[:before_wait])
      end

      attr_accessor :max_attempts, :delay

      alias interval delay
      alias interval= delay=

      def before_attempt(&block)
        @before_attempt << block if block_given?
      end

      def before_wait(&block)
        @before_wait << block if block_given?
      end

      # Waiter#poll: the block makes one attempt and answers [state, response]
      # (:retry, :success, :failure or :error). The response on success; a
      # failure, an error or the last attempt raise as the gem's.
      def wait
        n = 0
        loop do
          @before_attempt.each { |callable| callable.call(n) }
          state, response = yield
          n += 1
          return response if state == :success
          raise Errors::FailureStateError.new(response) if state == :failure
          raise Errors::UnexpectedError.new(response.error) if state == :error
          raise Errors::TooManyAttemptsError.new(n) if n == @max_attempts

          @before_wait.each { |callable| callable.call(n, response) }
          Kernel.sleep(@delay)
        end
      end

      # Array(value), for a callable that is not an Array.
      def self.callables(value)
        return [] if value.nil?

        value.is_a?(Array) ? value : [value]
      end
    end
  end
end
