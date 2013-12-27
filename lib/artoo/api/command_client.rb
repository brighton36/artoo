module Artoo
  module Api
    # The Artoo::Api::CommandClient class is how a websocket client can issue
    # commands to a robot and/or a device
    class CommandClient
      include Celluloid
      include Celluloid::Logger

      MESSAGE_POLL_INTERVAL = 1.0/60
      JSON_HASH_SPLITTER = /(?=(\{((?:[^{}]++|\{\g<2>\})++)\}))/
      

      class ApiCommandError < StandardError; end
      class InvalidJson < ApiCommandError; end
      class InvalidMessage < ApiCommandError; end
      class UnhandledRequest < ApiCommandError; end
      class InvalidParameters < ApiCommandError; end

      class << self
        attr_accessor :request_handlers
   
        private 

        # Register a requestid handler with the command dispatcher
        # @param [Symbol] label
        def on_request(label, &block)
          @request_handlers ||= {}
          @request_handlers[label.to_sym] = block
        end

        def device(robot_id, device_id)
          master.robot_device(robot_id, device_id)
        end

        def master
          ::Celluloid::Actor[:master]
        end
      end

      # Create new command dispatch client
      # @param [Socket] websocket
      def initialize(websocket)
        info "Initializing WebSockets commands dispatcher..."
        @websocket = websocket
        @websocket.on_message &method(:on_message).to_proc

        # We can't use the websocket.read_every since we need to catch EOF and
        # terminate the process when encountered:
        every(MESSAGE_POLL_INTERVAL) do
          begin
            @websocket.read 
          rescue Reel::SocketError, Errno::EPIPE, EOFError, IOError
            info "Disconnecting WebSockets commands dispatcher..."
            terminate
          end
        end
      end

      # Retrieve list of robots
      # @return [JSON] robots
      on_request(:robots) do |params|
        master.robots.collect{|r|r.to_hash}
      end

      # Retrieve robot by id
      # @return [JSON] robot
      on_request(:robot) do |params|
        master.robot(params[:robotid]).as_json
      end

      # Retrieve robot commands
      # @return [JSON] commands
      on_request(:robot_commands) do |params|
        master.robot(params[:robotid]).commands
      end

      # Execute robot command
      # @return [JSON] command
      on_request(:robot_command) do |params|
        master.robot(params[:robotid]).command(params[:commandid], *command_params)
      end

      # Retrieve robot devices
      # @return [JSON] devices
      on_request(:robot_devices) do |params|
        master.robot_devices(params[:robotid]).each_value.collect {|d| d.to_hash}
      end

      # Retrieve robot device
      # @return [JSON] device
      on_request(:robot_device) do |params|
        device(params[:robotid], params[:deviceid]).as_json
      end

      # Retrieve robot commands
      # @return [JSON] commands
      on_request(:robot_device_commands) do |params|
        device(params[:robotid], params[:deviceid]).commands
      end

      # Execute robot command
      # @return [JSON] command
      on_request(:robot_device_command) do |params|
        device(params[:robotid], params[:deviceid]).command(params[:commandid],
          *(params.has_key? :command_params) ? params[:command_params] : [] )
      end

      # Retrieve robot connections
      # @return [JSON] connections
      on_request(:robot_connections) do |params|
        master.robot_connections(params[:robotid]).each_value.collect{|c| c.to_hash}
      end

      # Retrieve robot connection
      # @return [JSON] connection
      on_request(:robot_connection) do |params|
        master.robot_connection(params[:robotid], params[:connectionid]).as_json
      end

      private

      # Write message to client
      # @param [String] m
      def write(m)
        @websocket.write m
      end

      # Handles incoming socket requests
      # @param [String] m
      def on_message(m)
        each_message(m) do |msg|
          puts "Message:"+msg.inspect
          raise InvalidMessage unless msg.has_key?(:requestid)

          request = msg[:requestid].to_sym

          raise UnrecognizedCommand unless self.class.request_handlers.has_key? request

          result = self.class.request_handlers[request].call(msg)

          write MultiJson.dump({:result => result, :requestid => request})
        end unless m.empty?

        nil
          
        rescue ApiCommandError, MultiJson::LoadError => e
          write MultiJson.dump(exception_to_h(e))
      end

      # m can contain multiple messages, concatenated together without a delim
      # as such, this regex will split messages into group-matched hashes for
      # processing hash-by-hash. I suppose this feature could also be used
      # to dispatch multiple commands per send call, if you're into that.
      # StringSplitter is a better class to handle this, but $0 won't be 
      # populated by a group-match regex, so we resort to this:
      def each_message(m, &block)
        while( JSON_HASH_SPLITTER.match(m) && !$1.empty?) do 
          msg = MultiJson.load m.slice!($1), :symbolize_keys => true 
          block.call msg
        end unless m.empty?
      end

      # Return an underscorized error based on the classname, alongside the
      # error message:
      def exception_to_h(e)
        e_label = e.class.name.gsub(/(?<!\A)([A-Z])/, '_\1').tr('::', "_").gsub(/_+/, '_').downcase
        { :error => e_label, :message => e.message}
      end
    end
  end
end
