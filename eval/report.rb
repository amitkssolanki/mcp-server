# frozen_string_literal: true

require "json"
require "yaml"

module Eval
  # Renders a Run::Result as a terminal report and as JSON.
  #
  # The fingerprint is a hash of every check's id, status and diffs, and of
  # every regression's verdict: everything except timings and the run's
  # start time. Two runs against the same data, code and seed produce the
  # same fingerprint, and that is how determinism is verified.
  class Report
    KINDS = %w[question invariant reconciliation].freeze

    def initialize(result, findings: YAML.safe_load_file(File.join(ROOT, "findings.yml")))
      @result = result
      @findings = findings
    end

    def passed?
      @result.checks.none? { |c| c.fail? || c.error? } && @result.regressions.all?(&:caught)
    end

    def fingerprint
      payload = {
        checks: @result.checks.map { |c| [c.id, c.status, c.diffs] },
        regressions: @result.regressions.map { |r| [r.id, r.caught, r.caught_by, r.failing] }
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))[0, 16]
    end

    def to_h
      {
        meta: @result.meta.merge(fingerprint: fingerprint, seconds: @result.seconds, passed: passed?),
        summary: summary,
        checks: @result.checks.map(&:to_h),
        regressions: @result.regressions.map(&:to_h),
        findings: findings_status
      }
    end

    def write_json(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(to_h))
    end

    def print(io = $stdout)
      m = @result.meta
      io.puts
      io.puts "MCP truth harness"
      io.puts "  database #{m[:database]}  commit #{m[:git_commit]}#{' (dirty)' if m[:git_dirty]}  seed #{m[:seed]}"
      io.puts

      KINDS.each do |kind|
        checks = @result.checks.select { |c| c.kind == kind }
        next if checks.empty?

        s = tally(checks)
        io.puts format("%-16s %3d   pass %3d   fail %3d   error %d", "#{kind.capitalize}s", checks.size, s["pass"], s["fail"], s["error"])
        checks.each { |c| io.puts line(c) }
        io.puts
      end

      if @result.regressions.any?
        caught = @result.regressions.count(&:caught)
        io.puts format("%-16s %3d   caught %d   missed %d", "Regressions", @result.regressions.size, caught,
                       @result.regressions.size - caught)
        @result.regressions.each do |r|
          io.puts format("  %-7s %-32s %s", r.caught ? "CAUGHT" : "MISSED", r.id, r.title)
          io.puts "          by #{r.caught_by.join(', ')}" if r.caught
          r.evidence.each { |check, e| io.puts "          #{check}: #{describe(e)}" }
          io.puts "          provenance: #{r.provenance}"
        end
        io.puts
      end

      failing = @result.checks.reject(&:pass?)
      if failing.any?
        io.puts "Failures by finding (eval/findings.yml)"
        by_finding(failing).each do |finding, checks|
          label = finding ? "#{finding['id']} [#{finding['triage']}/#{finding['scope']}] #{finding['title']}" : "UNTRIAGED"
          io.puts "  #{label}"
          io.puts "      #{checks.map(&:id).join(', ')}"
        end
        io.puts
      end

      io.puts format("Result: %s   fingerprint %s   %.1fs", passed? ? "PASS" : "FAIL", fingerprint, @result.seconds)
    end

    private

    def summary
      KINDS.to_h do |kind|
        checks = @result.checks.select { |c| c.kind == kind }
        [kind, { total: checks.size, **tally(checks).transform_keys(&:to_sym) }]
      end.merge(
        regressions: { total: @result.regressions.size, caught: @result.regressions.count(&:caught) },
        untriaged: by_finding(@result.checks.reject(&:pass?)).select { |f, _| f.nil? }.values.flatten.map(&:id)
      )
    end

    def findings_status
      @findings.map { |f| f.slice("id", "title", "triage", "scope", "status") }
    end

    def tally(checks) = Hash.new(0).merge(checks.map(&:status).tally)

    def line(c)
      head = format("  %-5s %-40s %7.2fs", c.status.upcase, c.id, c.seconds.to_f)
      return "#{head}  #{c.detail.to_s[0, 100]}" if c.error?
      return head if c.pass?

      "#{head}  #{Array(c.diffs).size} diff(s); #{describe(worst(c))}"
    end

    def worst(check)
      diffs = Array(check.diffs)
      diffs.select { |d| d[:ratio] }.max_by { |d| Math.log(d[:ratio].abs.nonzero? || 1).abs } || diffs.first || {}
    end

    def describe(d)
      return "" if d.nil? || d.empty?
      return d.except(:key).map { |k, v| "#{k}=#{v.inspect}" }.join(" ")[0, 160] unless d[:field]

      exp = d[:expected].is_a?(Array) ? "#{d[:expected].first(3)}..." : d[:expected]
      act = d[:actual].is_a?(Array) ? "#{d[:actual].first(3)}..." : d[:actual]
      ratio = d[:ratio] ? format(" (x%.4g)", d[:ratio]) : ""
      "#{d[:key]} #{d[:field]}: expected #{exp}, got #{act}#{ratio}"[0, 160]
    end

    # A check can evidence several findings; it is listed under each one.
    def by_finding(checks)
      grouped = Hash.new { |h, k| h[k] = [] }
      checks.each do |c|
        owners = @findings.select { |f| Array(f["checks"]).include?(c.id) }
        (owners.presence || [nil]).each { |f| grouped[f] << c }
      end
      grouped.sort_by { |f, _| f ? f["id"][1..].to_i : Float::INFINITY }.to_h
    end
  end
end
