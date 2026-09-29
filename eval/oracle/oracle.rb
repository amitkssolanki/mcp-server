# frozen_string_literal: true

require "bigdecimal"
require "time"

module Eval
  module Oracle
    # Ground truth for every metric in docs/METRICS.md, computed from the raw
    # CSVs (see Dataset) with plain Ruby enumerables.
    #
    # This is deliberately *not* a translation of the tools' SQL. The tools
    # join Spree tables and aggregate in Postgres. Here, each order is first
    # resolved into one fact record (its status, customer state, score by the
    # review policy, lateness and items), and every metric is a fold over
    # those records. The two paths share the CSV files and the written
    # definitions, and nothing else. See eval/README.md for the full list of
    # shared assumptions.
    class Truth
      COMPLETED = %w[delivered shipped invoiced processing approved].freeze
      UNCATEGORISED = "uncategorised"

      # One resolved order. Everything a metric could want is precomputed here
      # once, so no metric can accidentally reach back through a join.
      OrderFact = Struct.new(
        :id, :status, :completed, :customer_unique_id, :state, :purchased_on, :month,
        :days_late, :delivery_days, :score, :items, :item_revenue, :freight, :gross,
        keyword_init: true
      )

      attr_reader :dataset

      def initialize(dataset)
        @dataset = dataset
        build!
      end

      # --- building blocks ------------------------------------------------

      def order(id) = @orders.fetch(id)
      def orders = @orders.values
      def completed_orders = @completed ||= orders.select(&:completed)
      def delivered_orders = @delivered ||= completed_orders.select(&:days_late)

      # Category key for a product: the English slug, the Portuguese slug when
      # there is no translation, or "uncategorised".
      def category_of(product_id)
        pt = dataset.products.fetch(product_id).category_pt
        return UNCATEGORISED if pt.nil?

        dataset.translations.fetch(pt, pt)
      end

      # --- metrics --------------------------------------------------------

      # revenue_report. Groups completed orders or items by a dimension.
      # month/state partition orders; category/seller allocate per item;
      # payment_method sums payment values.
      def revenue_by(dimension:, from: nil, to: nil)
        pool = in_range(completed_orders, from, to)
        return payments_by_method(pool) if dimension == "payment_method"

        buckets = Hash.new { |h, k| h[k] = { order_ids: Set.new, item_revenue: 0, freight: 0 } }
        pool.each do |o|
          o.items.each do |item|
            key = case dimension
                  when "month"    then o.month
                  when "state"    then o.state
                  when "category" then category_of(item.product_id)
                  when "seller"   then item.seller_id
                  else raise ArgumentError, "unknown dimension #{dimension}"
                  end
            b = buckets[key]
            b[:order_ids] << o.id
            b[:item_revenue] += item.price
            b[:freight] += item.freight
          end
          # An order with no items still counts as an order in its month/state.
          buckets[o.month][:order_ids] << o.id if dimension == "month" && o.items.empty?
          buckets[o.state][:order_ids] << o.id if dimension == "state" && o.items.empty?
        end

        buckets.transform_values do |b|
          gross = b[:item_revenue] + b[:freight]
          orders = b[:order_ids].size
          { orders: orders, item_revenue: money(b[:item_revenue]), freight: money(b[:freight]),
            gross_revenue: money(gross), avg_order_value: orders.zero? ? 0.0 : mean(gross, orders, 2) }
        end
      end

      # list_categories.
      def categories
        products = Hash.new(0)
        dataset.products.each_key { |pid| products[category_of(pid)] += 1 }

        sold = Hash.new { |h, k| h[k] = { units: 0, item_revenue: 0, scores: {} } }
        completed_orders.each do |o|
          o.items.each do |item|
            b = sold[category_of(item.product_id)]
            b[:units] += 1
            b[:item_revenue] += item.price
            b[:scores][o.id] = o.score if o.score # keyed by order: counts once
          end
        end

        products.keys.to_h do |cat|
          b = sold[cat]
          [cat, { products: products[cat], units_sold: b[:units], item_revenue: money(b[:item_revenue]),
                  avg_review: mean_of(b[:scores].values, 2) }]
        end
      end

      # seller_performance. Returns every seller that sold in a completed order;
      # min_orders and ranking are applied by the caller.
      def sellers(seller_state: nil)
        acc = Hash.new { |h, k| h[k] = { orders: {}, item_revenue: 0 } }
        completed_orders.each do |o|
          o.items.each do |item|
            next if seller_state && dataset.sellers.fetch(item.seller_id).state != seller_state

            b = acc[item.seller_id]
            b[:orders][o.id] = o
            b[:item_revenue] += item.price
          end
        end

        acc.transform_values do |b|
          orders = b[:orders].values
          { orders: orders.size, item_revenue: money(b[:item_revenue]),
            avg_review: mean_of(orders.filter_map(&:score), 2),
            avg_days_late: mean_of(orders.filter_map(&:days_late), 1) }
        end
      end

      # delivery_performance.
      def delivery_by(dimension:, from: nil, to: nil)
        acc = Hash.new { |h, k| h[k] = {} }
        in_range(delivered_orders, from, to).each do |o|
          keys = case dimension
                 when "bucket"   then [lateness_bucket(o.days_late)]
                 when "state"    then [o.state]
                 when "category" then o.items.map { |i| category_of(i.product_id) }.uniq
                 when "seller"   then o.items.map(&:seller_id).uniq
                 else raise ArgumentError, "unknown dimension #{dimension}"
                 end
          keys.each { |k| acc[k][o.id] = o }
        end

        acc.transform_values do |by_id|
          os = by_id.values
          late = os.count { |o| o.days_late.positive? }
          { orders: os.size, late_orders: late, late_rate: pct(late, os.size),
            avg_days_late: mean_of(os.map(&:days_late), 1),
            avg_delivery_days: mean_of(os.map(&:delivery_days), 1),
            avg_review: mean_of(os.filter_map(&:score), 2),
            min_days_late: os.map(&:days_late).min }
        end
      end

      # search_orders. Placed orders matching every filter, by the definitions
      # in METRICS.md. Returns the matching facts; callers count them.
      def search_orders(status: nil, from: nil, to: nil, min_total: nil, max_total: nil,
                        min_days_late: nil, max_review_score: nil, customer_state: nil)
        in_range(orders, from, to).select do |o|
          (status.nil? || o.status == status) &&
            (min_total.nil? || o.gross >= BigDecimal(min_total.to_s)) &&
            (max_total.nil? || o.gross <= BigDecimal(max_total.to_s)) &&
            (min_days_late.nil? || (o.days_late && o.days_late >= min_days_late)) &&
            (max_review_score.nil? || (o.score && o.score <= max_review_score)) &&
            (customer_state.nil? || o.state == customer_state.upcase)
        end
      end

      # get_order. One order's totals and the score its review policy gives it.
      # Totals are for the order as placed, whatever its status.
      def order_summary(order_id)
        o = order(order_id)
        { status: o.status, item_total: money(o.item_revenue), freight: money(o.freight), total: money(o.gross),
          line_items: o.items.size, sellers: o.items.map(&:seller_id).uniq.size, review_score: o.score,
          days_late: o.days_late }
      end

      # get_product. Sales figures are over completed orders.
      def product(product_id)
        sold = completed_orders.flat_map { |o| o.items.select { |i| i.product_id == product_id }.map { |i| [o, i] } }
        orders = sold.map(&:first).uniq(&:id)
        { units_sold: sold.size, item_revenue: money(sold.sum(BigDecimal("0")) { |_, i| i.price }),
          orders: orders.size, avg_review: mean_of(orders.filter_map(&:score), 2),
          avg_days_late: mean_of(orders.filter_map(&:days_late), 1) }
      end

      # search_products filtered to one category: each product's sales.
      def products_in_category(category)
        per_product = dataset.products.each_key.select { |pid| category_of(pid) == category }
                                      .to_h { |pid| [pid, { units_sold: 0, item_revenue: BigDecimal("0") }] }
        completed_orders.each do |o|
          o.items.each do |i|
            next unless per_product.key?(i.product_id)

            per_product[i.product_id][:units_sold] += 1
            per_product[i.product_id][:item_revenue] += i.price
          end
        end
        per_product.transform_values { |v| v.merge(item_revenue: money(v[:item_revenue])) }
      end

      # Products ranked by completed units sold, then revenue, then id.
      def best_selling_product
        units = Hash.new(0)
        revenue = Hash.new(BigDecimal("0"))
        completed_orders.each { |o| o.items.each { |i| units[i.product_id] += 1; revenue[i.product_id] += i.price } }
        units.keys.min_by { |pid| [-units[pid], -revenue[pid], pid] }
      end

      # The customer with the most placed orders (ties: lowest id).
      def most_frequent_customer
        @orders_by_customer.min_by { |uid, os| [-os.size, uid] }.first
      end

      # find_customer.
      def customer(unique_id)
        placed = @orders_by_customer.fetch(unique_id, [])
        completed = placed.select(&:completed)
        { orders: placed.size, lifetime_value: money(completed.sum(BigDecimal("0"), &:gross)),
          avg_review: mean_of(completed.filter_map(&:score), 2) }
      end

      # Customers whose history includes an order with more than one review:
      # the population the review-policy bug inflated. Sorted for determinism.
      def customers_with_multi_review_orders
        @multi_review_order_ids.filter_map { |oid| @orders[oid]&.customer_unique_id }.uniq.sort
      end

      def multi_review_order_ids = @multi_review_order_ids

      # Orders where the review policy changes the answer: the most recent
      # review's score differs from the score of the first review in the file.
      # Taking "any review" gets these wrong.
      def policy_sensitive_order_ids = @policy_sensitive_order_ids

      def lateness_bucket(days)
        if days <= 0 then "on time or early"
        elsif days <= 3 then "1-3 days late"
        elsif days <= 7 then "4-7 days late"
        else "more than a week late"
        end
      end

      private

      def build!
        items_by_order = dataset.items.group_by(&:order_id)
        reviews_by_order = dataset.reviews.group_by(&:order_id)
        @multi_review_order_ids = reviews_by_order.select { |_, rs| rs.size > 1 }.keys.sort
        @policy_sensitive_order_ids = @multi_review_order_ids.select do |oid|
          reviews_by_order[oid].first.score != latest_review(reviews_by_order[oid]).score
        end

        @orders = dataset.orders.to_h do |o|
          customer = dataset.customers.fetch(o.customer_id)
          items = items_by_order.fetch(o.id, [])
          item_revenue = items.sum(BigDecimal("0"), &:price)
          freight = items.sum(BigDecimal("0"), &:freight)
          [o.id, OrderFact.new(
            id: o.id, status: o.status, completed: COMPLETED.include?(o.status),
            customer_unique_id: customer.unique_id, state: customer.state,
            purchased_on: o.purchased_at&.slice(0, 10), month: o.purchased_at&.slice(0, 7),
            days_late: day_diff(o.estimated_at, o.delivered_at),
            delivery_days: day_diff(o.purchased_at, o.delivered_at),
            score: latest_review(reviews_by_order[o.id])&.score,
            items: items, item_revenue: item_revenue, freight: freight, gross: item_revenue + freight
          )]
        end
        @orders_by_customer = @orders.values.group_by(&:customer_unique_id)
      end

      # The review policy: latest creation date, then latest answer, then
      # highest review id. ISO timestamps compare correctly as strings.
      def latest_review(reviews)
        return nil if reviews.nil? || reviews.empty?

        reviews.max_by { |r| [r.created_at.to_s, r.answered_at.to_s, r.id] }
      end

      # Whole days between two "YYYY-MM-DD HH:MM:SS" stamps, rounded half away
      # from zero. Rational arithmetic, so there is no float edge at .5.
      def day_diff(from, to)
        return nil if from.nil? || to.nil?

        Rational(parse(to).to_i - parse(from).to_i, 86_400).round
      end

      def parse(stamp)
        Time.strptime("#{stamp} +0000", "%Y-%m-%d %H:%M:%S %z")
      end

      def in_range(pool, from, to)
        pool.select do |o|
          (from.nil? || (o.purchased_on && o.purchased_on >= from)) &&
            (to.nil? || (o.purchased_on && o.purchased_on <= to))
        end
      end

      def payments_by_method(pool)
        ids = pool.to_set(&:id)
        acc = Hash.new { |h, k| h[k] = { order_ids: Set.new, value: 0 } }
        dataset.payments.each do |p|
          next unless ids.include?(p.order_id)

          acc[p.type][:order_ids] << p.order_id
          acc[p.type][:value] += p.value
        end
        acc.transform_values { |b| { orders: b[:order_ids].size, payment_value: money(b[:value]) } }
      end

      def money(value) = BigDecimal(value.to_s).round(2, :half_up).to_f

      def mean(sum, count, digits) = Rational(BigDecimal(sum.to_s).to_r, count).round(digits).to_f

      def mean_of(values, digits)
        return nil if values.empty?

        Rational(values.sum(0r) { |v| v.to_r }, values.size).round(digits).to_f
      end

      def pct(part, whole)
        return 0.0 if whole.zero?

        Rational(part * 100, whole).round(1).to_f
      end
    end
  end
end
