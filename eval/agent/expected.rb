# frozen_string_literal: true

module Eval
  module Agent
    # Expected answers for the agent questions, computed from the oracle. Each
    # entry reads one value out of an existing Oracle::Truth query; no metric
    # is defined here. Picks (which customer, order or product a question
    # names) reuse the Day 2 Expectations picks.
    class Expected
      def initialize(truth)
        @truth = truth
        @expectations = Expectations.new(truth)
      end

      def pick(name) = @expectations.pick(name)

      def fetch(name, params = {})
        params = params.to_h.transform_keys(&:to_sym)
        send("q_#{name}", **params)
      end

      private

      def q_orders_placed = @truth.orders.size
      def q_orders_completed = @truth.completed_orders.size

      def q_search_count(**filters) = @truth.search_orders(**filters).size

      def q_revenue_field(dimension:, key:, field:)
        @truth.revenue_by(dimension: dimension).fetch(key).fetch(field.to_sym)
      end

      def q_category_field(category:, field:) = @truth.categories.fetch(category).fetch(field.to_sym)

      def q_category_gross_field(category:) = @truth.revenue_by(dimension: "category").fetch(category)[:gross_revenue]

      def q_payment_value(method:, from:, to:)
        @truth.revenue_by(dimension: "payment_method", from: from, to: to).fetch(method)[:payment_value]
      end

      def q_delivery_field(dimension:, key:, field:)
        @truth.delivery_by(dimension: dimension).fetch(key).fetch(field.to_sym)
      end

      # Late delivered orders over all delivered orders, as a percentage.
      def q_overall_late_rate
        buckets = @truth.delivery_by(dimension: "bucket").values
        (Rational(buckets.sum { |b| b[:late_orders] } * 100, buckets.sum { |b| b[:orders] })).round(2).to_f
      end

      def q_worst_delivery_state(min_orders:)
        @truth.delivery_by(dimension: "state").select { |_, v| v[:orders] >= min_orders }
              .min_by { |k, v| [v[:avg_review], k] }.first
      end

      def q_worst_seller(min_orders:)
        @truth.sellers.select { |_, v| v[:orders] >= min_orders && v[:avg_review] }
              .min_by { |k, v| [v[:avg_review], k] }.first
      end

      def q_top_key(query:, rank:)
        pool = case query
               when "category_gross" then @truth.revenue_by(dimension: "category").transform_values { |v| v[:gross_revenue] }
               when "seller_item" then @truth.sellers.transform_values { |v| v[:item_revenue] }
               else raise ArgumentError, query
               end
        pool.max_by { |k, v| [rank == "desc" ? v : -v, k] }.first
      end

      def q_customer_field(unique_id:, field:) = @truth.customer(unique_id).fetch(field.to_sym)
      def q_order_field(order_id:, field:) = @truth.order_summary(order_id).fetch(field.to_sym)
      def q_product_field(product_id:, field:) = @truth.product(product_id).fetch(field.to_sym)
    end
  end
end
