# frozen_string_literal: true

require "date"

module Eval
  # Properties the tools must satisfy among themselves, with no oracle
  # involved. The oracle says what the right answer is. These say which
  # answers cannot all be right at once, so they still catch bugs the
  # question bank never asked about.
  #
  # Anything random draws from Random.new(seed), so a run is reproducible
  # from its seed. The seed is printed in every report.
  class Invariants
    FIRST_DAY = Date.new(2016, 9, 4)
    LAST_DAY = Date.new(2018, 10, 17)
    # Groupings where an order can land in several buckets: order counts do
    # not add up across them.
    OVERLAPPING = %w[category seller payment_method].freeze

    def self.all = instance_methods(false).grep(/\Acheck_/).sort

    def initialize(client:, seed:, cases: 25)
      @client = client
      @seed = seed
      @cases = cases
    end

    def run(only: nil)
      names = self.class.all
      names &= Array(only).map { |n| :"check_#{n.to_s.tr('-', '_')}" } if only
      names.map { |name| timed(name) { send(name) } }
    end

    # Which tools each invariant exercises, so a regression run can skip the
    # ones a substituted tool cannot affect.
    TOOLS = {
      check_unique_keys: %w[revenue_report list_categories seller_performance delivery_performance],
      check_value_bounds: %w[revenue_report list_categories seller_performance delivery_performance],
      check_partitions_sum_to_total: %w[revenue_report list_categories],
      check_overlapping_groups_not_additive: %w[revenue_report],
      check_same_metric_same_number: %w[revenue_report list_categories seller_performance],
      check_complete_listing_matches_count: %w[search_orders],
      check_narrower_filter_never_counts_more: %w[search_orders revenue_report],
      check_adjacent_date_windows_partition: %w[search_orders revenue_report],
      check_find_customer_exact_match: %w[find_customer]
    }.freeze

    # Every grouped result has one row per key.
    def check_unique_keys
      failures = grouped_outputs.filter_map do |label, rows, key|
        keys = rows.map { |r| r[key] }
        dupes = keys.tally.select { |_, n| n > 1 }.keys
        { output: label, duplicate_keys: dupes.first(5) } if dupes.any?
      end
      verdict("unique-keys", "Every grouped result has exactly one row per key", failures,
              cases: grouped_outputs.size)
    end

    # Review scores are 1-5, percentages 0-100, counts and money non-negative.
    def check_value_bounds
      failures = []
      grouped_outputs.each do |label, rows, key|
        rows.each do |r|
          bad = []
          bad << "avg_review=#{r['avg_review']}" if r["avg_review"] && !r["avg_review"].between?(1, 5)
          bad << "late_rate=#{r['late_rate']}" if r["late_rate"] && !r["late_rate"].between?(0, 100)
          %w[orders revenue units_sold late_orders].each do |f|
            bad << "#{f}=#{r[f]}" if r[f].is_a?(Numeric) && r[f].negative?
          end
          failures << { output: label, key: r[key], problems: bad } if bad.any?
        end
      end
      verdict("value-bounds", "Scores within 1-5, rates within 0-100, no negative counts or money", failures,
              cases: grouped_outputs.sum { |_, rows, _| rows.size })
    end

    # Groupings that partition the same population must agree on its total.
    # Month and state both partition completed orders, so the two must match
    # on orders and on revenue. Categories partition items, so category item
    # revenue must add up to the month breakdown's item revenue.
    def check_partitions_sum_to_total
      month = rows("revenue_report", group_by: "month")
      state = rows("revenue_report", group_by: "state", limit: 50)
      categories = rows("list_categories", {}, "categories")
      failures = []
      failures << compare_totals("orders: month vs state", sum(month, "orders"), sum(state, "orders"))
      failures << compare_totals("revenue: month vs state", sum(month, "revenue"), sum(state, "revenue"))
      month_items = month.all? { |r| r.key?("item_revenue") } ? sum(month, "item_revenue") : nil
      failures << compare_totals("item revenue: list_categories vs revenue_report(month)",
                                 month_items, sum(categories, "revenue"))
      verdict("partitions-sum-to-total", "Partitions of the same population agree on its total",
              failures.compact, cases: 3)
    end

    # A grouping where orders overlap must not present an additive order
    # total, in either the structured output or the text.
    def check_overlapping_groups_not_additive
      failures = OVERLAPPING.filter_map do |group|
        result = @client.call("revenue_report", "group_by" => group, "limit" => 50)
        totals = result.structured&.dig("totals") || {}
        claims = []
        claims << "structured totals.orders=#{totals['orders']}" if totals.key?("orders")
        claims << "text states an order total" if result.text.to_s.match?(/Total across shown rows: [\d,.]+ orders/)
        { group_by: group, claims: claims } if claims.any?
      end
      verdict("overlapping-groups-not-additive",
              "Order counts are never summed across overlapping buckets (category, seller, payment method)",
              failures, cases: OVERLAPPING.size)
    end

    # When two tools report the same named metric for the same thing, the
    # numbers are the same. Category item revenue appears in list_categories
    # and in revenue_report(category); seller item revenue in
    # seller_performance and revenue_report(seller).
    def check_same_metric_same_number
      failures = []

      listed = rows("list_categories", {}, "categories").to_h { |r| [r["category"], r["revenue"]] }
      rows("revenue_report", group_by: "category", limit: 50).each do |r|
        other = r.fetch("item_revenue", r["revenue"])
        next if listed[r["category"]] == other

        failures << { metric: "category item revenue", key: r["category"],
                      list_categories: listed[r["category"]], revenue_report: other }
      end

      ranked = rows("seller_performance", { sort: "revenue", min_orders: 1, limit: 50 }, "sellers")
                 .to_h { |r| [r["seller"], r["revenue"]] }
      rows("revenue_report", group_by: "seller", limit: 50).each do |r|
        next unless ranked.key?(r["seller"])

        other = r.fetch("item_revenue", r["revenue"])
        next if ranked[r["seller"]] == other

        failures << { metric: "seller item revenue", key: r["seller"],
                      seller_performance: ranked[r["seller"]], revenue_report: other }
      end

      verdict("same-metric-same-number", "Two tools reporting the same named metric agree", failures,
              cases: 2, sample: failures.first(6))
    end

    # A search that fits in one page must list exactly `total_matches`
    # distinct orders. Seeded: a random purchase day, narrowed by customer
    # state (busiest first) until the result fits on one page. Taking the
    # largest window that fits is what gives a rare duplicate a chance to be
    # on the page.
    def check_complete_listing_matches_count
      rng = Random.new(@seed)
      states = rows("revenue_report", group_by: "state", limit: 50).sort_by { |r| -r["orders"] }.map { |r| r["state"] }
      failures = []
      checked = 0
      attempts = 0
      while checked < @cases * 4 && attempts < @cases * 12
        attempts += 1
        day = random_day(rng).iso8601
        result = args = nil
        [nil, *states].each do |state|
          args = { "from" => day, "to" => day, "limit" => 50 }
          args["customer_state"] = state if state
          result = @client.call("search_orders", args)
          break if result.structured&.dig("total_matches").to_i <= 50
        end
        total = result.structured&.dig("total_matches")
        next if total.nil? || total.zero? || total > 50

        checked += 1
        numbers = result.structured.fetch("orders").map { |o| o["number"] }
        next if numbers.size == total && numbers.uniq.size == total

        failures << { arguments: args, total_matches: total, rows: numbers.size, distinct: numbers.uniq.size }
      end
      verdict("complete-listing-matches-count",
              "A one-page search lists exactly total_matches distinct orders", failures, cases: checked)
    end

    # Narrowing a date window can never increase a count or a revenue sum.
    def check_narrower_filter_never_counts_more
      rng = Random.new(@seed + 1)
      failures = []
      @cases.times do
        a, b = [random_day(rng), random_day(rng)].sort
        inner_a = a + rng.rand(0..[(b - a).to_i, 0].max)
        inner_b = inner_a + rng.rand(0..[(b - inner_a).to_i, 0].max)
        wide = { "from" => a.iso8601, "to" => b.iso8601 }
        narrow = { "from" => inner_a.iso8601, "to" => inner_b.iso8601 }

        wide_count, narrow_count = [wide, narrow].map { |w| search_total(w) }
        if narrow_count > wide_count
          failures << { tool: "search_orders", wide: wide, narrow: narrow, wide_count: wide_count, narrow_count: narrow_count }
        end

        wide_rev, narrow_rev = [wide, narrow].map { |w| sum(rows("revenue_report", w.merge(group_by: "month")), "revenue") }
        if narrow_rev > wide_rev + 0.005
          failures << { tool: "revenue_report", wide: wide, narrow: narrow, wide_revenue: wide_rev, narrow_revenue: narrow_rev }
        end
      end
      verdict("narrower-filter-never-counts-more", "Narrowing a date window never increases a count or a sum",
              failures, cases: @cases)
    end

    # [d1, d2] and [d2+1, d3] partition [d1, d3]: counts and revenue must add
    # up exactly. This is where an inclusive/exclusive date boundary bug
    # shows up, as an order counted twice or dropped at midnight.
    def check_adjacent_date_windows_partition
      rng = Random.new(@seed + 2)
      failures = []
      @cases.times do
        d1 = random_day(rng)
        d2 = d1 + rng.rand(0..20)
        d3 = d2 + 1 + rng.rand(0..20)
        left = { "from" => d1.iso8601, "to" => d2.iso8601 }
        right = { "from" => (d2 + 1).iso8601, "to" => d3.iso8601 }
        whole = { "from" => d1.iso8601, "to" => d3.iso8601 }

        counts = [left, right, whole].map { |w| search_total(w) }
        unless counts[0] + counts[1] == counts[2]
          failures << { tool: "search_orders", windows: [left, right, whole], counts: counts }
        end

        revenue = [left, right, whole].map { |w| sum(rows("revenue_report", w.merge(group_by: "month")), "revenue") }
        unless ((revenue[0] + revenue[1]) - revenue[2]).abs < 0.005
          failures << { tool: "revenue_report", windows: [left, right, whole], revenue: revenue }
        end
      end
      verdict("adjacent-date-windows-partition", "Adjacent date windows add up to the window that spans them",
              failures, cases: @cases)
    end

    # A customer lookup either finds the customer whose email it was given or
    # finds nobody. A wildcard or a fragment must never resolve to somebody.
    def check_find_customer_exact_match
      # The probe input comes from the database; the verdict comes only from the tool.
      person = ActiveRecord::Base.connection.select_value("SELECT email FROM spree_users ORDER BY id LIMIT 1")
      probes = {
        "%" => false, "_" => false, "olist.invalid" => false,
        person[0, 8] => false, person.upcase => true, person => true
      }
      failures = probes.filter_map do |probe, should_resolve|
        result = @client.call("find_customer", "email" => probe)
        resolved = !result.error
        wrong_person = resolved && result.structured["email"].to_s.casecmp?(person) == false
        next if resolved == should_resolve && !wrong_person

        { probe: probe, should_resolve: should_resolve, resolved_to: (result.structured || {})["email"] }
      end
      verdict("find-customer-exact-match", "A customer lookup resolves only an exact email", failures,
              cases: probes.size)
    end

    private

    def grouped_outputs
      @grouped_outputs ||= [
        *%w[month state category seller payment_method].map do |g|
          key = g == "payment_method" ? "method" : g
          ["revenue_report(#{g})", rows("revenue_report", group_by: g, limit: 50), key]
        end,
        ["list_categories", rows("list_categories", {}, "categories"), "category"],
        ["seller_performance", rows("seller_performance", { min_orders: 1, limit: 50 }, "sellers"), "seller"],
        *%w[bucket category state seller].map do |g|
          key = g == "bucket" ? "delivery" : g
          ["delivery_performance(#{g})", rows("delivery_performance", group_by: g, min_orders: 1, limit: 50), key]
        end
      ]
    end

    def rows(tool, args, path = "rows")
      result = @client.call(tool, args.transform_keys(&:to_s))
      raise "#{tool} #{args.inspect} failed: #{result.error_message}" if result.error

      Array(result.structured&.dig(path))
    end

    def search_total(window)
      @client.call("search_orders", window.merge("limit" => 1)).structured.fetch("total_matches")
    end

    def sum(rows, field) = rows.sum { |r| r[field].to_f }.round(2)

    def compare_totals(label, a, b)
      return { comparison: label, problem: "no tool reports this total", values: [a, b] } if a.nil? || b.nil?
      return nil if (a - b).abs < 0.005

      { comparison: label, values: [a, b], delta: (a - b).round(2) }
    end

    def random_day(rng) = FIRST_DAY + rng.rand(0..(LAST_DAY - FIRST_DAY).to_i)

    def verdict(id, title, failures, cases:, sample: nil)
      Check.new(id: id, kind: "invariant", title: title, status: failures.empty? ? "pass" : "fail",
                expected: { violations: 0 }, actual: { violations: failures.size, cases: cases },
                diffs: (sample || failures).first(10), arguments: { seed: @seed, cases: @cases })
    end

    def timed(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      check = yield
      check.tap { |c| c.seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    rescue StandardError => e
      Check.new(id: name.to_s.delete_prefix("check_").tr("_", "-"), kind: "invariant", status: "error",
                detail: "#{e.class}: #{e.message}")
    end
  end
end
