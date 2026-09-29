# frozen_string_literal: true

namespace :eval do
  desc "Run the MCP truth harness: questions vs the CSV oracle, invariants, reconciliation, regressions. " \
       "SEED=n CASES=n REGRESSIONS=0 OUT=path.json"
  task run: :environment do
    require Rails.root.join("eval/harness")

    seed = Integer(ENV.fetch("SEED", Eval::DEFAULT_SEED))
    run = Eval::Run.new(seed: seed, cases: Integer(ENV.fetch("CASES", 25)),
                        regressions: ENV.fetch("REGRESSIONS", "1") != "0")
    puts "Running (seed #{seed})"
    report = Eval::Report.new(run.execute)
    report.print

    out = ENV.fetch("OUT", Rails.root.join("tmp/eval/latest.json").to_s)
    report.write_json(out)
    puts "JSON: #{out}"
    exit(1) unless report.passed?
  end

  desc "Agent evaluation: questions in eval/agent/questions.yml through Claude Code, graded against the oracle. " \
       "NAME=03-agent-baseline RUNS=3 MODEL=claude-sonnet-5 CONCURRENCY=3 ONLY=id,id"
  task agent: :environment do
    require Rails.root.join("eval/harness")
    require Rails.root.join("eval/agent/agent")

    experiment = Eval::Agent::Experiment.new(
      name: ENV.fetch("NAME", "03-agent-baseline"), runs: Integer(ENV.fetch("RUNS", 3)),
      model: ENV.fetch("MODEL", "claude-sonnet-5"), concurrency: Integer(ENV.fetch("CONCURRENCY", 3)),
      only: ENV["ONLY"]&.split(",")
    )
    report = experiment.execute
    puts JSON.pretty_generate(report[:metrics])
  end

  desc "Write eval/agent/expected-answers.json: the oracle's answers to the agent questions, before any run"
  task agent_preregister: :environment do
    require Rails.root.join("eval/harness")
    require Rails.root.join("eval/agent/agent")

    path = Rails.root.join("eval/agent/expected-answers.json").to_s
    Eval::Agent::Experiment.write_preregistration(path)
    puts File.read(path)
  end
end
