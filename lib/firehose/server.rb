require 'faye/websocket'

module Firehose
  class Server
    def initialize(opts={})
      @port   = opts[:port]   || Firehose::Default::URI.port
      @host   = opts[:host]   || Firehose::Default::URI.host
      @server = opts[:server] || :rainbows
    end

    def start
      self.send("start_#{@server}")
    end

    def start_rainbows
      require 'rainbows'
      Faye::WebSocket.load_adapter('rainbows')

      rackup = Unicorn::Configurator::RACKUP
      rackup[:port] = @port if @port
      rackup[:host] = @host if @host
      rackup[:set_listener] = true
      opts = rackup[:options]
      opts[:config_file] = File.expand_path('../../../config/rainbows.rb', __FILE__)

      server = Rainbows::HttpServer.new(Firehose::Rack::App.new, opts)
      server.start.join
    end

    def start_thin
      require 'thin'
      Faye::WebSocket.load_adapter('thin')

      # TODO: See if we can just set Thin to use Firehose.logger instead of
      #       printing out messages by itself.
      Thin::Logging.silent = true if Firehose.logger.level == Logger::ERROR

      server = Thin::Server.new(@host, @port) do
        run Firehose::Rack::App.new
      end.start
    end
  end
end
