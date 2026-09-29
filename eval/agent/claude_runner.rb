# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

module Eval
  module Agent
    # Runs one question through Claude Code in headless mode (`claude -p`) and
    # returns everything it did, read from the stream-json event log.
    #
    # Execution: the user's own Claude subscription (claude.ai login), not an
    # API key. The init event's apiKeySource is recorded for every run, so a
    # report shows which billing path produced it. The run is refused if an
    # API key would be used, unless ALLOW_API_KEY=1.
    #
    # Isolation: the agent gets the store's MCP tools and nothing else. There
    # are no built-in tools (it cannot read the repo, the CSVs or the oracle),
    # no settings or CLAUDE.md, no other MCP servers, and an empty working
    # directory. The MCP server is bin/mcp-stdio, read-only, against the test
    # database: the same server code the HTTP endpoint serves.
    class ClaudeRunner
      SYSTEM_PROMPT = <<~TEXT
        You help the operator of an online store answer questions about their business.
        Use the store's tools to find the answer; never guess or estimate a figure the
        tools can give you. Answer the question that was asked, in a sentence or two.
      TEXT

      ANSWER_INSTRUCTION = <<~TEXT.strip
        When you have the answer, end your reply with a single line containing only a
        JSON object of the form {"answer": <value>}, where <value> is the number or
        name that answers the question (a number without currency symbols or units).
      TEXT

      Run = Struct.new(:question_id, :run_index, :model, :api_key_source, :tool_calls, :final_text,
                       :turns, :duration_ms, :usage, :cost_usd, :error, :raw_path, keyword_init: true)

      def initialize(model:, raw_dir:, root: Rails.root)
        @model = model
        @raw_dir = raw_dir
        @root = root
        FileUtils.mkdir_p(raw_dir)
        @mcp_config = write_mcp_config
      end

      def run(question_id, prompt, run_index)
        raw_path = File.join(@raw_dir, "#{question_id}.run#{run_index}.jsonl")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = Dir.mktmpdir("agent-cwd") do |cwd|
          Open3.capture3(env, *command(prompt), chdir: cwd, stdin_data: "")
        end
        File.write(raw_path, stdout)
        parse(question_id, run_index, stdout, raw_path).tap do |r|
          r.duration_ms ||= ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          r.error ||= "exit #{status.exitstatus}: #{stderr.lines.last(3).join.strip}" unless status.success?
        end
      end

      private

      def command(prompt)
        [
          "claude", "-p", "#{prompt}\n\n#{ANSWER_INSTRUCTION}",
          "--model", @model,
          "--output-format", "stream-json", "--verbose",
          "--system-prompt", SYSTEM_PROMPT,
          "--strict-mcp-config", "--mcp-config", @mcp_config,
          "--tools", "",
          "--allowedTools", "mcp__store",
          "--setting-sources", "",
          "--disable-slash-commands",
          "--no-session-persistence",
          "--max-turns", "12"
        ]
      end

      # The CLI's own login (keychain), not the calling session's. Only what a
      # shell needs; notably no ANTHROPIC_API_KEY, so a key cannot be picked up
      # by accident.
      def env
        keep = %w[HOME USER LOGNAME PATH TERM LANG TMPDIR SHELL]
        base = ENV.to_h.slice(*keep)
        base["ANTHROPIC_API_KEY"] = ENV["ANTHROPIC_API_KEY"] if ENV["ALLOW_API_KEY"] == "1"
        # Open3 with unsetenv_others would be cleaner; spawn's env merges, so
        # blank out everything else explicitly.
        ENV.keys.each_with_object(base) { |k, h| h[k] = nil unless h.key?(k) }
      end

      def write_mcp_config
        gem_home = ENV.fetch("GEM_HOME")
        server_env = {
          "RAILS_ENV" => "test", "MCP_READ_ONLY" => "true",
          "GEM_HOME" => gem_home, "GEM_PATH" => ENV.fetch("GEM_PATH", gem_home),
          "PATH" => ENV.fetch("PATH")
        }
        config = { mcpServers: { store: { command: @root.join("bin/mcp-stdio").to_s, env: server_env } } }
        path = File.join(@raw_dir, "mcp-config.json")
        File.write(path, JSON.pretty_generate(config))
        path
      end

      def parse(question_id, run_index, stdout, raw_path)
        run = Run.new(question_id: question_id, run_index: run_index, model: @model, tool_calls: [],
                      final_text: nil, raw_path: raw_path)
        by_id = {}
        stdout.each_line do |line|
          event = JSON.parse(line)
          case event["type"]
          when "system"
            if event["subtype"] == "init"
              run.api_key_source = event["apiKeySource"]
              run.error = "MCP server not connected" unless event["mcp_servers"].to_a.any? { |s| s["status"] == "connected" }
            end
          when "assistant"
            Array(event.dig("message", "content")).each do |block|
              next unless block["type"] == "tool_use"

              call = { id: block["id"], tool: block["name"].to_s.delete_prefix("mcp__store__"), arguments: block["input"] }
              by_id[block["id"]] = call
              run.tool_calls << call
            end
          when "user"
            Array(event.dig("message", "content")).each do |block|
              next unless block["type"] == "tool_result" && (call = by_id[block["tool_use_id"]])

              text = Array(block["content"]).map { |c| c.is_a?(Hash) ? c["text"] : c.to_s }.join
              call[:result] = text[0, 1500]
              call[:is_error] = block["is_error"] == true
            end
          when "result"
            run.final_text = event["result"]
            run.turns = event["num_turns"]
            run.duration_ms = event["duration_ms"]
            run.usage = event["usage"]&.slice("input_tokens", "output_tokens", "cache_read_input_tokens",
                                              "cache_creation_input_tokens")
            run.cost_usd = event["total_cost_usd"]
            run.error = event["result"] if event["is_error"]
          end
        rescue JSON::ParserError
          next
        end
        run
      end
    end
  end
end
