# frozen_string_literal: true

require 'async/http/protocol/http1/server'

module RestGate
  module ClientIdleTimeout
    class Expired < Async::TimeoutError; end

    class << self
      attr_reader :seconds

      def install!(value = ENV.fetch('CLIENT_IDLE_TIMEOUT_SECONDS', '60'))
        seconds = Float(value, exception: false)
        unless seconds&.finite? && seconds >= 0
          raise ArgumentError, 'CLIENT_IDLE_TIMEOUT_SECONDS must be a finite non-negative number'
        end

        @seconds = seconds
        server = Async::HTTP::Protocol::HTTP1::Server
        server.prepend(HTTP1Server) unless server.ancestors.include?(HTTP1Server)
      end
    end

    module HTTP1Server
      def next_request
        seconds = ClientIdleTimeout.seconds
        return super unless seconds.positive? && idle? && !closed?

        # Peek without consuming bytes; active parsing, uploads and responses have no idle deadline.
        begin
          Async::Task.current.with_timeout(seconds, Expired) { @stream.peek(1) }
        rescue Expired
          # Returning normally lets Falcon close the idle socket without an HTTP error response.
          return nil
        end

        super
      end
    end
  end
end
