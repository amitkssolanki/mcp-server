# frozen_string_literal: true

require "yaml"

module Eval
  # Runs canonical questions: each one calls a tool through MCP and compares
  # its structured output with the oracle's answer, field by field.
  #
  # A question is data (eval/questions/*.yml). Three shapes are supported:
  #
  #   rows:   a keyed table, e.g. revenue by month. `match: all` requires the
  #           same key set; `match: {top: N, rank_by:, order:}` requires the
  #           tool's rows to be the oracle's top N, in the oracle's order.
  #   record: a single object, e.g. one customer's summary.
  #   scalar: a single value at a path, e.g. search_orders' total_matches.
  class QuestionRunner
    # Every compared value is a rounded decimal on both sides, so equal values
    # are equal floats. The tolerance only absorbs float representation noise
    # and never covers a real cent.
    TOLERANCE = 1e-6

    def self.load(glob = Rails.root.join("eval/questions/*.yml"))
      Dir[glob].sort.flat_map { |f| YAML.safe_load_file(f, permitted_classes: [Date]) }
    end

    def initialize(client:, expectations:)
      @client = client
      @expectations = expectations
    end

    def run(question)
      q = question.transform_keys(&:to_s)
      picked = q["pick"] ? @expectations.pick(q["pick"]) : {}
      args = interpolate(q["args"] || {}, picked)
      expected = @expectations.fetch(q.dig("expected", "oracle"), interpolate(q.dig("expected", "params") || {}, picked))

      result = @client.call(q.fetch("tool"), args)
      base = { id: q.fetch("id"), kind: "question", title: q["title"], metrics: q["metrics"],
               tool: q["tool"], arguments: args, seconds: result.seconds.round(3) }

      if result.error
        return Check.new(**base, status: "error", detail: result.error_message)
      end

      diffs, expected_summary, actual_summary = compare(q, expected, result.structured || {})
      Check.new(**base, status: diffs.empty? ? "pass" : "fail",
                expected: expected_summary, actual: actual_summary, diffs: diffs.map(&:to_h))
    rescue StandardError => e
      Check.new(id: question["id"], kind: "question", title: question["title"], status: "error",
                detail: "#{e.class}: #{e.message}")
    end

    private

    def compare(q, expected, structured)
      if q["scalar"]
        actual = dig(structured, q["scalar"])
        diffs = equal?(expected, actual) ? [] : [Diff.new(key: q["scalar"], field: q["scalar"], expected: expected, actual: actual)]
        return [diffs, expected, actual]
      end

      fields = q.fetch("fields")
      if q["record"]
        record = q["record"] == true ? structured : dig(structured, q["record"])
        diffs = compare_fields("(record)", fields, expected, record || {})
        return [diffs, pick_fields(expected, fields.values), pick_fields(record || {}, fields.keys)]
      end

      compare_rows(q, expected, structured)
    end

    def compare_rows(q, expected, structured)
      fields = q.fetch("fields")
      key_field = q.fetch("key")
      normalize = key_normalizer(q["key_format"])

      rows = Array(dig(structured, q.fetch("rows")))
      actual = {}
      diffs = []
      rows.each do |row|
        key = normalize.call(row[key_field])
        diffs << Diff.new(key: key, field: "(duplicate row)", expected: 1, actual: 2) if actual.key?(key)
        actual[key] = row
      end
      expected = expected.transform_keys { |k| normalize.call(k) }

      wanted_keys = expected_keys(q["match"], expected)
      if ranked?(q["match"])
        # Ranking is judged on the oracle's values in the tool's order, not on
        # key identity. Tied rows may come back in any order, and any of the
        # rows tied at the cut-off is an acceptable last entry.
        rank_by = q["match"].fetch("rank_by").to_sym
        actual_order = rows.map { |r| normalize.call(r[key_field]) }
        wanted_values = wanted_keys.map { |k| expected.dig(k, rank_by) }
        actual_values = actual_order.map { |k| expected.dig(k, rank_by) }
        unless actual_values == wanted_values && (actual_order - expected.keys).empty?
          diffs << Diff.new(key: "(ranking)", field: rank_by.to_s, expected: wanted_keys, actual: actual_order)
        end
        wanted_keys = actual_order & expected.keys if actual_values == wanted_values
      else
        (wanted_keys - actual.keys).each { |k| diffs << Diff.new(key: k, field: "(row)", expected: "present", actual: "missing") }
        (actual.keys - wanted_keys).each { |k| diffs << Diff.new(key: k, field: "(row)", expected: "absent", actual: "present") }
      end

      (wanted_keys & actual.keys).each do |k|
        diffs.concat(compare_fields(k, fields, expected.fetch(k), actual.fetch(k)))
      end

      [diffs, { rows: wanted_keys.size }, { rows: rows.size }]
    end

    def compare_fields(key, fields, expected, actual)
      fields.filter_map do |tool_field, oracle_field|
        e = expected[oracle_field.to_sym]
        a = dig(actual, tool_field)
        Diff.new(key: key, field: tool_field, expected: e, actual: a) unless equal?(e, a)
      end
    end

    def expected_keys(match, expected)
      return expected.keys.sort unless ranked?(match)

      rank_by = match.fetch("rank_by").to_sym
      direction = match.fetch("order", "desc")
      ranked = expected.sort_by do |key, v|
        value = v[rank_by]
        # nils last in either direction, then key as a deterministic tiebreak
        [value.nil? ? 1 : 0, value.nil? ? 0 : (direction == "desc" ? -value : value), key.to_s]
      end
      ranked.first(match.fetch("top")).map(&:first)
    end

    def ranked?(match) = match.is_a?(Hash) && match["top"]

    def equal?(expected, actual)
      return expected == actual if expected.nil? || actual.nil?
      return (expected - actual).abs <= TOLERANCE if expected.is_a?(Numeric) && actual.is_a?(Numeric)

      expected == actual
    end

    def key_normalizer(format)
      case format
      when "category" then ->(v) { v.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "") }
      else ->(v) { v.to_s }
      end
    end

    def pick_fields(hash, keys) = keys.to_h { |k| [k.to_s, hash[k.to_sym] || hash[k.to_s]] }

    # "a.b" digs into nested objects; "items#count" is the length of an array.
    def dig(hash, path)
      path, count = path.to_s.split("#", 2)
      value = path.split(".").reduce(hash) { |h, k| h.is_a?(Hash) ? h[k] : nil }
      count == "count" ? value&.size : value
    end

    def interpolate(value, picked)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, interpolate(v, picked)] }
      when String then picked.empty? ? value : format(value, **picked)
      else value
      end
    end
  end
end
