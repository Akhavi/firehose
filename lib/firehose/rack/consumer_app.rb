module Firehose
  module Rack
    AsyncResponse = [-1, {}, []]

    class ConsumerApp
      def call(env)
        websocket_request?(env) ? websocket.call(env) : http_long_poll.call(env)
      end

      private
      def websocket
        WebSocket.new
      end

      def http_long_poll
        @http_long_poll ||= HttpLongPoll.new
      end

      def websocket_request?(env)
        Faye::WebSocket.websocket?(env)
      end


      class HttpLongPoll
        def call(env)
          req     = env['parsed_request'] ||= ::Rack::Request.new(env)
          path    = req.path
          method  = req.request_method
          timeout = 20
          last_sequence = env[RACK_LAST_MESSAGE_SEQUENCE_HEADER].to_i
          cors_origin = env['HTTP_ORIGIN']

          case method
          # GET is how clients subscribe to the queue. When a messages comes in, we flush out a response,
          # close down the requeust, and the client then reconnects.
          when 'GET'
            EM.next_tick do
              # TODO seperate out CORS logic as an async middleware with a Goliath web server.
              cors_headers  = {
                'Access-Control-Allow-Origin'     => cors_origin,
                'Access-Control-Expose-Headers'   => LAST_MESSAGE_SEQUENCE_HEADER
              }

              # If the request is a CORS request, return those headers, otherwise don't worry 'bout it
              response_headers = cors_origin ? cors_headers : {}

              if last_sequence < 0
                env['async.callback'].call [400, response_headers, ["Header '#{LAST_MESSAGE_SEQUENCE_HEADER}' may not be less than zero"]]
              else
                Channel.new(path).next_message(last_sequence, :timeout => 20).callback do |message, sequence|
                  response_headers.merge!(LAST_MESSAGE_SEQUENCE_HEADER => sequence.to_s)
                  env['async.callback'].call [200, response_headers, [message]]
                end.errback do |e|
                  if e == :timeout
                    env['async.callback'].call [204, response_headers, []]
                  else
                    raise e
                  end
                end
              end
            end

            # Tell the web server that this will be an async response.
            Firehose::Rack::AsyncResponse

          # Tell the browser that we're cool about shipping Last-Message-Sequence headers back-and-forth.
          when 'OPTIONS'
            # TODO seperate out CORS logic as an async middleware with a Goliath web server.
            [200, {
            'Access-Control-Allow-Methods'    => 'GET',
            'Access-Control-Allow-Origin'     => cors_origin,
            'Access-Control-Allow-Headers'    => LAST_MESSAGE_SEQUENCE_HEADER,
            'Access-Control-Expose-Headers'   => LAST_MESSAGE_SEQUENCE_HEADER,
            'Access-Control-Max-Age'          => '1728000'
            }, []]
          else
            Firehose.logger.debug "HTTP #{method} not supported"
            [501, {'Content-Type' => 'text/plain'}, ["#{method} not supported."]]
          end
        end
      end


      # It _may_ be more memory efficient if we used the same instance of this
      # class (or even if we just used a proc/lambda) for every
      # request/connection. However, we couldn't use instance variables, and
      # so I'd need to confirm that local variables would be accessible from
      # the callback blocks.
      class WebSocket
        def call(env)
          req   = ::Rack::Request.new(env)
          @path  = req.path
          ws = Faye::WebSocket.new(env)

          ws.onopen = lambda do |event|
            Firehose.logger.debug "WS subscribed to `#{@path}`"

            subscribe = Proc.new do |last_sequence|
              @channel = Channel.new(@path)
              @deferrable = @channel.next_message(last_sequence).callback do |message, sequence|
                Firehose.logger.debug "WS sent `#{message}` to `#{@path}` with sequence `#{sequence}`"
                ws.send message
                subscribe.call(sequence)
              end.errback { |e| raise e.inspect unless e == :disconnect }
            end

            subscribe.call
          end

          #ws.onmessage = lambda do |event|
          #  event.data
          #end

          ws.onclose = lambda do |event|
            if @deferrable
              @deferrable.fail :disconnect
              @channel.unsubscribe(@deferrable) if @channel
            end
            Firehose.logger.debug "WS connection `#{@path}` closing. Code: #{event.code.inspect}; Reason #{event.reason.inspect}"
          end

          ws.onerror = lambda do |event|
            Firehose.logger.error "WS connection `#{@path}` error `#{error}`: #{error.backtrace}"
          end


          # Return async Rack response
          ws.rack_response
        end
      end
    end
  end
end
