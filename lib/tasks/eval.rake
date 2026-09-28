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
end
