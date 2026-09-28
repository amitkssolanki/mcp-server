# frozen_string_literal: true

require "json"

module Eval
  # Calls tools the way a real MCP client does: JSON-RPC text in, JSON-RPC text
  # out, through MCP::Server#handle_json. That covers argument validation,
  # tool lookup, response serialisation and structuredContent, which is the
  # path claude.ai takes. It is the same server StoreMcp.server builds for the
  # stdio and HTTP transports, minus the transport itself.
  #
  # The harness only ever builds a read-only server. It cannot write to the
  # store, even by mistake.
  class McpClient
    Result = Struct.new(:tool, :arguments, :text, :structured, :error, :error_message, :seconds, keyword_init: true)

    attr_reader :server

    def initialize(store: StoreMcp.default_store, tools: nil)
      @server = StoreMcp.server(store: store, read_only: true, tools: tools)
      @next_id = 0
    end

    def list_tools
      rpc("tools/list").fetch("tools")
    end

    def call(tool, arguments = {})
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = raw("tools/call", name: tool, arguments: arguments)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      if response["error"]
        return Result.new(tool: tool, arguments: arguments, error: true,
                          error_message: response["error"]["message"], seconds: seconds)
      end

      result = response.fetch("result")
      text = Array(result["content"]).filter_map { |c| c["text"] }.join("\n")
      Result.new(tool: tool, arguments: arguments, text: text, structured: result["structuredContent"],
                 error: result["isError"] == true, error_message: (text if result["isError"]), seconds: seconds)
    end

    private

    def rpc(method, **params)
      response = raw(method, **params)
      raise "MCP error on #{method}: #{response['error'].inspect}" if response["error"]

      response.fetch("result")
    end

    def raw(method, **params)
      @next_id += 1
      request = { jsonrpc: "2.0", id: @next_id, method: method, params: params }
      JSON.parse(server.handle_json(JSON.generate(request)))
    end
  end
end
