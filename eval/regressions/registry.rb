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
    Regression = Struct.new(:id, :kind, :title, :provenance, :substitute, :mutate, :tools, :caught_by, :finding,
                            keyword_init: true)

    def self.all
      HISTORICAL + PRE_FIX
    end

    HISTORICAL = [
      Regression.new(
        id: "H1-category-revenue-fan-out", kind: "historical",
        title: "Category revenue summed over a line-item x review join (the 42x bug)",
        provenance: "reconstructed from the article; on the pre-fix product counters it reproduces the " \
                    "article's R$52,545,084 exactly (R$52,474,005 on today's counters, still ~42x)",
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
        mutate: DROP_33_PAYMENTS, tools: %w[revenue_report],
        caught_by: %w[reconcile-row-counts reconcile-value-sums revenue-by-payment-method]
      )
    ].freeze

    # The tools as they were before the fixes this harness prompted, copied
    # verbatim from git (eval/regressions/pre_fix/). Each one must stay
    # caught, so a fix cannot quietly come undone.
    VERBATIM = "verbatim from git at 9fa9b02, the code the harness first ran against"

    PRE_FIX = [
      Regression.new(
        id: "P1-search-orders", kind: "pre-fix", finding: "F1",
        title: "search_orders joined every review, listing twice-reviewed orders twice",
        provenance: VERBATIM, substitute: [PreFix::SearchOrders],
        caught_by: %w[search-all-placed search-rj-one-star search-black-friday-day search-very-late
                      search-big-sp-orders search-late-and-unhappy search-cancelled-in-2018
                      complete-listing-matches-count search-orders-random-filters]
      ),
      Regression.new(
        id: "P2-list-categories", kind: "pre-fix", finding: "F2",
        title: "list_categories averaged reviews over every order and every review",
        provenance: VERBATIM, substitute: [PreFix::ListCategories],
        caught_by: %w[categories-all categories-worst-reviewed]
      ),
      Regression.new(
        id: "P3-delivery-performance", kind: "pre-fix", finding: "F1, F8",
        title: "delivery_performance counted twice-reviewed orders twice, and cancelled orders",
        provenance: VERBATIM, substitute: [PreFix::DeliveryPerformance],
        caught_by: %w[delivery-by-bucket delivery-by-state delivery-by-category-worst delivery-by-seller-worst
                      delivery-buckets-2017-q4 delivery-random-windows partitions-sum-to-total]
      ),
      Regression.new(
        id: "P4-find-customer", kind: "pre-fix", finding: "F1, F9",
        title: "find_customer matched substrings and doubled twice-reviewed orders",
        provenance: VERBATIM, substitute: [PreFix::FindCustomer],
        caught_by: %w[customer-with-multi-review-order customer-most-orders customers-random find-customer-exact-match]
      ),
      Regression.new(
        id: "P5-seller-performance", kind: "pre-fix", finding: "F2, F5",
        title: "seller_performance counted cancelled orders and every review",
        provenance: VERBATIM, substitute: [PreFix::SellerPerformance],
        caught_by: %w[sellers-top-revenue sellers-worst-reviewed sellers-latest-deliverers sellers-in-rio-by-revenue
                      sellers-random-states same-metric-same-number]
      ),
      Regression.new(
        id: "P6-get-order", kind: "pre-fix", finding: "F2",
        title: "get_order showed whichever review the database returned first",
        provenance: VERBATIM, substitute: [PreFix::GetOrder],
        caught_by: %w[order-multi-seller-multi-review]
      ),
      Regression.new(
        id: "P7-get-product", kind: "pre-fix", finding: "F2, F5",
        title: "get_product averaged over line items and cancelled orders",
        provenance: VERBATIM, substitute: [PreFix::GetProduct],
        caught_by: %w[product-best-seller products-random]
      ),
      Regression.new(
        id: "P8-revenue-report", kind: "pre-fix", finding: "F3, F4, F6, F7",
        title: "revenue_report credited whole orders to categories, sellers and payment methods",
        provenance: VERBATIM, substitute: [PreFix::RevenueReport],
        caught_by: %w[revenue-by-category-top20 revenue-by-seller-top20 revenue-by-payment-method
                      revenue-by-month-split revenue-by-category-split revenue-by-seller-split
                      revenue-by-payment-method-2018 overlapping-groups-not-additive same-metric-same-number
                      partitions-sum-to-total revenue-report-random-windows]
      ),
      Regression.new(
        id: "P9-product-counters", kind: "pre-fix", finding: "F5",
        title: "product sales counters included cancelled and unavailable orders",
        provenance: "importer SQL verbatim from git at 9fa9b02, applied in a rolled-back transaction",
        mutate: PreFix::PRODUCT_COUNTERS, tools: %w[list_categories search_products get_product],
        caught_by: %w[categories-all categories-worst-reviewed products-top-health-beauty product-best-seller
                      products-random]
      )
    ].freeze
  end
end
