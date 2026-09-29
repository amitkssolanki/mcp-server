# frozen_string_literal: true

require "digest"
require "yaml"

module Eval
  module Agent
    # One agent experiment: every question in eval/agent/questions.yml, run N
    # times through Claude Code against the store's MCP server, graded against
    # the oracle. Writes eval/reports/<name>.json and <name>.md, and keeps each
    # run's raw stream-json event log under tmp/agent/<name>/.
    class Experiment
      QUESTIONS = File.join(__dir__, "questions.yml")
      BASELINE_TOOLS = File.join(__dir__, "baseline-tools.json")

      def initialize(name:, runs:, model:, concurrency: 3, io: $stdout, only: nil)
        @name = name
        @runs = runs
        @model = model
        @concurrency = concurrency
        @io = io
        @questions = YAML.safe_load_file(QUESTIONS)
        @questions.select! { |q| only.include?(q["id"]) } if only
        @raw_dir = Rails.root.join("tmp/agent", name).to_s
      end

      # The questions with picks filled in and expected answers computed:
      # everything a run is graded against, fixed before any run.
      def plan
        @plan ||= begin
          expected = Expected.new(Eval.truth)
          @questions.map { |q| prepare(q, expected) }
        end
      end

      def self.write_preregistration(path)
        plan = new(name: "preregistration", runs: 0, model: "n/a").plan
        File.write(path, JSON.pretty_generate(
          note: "Expected answers for eval/agent/questions.yml, computed by the oracle from the raw CSVs " \
                "and committed before any agent run.",
          questions: plan.map { |p| { id: p[:question]["id"], prompt: p[:prompt], answer_type: p[:question]["answer"],
                                      expected: p[:expected], alternates: p[:alternates],
                                      acceptable_tools: p[:question]["tools"], arg_rule: p[:question]["args"] } }
        ) + "\n")
      end

      def execute
        started_at = Time.now.utc
        plan = self.plan
        tools = tool_versions

        runner = ClaudeRunner.new(model: @model, raw_dir: @raw_dir)
        jobs = plan.flat_map { |p| (1..@runs).map { |i| [p, i] } }
        guard_billing!(runner, jobs.first)

        results = run_all(runner, jobs.drop(1)).unshift(@first_result)
        report = build_report(plan, results, tools, started_at)
        write(report)
        report
      end

      private

      # The question with its picks filled in, its expected answer and the
      # defined alternates, all computed before any run.
      def prepare(q, expected)
        picked = q["pick"] ? expected.pick(q["pick"]) : {}
        fill = ->(v) { v.is_a?(String) && picked.any? ? format(v, **picked) : v }
        params = ->(spec) { (spec["params"] || {}).transform_values(&fill) }
        {
          question: q, picked: picked, prompt: fill.(q.fetch("prompt")),
          expected: expected.fetch(q.dig("expected", "oracle"), params.(q["expected"])),
          alternates: (q["alternates"] || {}).to_h { |k, spec| [k, expected.fetch(spec["oracle"], params.(spec))] }
        }
      end

      # What the agent is shown: tools/list and the server instructions, and
      # whether they are exactly the frozen day 2 baseline.
      def tool_versions
        tools = McpClient.new.list_tools
        served = { instructions: StoreMcp::INSTRUCTIONS, tools: tools }
        frozen = JSON.parse(File.read(BASELINE_TOOLS))
        {
          digest: Digest::SHA256.hexdigest(JSON.generate(served))[0, 16],
          matches_frozen_baseline: frozen["tools"] == JSON.parse(JSON.generate(tools)) &&
            frozen["instructions"] == StoreMcp::INSTRUCTIONS,
          changed_tools: tools.reject { |t| frozen["tools"].include?(JSON.parse(JSON.generate(t))) }.map { |t| t["name"] }
        }
      end

      # Run one case first and refuse to go on unless it used the
      # subscription login. An experiment must never quietly bill an API key.
      def guard_billing!(runner, (plan, index))
        @first_result = run_one(runner, plan, index)
        source = @first_result[:run][:api_key_source]
        return if source == "none" || ENV["ALLOW_API_KEY"] == "1"

        raise "first run reported apiKeySource=#{source.inspect}, not the subscription login; " \
              "stopping. Error: #{@first_result[:run][:error]}"
      end

      def run_all(runner, jobs)
        queue = Queue.new
        jobs.each { |j| queue << j }
        results = Queue.new
        Array.new(@concurrency) do
          Thread.new do
            while (job = (queue.pop(true) rescue nil))
              results << run_one(runner, *job)
            end
          end
        end.each(&:join)
        Array.new(results.size) { results.pop }
      end

      def run_one(runner, plan, index)
        run = runner.run(plan[:question]["id"], plan[:prompt], index)
        grade = Grader.new(plan[:question], expected: plan[:expected], alternates: plan[:alternates],
                           picked: plan[:picked]).grade(run)
        grade = grade.merge(verdict: "error", correct: false) if run.error
        @io.puts format("  %-32s run %d  %-24s tools=%s", plan[:question]["id"], index, grade[:verdict],
                        grade[:tools_called].join(","))
        { question_id: plan[:question]["id"], run_index: index, run: run.to_h.except(:raw_path).merge(
          raw_log: run.raw_path.delete_prefix("#{Rails.root}/")
        ), grade: grade }
      end

      def build_report(plan, results, tools, started_at)
        results = results.sort_by { |r| [r[:question_id], r[:run_index]] }
        per_question = plan.map do |p|
          id = p[:question]["id"]
          rs = results.select { |r| r[:question_id] == id }
          answers = rs.map { |r| r[:grade][:answer] }
          {
            id: id, prompt: p[:prompt], risk: p[:question]["risk"], expected: p[:expected],
            alternates: p[:alternates], acceptable_tools: p[:question]["tools"], arg_rule: p[:question]["args"],
            runs: rs.size, correct: rs.count { |r| r[:grade][:correct] },
            tool_ok: rs.count { |r| r[:grade][:tool_ok] }, args_ok: rs.count { |r| r[:grade][:args_ok] },
            verdicts: rs.map { |r| r[:grade][:verdict] },
            distinct_answers: answers.map(&:to_s).uniq.size,
            consistent: rs.map { |r| [r[:grade][:verdict], r[:grade][:answer].to_s] }.uniq.size == 1
          }
        end

        n = results.size.to_f
        pct = ->(k) { (results.count { |r| r[:grade][k] } / n * 100).round(1) }
        usage = results.map { |r| r[:run][:usage] || {} }
        {
          experiment: @name,
          method: {
            execution: "Claude Code headless (claude -p), subscription login",
            claude_code_version: `claude --version 2>/dev/null`.strip,
            model: @model, runs_per_question: @runs, questions: plan.size, total_runs: results.size,
            api_key_sources: results.map { |r| r[:run][:api_key_source] }.tally,
            system_prompt: ClaudeRunner::SYSTEM_PROMPT, answer_instruction: ClaudeRunner::ANSWER_INSTRUCTION,
            tools: tools, git_commit: `git rev-parse --short HEAD`.strip,
            started_at: started_at.iso8601, finished_at: Time.now.utc.iso8601
          },
          metrics: {
            answer_accuracy_pct: pct.(:correct),
            tool_selection_accuracy_pct: pct.(:tool_ok),
            argument_accuracy_pct: pct.(:args_ok),
            questions_correct_every_run: per_question.count { |q| q[:correct] == q[:runs] },
            questions_consistent: per_question.count { |q| q[:consistent] },
            verdicts: results.map { |r| r[:grade][:verdict].split(":").first }.tally,
            mean_tool_calls: (results.sum { |r| r[:grade][:tools_called].size } / n).round(2),
            mean_duration_s: (results.sum { |r| r[:run][:duration_ms].to_i } / n / 1000).round(1),
            tokens: %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens]
                      .to_h { |k| [k, usage.sum { |u| u[k].to_i }] },
            notional_cost_usd: results.sum { |r| r[:run][:cost_usd].to_f }.round(4)
          },
          questions: per_question,
          runs: results
        }
      end

      def write(report)
        base = Rails.root.join("eval/reports", @name).to_s
        File.write("#{base}.json", JSON.pretty_generate(report))
        File.write("#{base}.md", Markdown.new(report).render)
        @io.puts "Wrote #{base}.json and .md"
      end
    end
  end
end
