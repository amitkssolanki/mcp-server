# frozen_string_literal: true

module Eval
  # One verdict from the harness: a question, an invariant or a reconciliation.
  # Every check records what it compared, not just whether it passed, so a
  # failure can be triaged from the report alone.
  #
  # `seconds` is the only field allowed to vary between identical runs; it is
  # left out of the fingerprint (see Report#fingerprint).
  Check = Struct.new(
    :id, :kind, :title, :status, :metrics, :tool, :arguments,
    :expected, :actual, :diffs, :detail, :seconds,
    keyword_init: true
  ) do
    def pass? = status == "pass"
    def fail? = status == "fail"
    def error? = status == "error"

    def to_h
      super.compact.reject { |_, v| v.respond_to?(:empty?) && v.empty? }
    end
  end

  # A single field disagreement, keyed by the row it came from.
  Diff = Struct.new(:key, :field, :expected, :actual, keyword_init: true) do
    def delta
      return nil unless expected.is_a?(Numeric) && actual.is_a?(Numeric)

      (actual - expected).round(6)
    end

    def ratio
      return nil unless expected.is_a?(Numeric) && actual.is_a?(Numeric) && !expected.zero?

      (actual.to_f / expected).round(4)
    end

    def to_h = super.merge(delta: delta, ratio: ratio).compact
  end
end
