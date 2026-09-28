# frozen_string_literal: true

require "date"

module Eval
  # Seeded differential testing: random arguments to the real tools, each
  # answer compared with the oracle's. The question bank asks the questions
  # somebody thought of; this asks a few hundred nobody did.
  #
  # Every case is an ordinary question (the same shape as eval/questions/*.yml)
  # run through the same QuestionRunner, so there is one comparator, not two.
  # Arguments come from Random.new(seed + offset); the seed is in the report,
  # and a failing case prints its exact arguments.
  class Differential
    STATUSES = %w[delivered shipped canceled unavailable invoiced processing].freeze
    STATES = %w[SP RJ MG RS PR SC BA DF GO ES PE CE PA MT MA MS PB RN PI AL SE TO RO AM AC AP RR].freeze

    SIZES = { search: 3.2, revenue: 1.2, delivery: 0.8, customers: 1.2, products: 1.2, sellers: 0.4 }.freeze

    def initialize(runner:, truth:, seed:, cases: 25)
      @runner = runner
      @truth = truth
      @seed = seed
      @cases = cases
    end

    def run(ids: nil)
      specs = {
        "search-orders-random-filters" => -> { search_cases },
        "revenue-report-random-windows" => -> { revenue_cases },
        "delivery-random-windows" => -> { delivery_cases },
        "customers-random" => -> { customer_cases },
        "products-random" => -> { product_cases },
        "sellers-random-states" => -> { seller_cases }
      }
      specs.select { |id, _| ids.nil? || ids.include?(id) }.map do |id, build|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        check = judge(id, build.call)
        check.seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
        check
      end
    end

    private

    def n(kind) = (@cases * SIZES.fetch(kind)).round

    def search_cases
      rng = Random.new(@seed + 10)
      Array.new(n(:search)) do |i|
        filters = {}
        filters["status"] = STATUSES.sample(random: rng) if rng.rand < 0.3
        if rng.rand < 0.6
          a, b = window(rng)
          filters["from"] = a
          filters["to"] = b
        end
        filters["customer_state"] = STATES.sample(random: rng) if rng.rand < 0.4
        filters["min_total"] = [50, 100, 250, 500, 1000].sample(random: rng) if rng.rand < 0.3
        filters["max_total"] = [30, 80, 150, 400].sample(random: rng) if rng.rand < 0.2
        filters["min_days_late"] = [-10, 0, 1, 5, 15].sample(random: rng) if rng.rand < 0.3
        filters["max_review_score"] = rng.rand(1..4) if rng.rand < 0.3
        oracle = filters.transform_keys(&:to_sym)
        { "id" => "search##{i}", "tool" => "search_orders", "args" => filters.merge("limit" => 1),
          "scalar" => "total_matches", "expected" => { "oracle" => "search_count", "params" => oracle } }
      end
    end

    def revenue_cases
      rng = Random.new(@seed + 11)
      Array.new(n(:revenue)) do |i|
        a, b = window(rng)
        group = %w[month state].sample(random: rng)
        { "id" => "revenue##{i}", "tool" => "revenue_report",
          "args" => { "group_by" => group, "from" => a, "to" => b, "limit" => 50 },
          "rows" => "rows", "key" => group, "match" => "all",
          "fields" => { "orders" => "orders", "revenue" => "gross_revenue", "item_revenue" => "item_revenue",
                        "freight" => "freight" },
          "expected" => { "oracle" => "revenue_by", "params" => { "dimension" => group, "from" => a, "to" => b } } }
      end
    end

    def delivery_cases
      rng = Random.new(@seed + 12)
      Array.new(n(:delivery)) do |i|
        a, b = window(rng)
        { "id" => "delivery##{i}", "tool" => "delivery_performance", "args" => { "from" => a, "to" => b },
          "rows" => "rows", "key" => "delivery", "match" => "all",
          "fields" => { "orders" => "orders", "late_orders" => "late_orders", "late_rate" => "late_rate",
                        "avg_days_late" => "avg_days_late", "avg_delivery_days" => "avg_delivery_days",
                        "avg_review" => "avg_review" },
          "expected" => { "oracle" => "delivery_by", "params" => { "dimension" => "bucket", "from" => a, "to" => b } } }
      end
    end

    def customer_cases
      rng = Random.new(@seed + 13)
      pool = @truth.orders.map(&:customer_unique_id).uniq.sort
      # Half uniform, half from customers with an order the review policy
      # decides: the population where a fan-out would show.
      risky = @truth.multi_review_order_ids.map { |id| @truth.order(id).customer_unique_id }.uniq.sort
      Array.new(n(:customers)) do |i|
        uid = (i.even? ? pool : risky).sample(random: rng)
        { "id" => "customer##{i}", "tool" => "find_customer", "args" => { "email" => "#{uid}@olist.invalid" },
          "record" => true, "fields" => { "orders" => "orders", "lifetime_value" => "lifetime_value",
                                          "avg_review" => "avg_review" },
          "expected" => { "oracle" => "customer", "params" => { "unique_id" => uid } } }
      end
    end

    def product_cases
      rng = Random.new(@seed + 14)
      sold = @truth.orders.flat_map { |o| o.items.map(&:product_id) }.uniq.sort
      Array.new(n(:products)) do |i|
        pid = sold.sample(random: rng)
        { "id" => "product##{i}", "tool" => "get_product", "args" => { "sku" => pid }, "record" => true,
          "fields" => { "units_sold" => "units_sold", "revenue" => "item_revenue", "orders" => "orders",
                        "avg_review" => "avg_review", "avg_days_late" => "avg_days_late" },
          "expected" => { "oracle" => "product", "params" => { "product_id" => pid } } }
      end
    end

    def seller_cases
      rng = Random.new(@seed + 15)
      Array.new(n(:sellers)) do |i|
        state = %w[SP RJ MG PR SC RS BA GO DF ES].sample(random: rng)
        min = [5, 10, 25].sample(random: rng)
        { "id" => "seller##{i}", "tool" => "seller_performance",
          "args" => { "state" => state, "min_orders" => min, "sort" => "revenue", "limit" => 50 },
          "rows" => "sellers", "key" => "seller",
          "match" => { "top" => 50, "rank_by" => "item_revenue", "order" => "desc" },
          "fields" => { "orders" => "orders", "revenue" => "item_revenue", "avg_review" => "avg_review",
                        "avg_days_late" => "avg_days_late" },
          "expected" => { "oracle" => "sellers", "params" => { "seller_state" => state, "min_orders" => min } } }
      end
    end

    # A random window inside the dataset's range, from one day to a year long.
    def window(rng)
      first = Invariants::FIRST_DAY
      span = (Invariants::LAST_DAY - first).to_i
      a = first + rng.rand(0..span)
      b = [a + rng.rand(0..365), Invariants::LAST_DAY].min
      [a.iso8601, b.iso8601]
    end

    def judge(id, cases)
      results = cases.map { |q| [q, @runner.run(q)] }
      bad = results.reject { |_, c| c.pass? }
      diffs = bad.first(8).map do |q, c|
        { case: q["id"], arguments: q["args"], status: c.status,
          first_diff: Array(c.diffs).first || c.detail, diffs: Array(c.diffs).size }
      end
      Check.new(id: id, kind: "differential", title: "#{cases.size} seeded random #{cases.first&.dig('tool')} calls agree with the oracle",
                status: bad.empty? ? "pass" : "fail", expected: { disagreements: 0 },
                actual: { disagreements: bad.size, cases: cases.size, seeded_cases: cases.size }, diffs: diffs,
                arguments: { seed: @seed, cases: cases.size })
    end
  end
end
