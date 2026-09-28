# frozen_string_literal: true

module Eval
  module Regressions
    # A known-bad version of the system that the harness must catch.
    #
    # `substitute` swaps tool implementations by name. `mutate` changes the
    # database inside a transaction that is always rolled back. `caught_by`
    # names the checks that are supposed to notice. A regression counts as
    # caught when at least one of them fails *differently* from how it fails
    # on the unmodified system (see Run#run_regression).
    Regression = Struct.new(:id, :kind, :title, :provenance, :substitute, :mutate, :caught_by, keyword_init: true)

    def self.all
      HISTORICAL + PRE_FIX
    end

    HISTORICAL = [
      Regression.new(
        id: "H1-category-revenue-fan-out", kind: "historical",
        title: "Category revenue summed over a line-item x review join (the 42x bug)",
        provenance: "reconstructed from the article; reproduces its R$52,545,084 exactly",
        substitute: [CategoryRevenueFanOut],
        caught_by: %w[categories-all partitions-sum-to-total same-metric-same-number]
      ),
      Regression.new(
        id: "H2-seller-average-fan-out", kind: "historical",
        title: "Seller review average taken over line items instead of orders (3.81 reported as 2.57)",
        provenance: "reconstructed from the article; reproduces its 3.81 -> 2.57 exactly",
        substitute: [SellerAverageFanOut],
        caught_by: %w[sellers-top-revenue sellers-worst-reviewed same-metric-same-number]
      ),
      Regression.new(
        id: "H3-silently-dropped-payments", kind: "historical",
        title: "33 payment rows silently missing after import (the insert_all bug)",
        provenance: "simulated effect; the original index/column combination is not recoverable",
        mutate: DROP_33_PAYMENTS,
        caught_by: %w[reconcile-row-counts reconcile-value-sums revenue-by-payment-method]
      )
    ].freeze

    # Filled in once the defects the harness found are fixed: the pre-fix
    # implementations, verbatim, so the fixes stay fixed.
    PRE_FIX = [].freeze
  end
end
