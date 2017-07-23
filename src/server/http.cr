require "./connection"
require "../reql/*"
require "http/server"
require "json"

module Server
  @@http_connections = {} of String => ClientConnection

  def self.start_http
    server = HTTP::Server.new(8080) do |context|
      uri = URI.parse(context.request.resource)
      case uri.path
      when "/ajax/reql/open-new-connection"
        conn_id = SecureRandom.base64
        @@http_connections[conn_id] = ClientConnection.new
        context.response.print conn_id
      when "/ajax/reql/close-connection"
        conn_id = (uri.query || "").sub("conn_id=", "")
        @@http_connections.delete conn_id
      when "/ajax/reql/"
        conn_id = (uri.query || "").sub("conn_id=", "")
        conn = @@http_connections[conn_id]
        body = context.request.body || IO::Memory.new
        query_id = body.read_bytes(UInt64)
        message = JSON.parse(body.gets_to_end).raw.as(Array)

        answer = {"t" => 18, "r" => ["hmm..."], "b" => [] of String}.to_json
        begin
          case message[0]
          when 1 # START
            start = Time.now
            query = ReQL::Query.new(query_id, message[1], message[2]?.as(Hash(String, JSON::Type) | Nil))
            result = query.start
            duration = (Time.now - start).to_f
            if result.is_a? ReQL::Datum
              answer = {"t" => 1, "r" => [result.value], "p" => [{"duration(ms)" => duration}]}.to_json
            else
              answer = {"t" => 2, "r" => ["stream here", 1, 2, 3], "p" => [{"duration(ms)" => duration}]}.to_json
            end
          when 2 # CONTINUE
          when 3 # STOP
          when 4 # NOREPLY_WAIT
          when 5 # SERVER_INFO
          end
        rescue ex : ReQL::CompileError
          answer = {"t" => 17, "r" => [ex.message], "b" => [] of String}.to_json
        rescue ex : ReQL::RuntimeError
          answer = {"t" => 18, "r" => [ex.message], "b" => [] of String}.to_json
        end
        puts answer
        context.response.write_bytes(query_id)
        context.response.write_bytes(answer.size)
        context.response.print answer
      else
        p context.request
        context.response.status_code = 400
      end

      # res = HTTP::Client.new("172.17.0.2", 8080).exec(context.request)
      # p res.body
      # res.headers.each do |(k ,v)|
      #   context.response.headers[k] = v
      # end
      # context.response.status_code = res.status_code
      # context.response.print res.body
    end

    puts "Listening on http://127.0.0.1:3000"
    server.listen
  end
end
