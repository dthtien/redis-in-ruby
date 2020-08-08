require 'socket'
require 'timeout'
require 'logger'
require 'delegate'
require 'strscan'

LOG_LEVEL = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO

require_relative './types'
require_relative './expire_helper'
require_relative './command_command'
require_relative './get_command'
require_relative './set_command'
require_relative './ttl_command'
require_relative './pttl_command'

module Redis

  class Server

    COMMANDS = {
      'COMMAND' => CommandCommand,
      'GET' => GetCommand,
      'SET' => SetCommand,
      'TTL' => TtlCommand,
      'PTTL' => PttlCommand,
    }
    MAX_EXPIRE_LOOKUPS_PER_CYCLE = 20
    DEFAULT_FREQUENCY = 10 # How many times server_cron runs per second

    IncompleteCommand = Class.new(StandardError)
    ProtocolError = Class.new(StandardError) do
      def serialize
        RESPError.new(message).serialize
      end
    end

    TimeEvent = Struct.new(:process_at, :block)
    Client = Struct.new(:socket, :buffer) do
      def initialize(socket)
        self.socket = socket
        self.buffer = ''
      end
    end


    def initialize
      @logger = Logger.new(STDOUT)
      @logger.level = LOG_LEVEL

      @clients = []
      @data_store = {}
      @expires = {}

      @server = TCPServer.new 2000
      @time_events = []
      @logger.debug "Server started at: #{ Time.now }"
      add_time_event(Time.now.to_f.truncate + 1) do
        server_cron
      end

      start_event_loop
    end

    private

    def add_time_event(process_at, &block)
      @time_events << TimeEvent.new(process_at, block)
    end

    def nearest_time_event
      now = (Time.now.to_f * 1000).truncate
      nearest = nil
      @time_events.each do |time_event|
        if nearest.nil?
          nearest = time_event
        elsif time_event.process_at < nearest.process_at
          nearest = time_event
        else
          next
        end
      end

      nearest
    end

    def select_timeout
      if @time_events.any?
        nearest = nearest_time_event
        now = (Time.now.to_f * 1000).truncate
        if nearest.process_at < now
          0
        else
          (nearest.process_at - now) / 1000.0
        end
      else
        0
      end
    end

    def client_sockets
      @clients.map(&:socket)
    end

    def start_event_loop
      loop do
        timeout = select_timeout
        @logger.debug "select with a timeout of #{ timeout }"
        result = IO.select(client_sockets + [@server], [], [], timeout)
        sockets = result ? result[0] : []
        process_poll_events(sockets)
        process_time_events
      end
    end

    def process_poll_events(sockets)
      sockets.each do |socket|
        begin
          if socket.is_a?(TCPServer)
            @clients << Client.new(@server.accept)
          elsif socket.is_a?(TCPSocket)
            client = @clients.find { |client| client.socket == socket }
            client_command_with_args = socket.read_nonblock(1024, exception: false)
            if client_command_with_args.nil?
              @clients.delete(client)
            elsif client_command_with_args == :wait_readable
              # There's nothing to read from the client, we don't have to do anything
              next
            elsif client_command_with_args.strip.empty?
              @logger.debug "Empty request received from #{ socket }"
            else
              client.buffer += client_command_with_args
              split_commands(client.buffer) do |command_parts, command_length|
                # Truncate the command we just parsed
                client.buffer = client.buffer[command_length..-1]
                response = handle_client_command(command_parts)
                @logger.debug "Response: #{ response.class } / #{ response.inspect }"
                @logger.debug "Writing: '#{ response.serialize.inspect }'"
                socket.write response.serialize
              end
            end
          else
            raise "Unknown socket type: #{ socket }"
          end
        rescue Errno::ECONNRESET
          @clients.delete_if { |client| client.socket == socket }
        rescue IncompleteCommand => e
          # Not clearing the buffer or anything
          next
        rescue ProtocolError => e
          socket.write e.serialize
          socket.close
          @clients.delete(client)
        end
      end
    end

    def split_commands(client_buffer)
      @logger.debug "Full result from read: '#{ client_buffer.inspect }'"
      if client_buffer[0] == '*'
        total_chars = client_buffer.length
        scanner = StringScanner.new(client_buffer)

        until scanner.eos?
          command_parts = parse_value_from_string(scanner)
          raise "Not an array #{ client_buffer }" unless command_parts.is_a?(Array)

          yield command_parts, scanner.charpos
        end
      else
        client_buffer.split("\n").map(&:strip).each do |command|
          yield command.split.map(&:strip), client_buffer.length
        end
      end
    end

    # We're not parsing integers, errors or simple strings since none of the implemented
    # commands use these data types
    def parse_value_from_string(scanner)
      type_char = scanner.getch
      case type_char
      when '$'
        expected_length = scanner.scan_until(/\r\n/)
        raise IncompleteCommand, scanner.string if expected_length.nil?
        expected_length = expected_length.to_i
        raise "Unexpected length for #{ scanner.string }" if expected_length <= 0

        bulk_string = scanner.rest.slice(0, expected_length + 2) # Adding 2 for CR(\r) & LF(\n)

        raise IncompleteCommand, scanner.string if bulk_string.nil? ||
                                                   bulk_string.length - 2 != expected_length

        bulk_string.strip!

        raise "Length mismatch: #{ bulk_string } vs #{ expected_length }" if expected_length != bulk_string&.length

        scanner.pos += bulk_string.bytesize + 2
        bulk_string
      when '*'
        expected_length = scanner.scan_until(/\r\n/)
        raise IncompleteCommand, scanner.string if expected_length.nil?
        expected_length = expected_length.to_i
        raise "Unexpected length for #{ scanner.string }" if expected_length < 0

        array_result = []

        expected_length.times do
          raise IncompleteCommand, scanner.string if scanner.eos?
          parsed_value = parse_value_from_string(scanner)
          raise IncompleteCommand, scanner.string if parsed_value.nil?
          array_result << parsed_value
        end

        array_result
      else
        raise ProtocolError, "ERR Protocol error: expected '$', got '#{ type_char }'"
      end
    end

    def process_time_events
      @time_events.delete_if do |time_event|
        next if time_event.process_at > Time.now.to_f * 1000

        return_value = time_event.block.call

        if return_value.nil?
          true
        else
          time_event.process_at = (Time.now.to_f * 1000).truncate + return_value
          @logger.debug "Rescheduling time event #{ Time.at(time_event.process_at / 1000.0).to_f }"
          false
        end
      end
    end

    def handle_client_command(command_parts)
      @logger.debug "Received command: #{ command_parts }"
      command_str = command_parts[0]
      args = command_parts[1..-1]

      command_class = COMMANDS[command_str]

      if command_class
        command = command_class.new(@data_store, @expires, args)
        command.call
      else
        formatted_args = args.map { |arg| "`#{ arg }`," }.join(' ')
        message = "ERR unknown command `#{ command_str }`, with args beginning with: #{ formatted_args }"
        RESPError.new(message)
      end
    end

    def server_cron
      start_timestamp = Time.now
      keys_fetched = 0

      @expires.each do |key, _|
        if @expires[key] < Time.now.to_f * 1000
          @logger.debug "Evicting #{ key }"
          @expires.delete(key)
          @data_store.delete(key)
        end

        keys_fetched += 1
        if keys_fetched >= MAX_EXPIRE_LOOKUPS_PER_CYCLE
          break
        end
      end

      end_timestamp = Time.now
      @logger.debug do
        sprintf(
          "Processed %i keys in %.3f ms", keys_fetched, (end_timestamp - start_timestamp) * 1000)
      end

      1000 / DEFAULT_FREQUENCY
    end
  end
end