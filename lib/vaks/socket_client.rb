require "socket"
require "json"

module Vaks
  class SocketClient
    def initialize(socket_path)
      @socket_path = socket_path
    end

    # Send a command hash to the daemon and return the parsed response.
    # Raises a descriptive error if the daemon is not running.
    def send(cmd_hash)
      UNIXSocket.open(@socket_path) do |sock|
        sock.puts(JSON.generate(cmd_hash))
        JSON.parse(sock.gets.chomp)
      end
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      raise "vaks daemon is not running (socket not found: #{@socket_path})"
    end
  end
end
