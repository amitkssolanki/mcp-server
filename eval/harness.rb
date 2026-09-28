# frozen_string_literal: true

# Entry point for the evaluation harness. Loaded by lib/tasks/eval.rake and
# test/test_helper.rb; nothing in app/ depends on it.
#
# Layout:
#   eval/oracle/       independent ground truth from the raw CSVs
#   eval/questions/    canonical questions (data)
#   eval/runner/       MCP client, question runner, comparator types
#   eval/invariants/   tool-only consistency properties (seeded)
#   eval/regressions/  known-bad implementations the harness must catch
#   eval/reports/      committed evidence snapshots
module Eval
  ROOT = File.expand_path(__dir__)
  DEFAULT_SEED = 20_260_928

  def self.data_dir
    ENV.fetch("OLIST_DIR", Rails.root.join("db/olist").to_s)
  end

  # The oracle takes a few seconds to build; share it within a process.
  def self.truth
    @truth ||= Oracle::Truth.new(Oracle::Dataset.load(data_dir))
  end
end

%w[
  oracle/dataset oracle/oracle
  runner/check runner/mcp_client runner/expectations runner/question_runner
  invariants/invariants reconciliation
  regressions/historical regressions/registry
  run report
].each { |f| require File.join(Eval::ROOT, f) }
