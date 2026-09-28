# frozen_string_literal: true

module Eval
  # Turns a question's `expected:` block into oracle values. Each entry here
  # is a thin adapter: it calls Oracle::Truth and applies the same filtering a
  # tool's arguments ask for (min_orders, a seller's state). No metric logic
  # lives here. That belongs in the oracle.
  class Expectations
    def initialize(truth)
      @truth = truth
    end

    def fetch(name, params)
      params = symbolize(params)
      raise ArgumentError, "unknown oracle query #{name}" unless respond_to?("q_#{name}", true)

      send("q_#{name}", **params)
    end

    # Values a question can interpolate into its tool arguments, e.g. a
    # customer picked because their history exposes a known defect.
    def pick(name)
      raise ArgumentError, "unknown pick #{name}" unless respond_to?("pick_#{name}", true)

      send("pick_#{name}")
    end

    private

    def q_revenue_by(dimension:, from: nil, to: nil)
      @truth.revenue_by(dimension: dimension, from: from, to: to)
    end

    def q_categories
      @truth.categories
    end

    def q_sellers(min_orders: 50, seller_state: nil)
      @truth.sellers(seller_state: seller_state).select { |_, v| v[:orders] >= min_orders }
    end

    def q_delivery_by(dimension:, from: nil, to: nil, min_orders: 0)
      @truth.delivery_by(dimension: dimension, from: from, to: to).select { |_, v| v[:orders] >= min_orders }
    end

    def q_search_count(**filters)
      @truth.search_orders(**filters).size
    end

    def q_customer(unique_id:)
      @truth.customer(unique_id)
    end

    # The first customer, in id order, with a completed order that carries
    # more than one review. That order is where a review join fans out.
    def pick_multi_review_customer
      orders = @truth.multi_review_order_ids.map { |id| @truth.order(id) }.select(&:completed)
      { unique_id: orders.map(&:customer_unique_id).min }
    end

    def symbolize(params) = (params || {}).to_h.transform_keys(&:to_sym)
  end
end
