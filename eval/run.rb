# frozen_string_literal: true

require "digest"

module Eval
  # One full evaluation: questions, invariants and reconciliation against the
  # real tools, then every registered regression. Returns a plain result
  # object; Report renders it.
  class Run
    Result = Struct.new(:meta, :checks, :regressions, :seconds, keyword_init: true)
    RegressionResult = Struct.new(:id, :kind, :finding, :title, :provenance, :caught, :caught_by, :failing, :evidence,
                                  keyword_init: true)

    def initialize(seed: DEFAULT_SEED, cases: 25, regressions: true, io: $stdout)
      @seed = seed
      @cases = cases
      @regressions = regressions
      @io = io
    end

    def execute
      started = now
      truth = timed("oracle built from CSVs") { Eval.truth }
      @expectations = Expectations.new(truth)
      @questions = QuestionRunner.load

      checks = timed("checks") { run_checks(McpClient.new, truth) }
      regressions = @regressions ? timed("regressions") { Regressions.all.map { |r| run_regression(r, checks, truth) } } : []

      Result.new(meta: meta, checks: checks, regressions: regressions, seconds: (now - started).round(1))
    end

    private

    # `ids`, when given, limits the run to those checks: a regression is judged
    # only on the checks it names, so running anything else would be wasted
    # time.
    def run_checks(client, truth, ids: nil)
      wanted = ->(id) { ids.nil? || ids.include?(id) }
      runner = QuestionRunner.new(client: client, expectations: @expectations)
      invariant_ids = Invariants.all.map { |m| m.to_s.delete_prefix("check_").tr("_", "-") }.select(&wanted)
      differential = Differential.new(runner: runner, truth: truth, seed: @seed, cases: @cases)

      @questions.select { |q| wanted.(q["id"]) }.map { |q| runner.run(q) } +
        (invariant_ids.empty? ? [] : Invariants.new(client: client, seed: @seed, cases: @cases).run(only: invariant_ids)) +
        differential.run(ids: ids) +
        (ids.nil? || ids.any? { |id| id.start_with?("reconcile-") } ? Reconciliation.new(truth).run : [])
    end

    # A regression is caught when one of its named checks fails differently
    # from how it fails on the unmodified system. Before the fixes land, some
    # checks already fail, so "fails" alone would prove nothing.
    def run_regression(regression, baseline, truth)
      checks = if regression.mutate
                 in_rolled_back_transaction do
                   regression.mutate.call
                   run_checks(McpClient.new, truth, ids: regression.caught_by)
                 end
               else
                 run_checks(McpClient.new(tools: regression.substitute), truth, ids: regression.caught_by)
               end

      before = baseline.to_h { |c| [c.id, signature(c)] }
      failing = checks.select { |c| c.fail? && before[c.id] != signature(c) }
      caught = failing.map(&:id) & regression.caught_by
      RegressionResult.new(
        id: regression.id, kind: regression.kind, finding: regression.finding, title: regression.title,
        provenance: regression.provenance,
        caught: caught.any?, caught_by: caught, failing: failing.map(&:id),
        evidence: failing.select { |c| caught.include?(c.id) }.to_h { |c| [c.id, evidence(c)] }
      )
    end

    # The largest single disagreement, which is what a reader wants to see.
    # A differential check's diffs are failing cases; show the case and its
    # first field-level difference.
    def evidence(check)
      diffs = Array(check.diffs).map { |d| d[:first_diff].is_a?(Hash) ? d[:first_diff].merge(case: d[:case]) : d }
      worst = diffs.select { |d| d.is_a?(Hash) && d[:ratio] }.max_by { |d| Math.log(d[:ratio].abs.nonzero? || 1).abs }
      (worst || diffs.first || {}).except(:delta, :diffs, :status)
    end

    def signature(check) = Digest::SHA256.hexdigest(JSON.generate([check.status, check.diffs]))

    def in_rolled_back_transaction
      result = nil
      ActiveRecord::Base.transaction do
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    end

    def meta
      {
        seed: @seed, cases_per_invariant: @cases,
        database: ActiveRecord::Base.connection.current_database,
        git_commit: `git rev-parse --short HEAD 2>/dev/null`.strip.presence,
        git_dirty: `git status --porcelain -- app lib eval ':!eval/reports' 2>/dev/null`.strip.present?,
        dataset: Oracle::Dataset::FILES.values.to_h do |name|
          [name, Digest::SHA256.file(File.join(Eval.data_dir, "#{name}.csv")).hexdigest[0, 12]]
        end,
        ruby: RUBY_VERSION, started_at: Time.now.utc.iso8601
      }
    end

    def timed(label)
      started = now
      result = yield
      @io.puts format("  %-28s %6.1fs", label, now - started)
      result
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
