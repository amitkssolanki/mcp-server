# frozen_string_literal: true

require "test_helper"

# Who tests the tester. The oracle is the harness's ground truth, so its
# definitions are pinned here against a five-order dataset
# (test/fixtures/olist_mini) with every expected value worked out by hand.
# A fixture exists for each decision in docs/METRICS.md that a plausible
# implementation could get wrong.
#
#   o1  delivered    u1/SP  2017-01-02  p1(s1) 10.00+2.00, p2(s2, no category) 5.50+1.25
#                                        reviews: 1 (01-10), then 5 (01-12)  -> score 5
#                                        2.5 days late                        -> days_late 3
#   o2  canceled     u1/RJ  2017-01-03  p1(s1) 100.00                        review 1
#   o3  shipped      u2/SP  2017-01-15  p3(s1, untranslated) 20.00+3.00      voucher 10 + card 13, no review
#   o4  delivered    u3/MG  2017-02-01 23:59:59  p1(s2) 7.25+0.75
#                                        reviews 2 and 4, same day, 4 answered later -> score 4
#                                        half a day early                     -> days_late -1
#   o5  unavailable  u4/SP  2017-02-02  p1(s1) 50.00+5.00                    review 1
class OracleTest < ActiveSupport::TestCase
  test "completed orders are delivered, shipped, invoiced, processing or approved" do
    assert_equal %w[o1 o3 o4], mini_truth.completed_orders.map(&:id)
  end

  test "an order's score is its most recent review, not an average of its reviews" do
    assert_equal 5, mini_truth.order("o1").score, "later review wins"
    assert_equal 4, mini_truth.order("o4").score, "same creation day: later answer wins"
    assert_nil mini_truth.order("o3").score
  end

  test "days late rounds half away from zero, in both directions" do
    assert_equal 3, mini_truth.order("o1").days_late   # +2.5
    assert_equal(-1, mini_truth.order("o4").days_late) # -0.5
    assert_equal 20, mini_truth.order("o1").delivery_days
    assert_nil mini_truth.order("o3").days_late, "not delivered yet"
  end

  test "revenue by month counts completed orders only, items plus freight" do
    by_month = mini_truth.revenue_by(dimension: "month")
    assert_equal({ orders: 2, item_revenue: 35.5, freight: 6.25, gross_revenue: 41.75, avg_order_value: 20.88 },
                 by_month["2017-01"])
    assert_equal 8.0, by_month["2017-02"][:gross_revenue]
  end

  test "category revenue is allocated per item, so categories partition item revenue" do
    by_category = mini_truth.revenue_by(dimension: "category")
    assert_equal 17.25, by_category["health_beauty"][:item_revenue]
    assert_equal 5.5, by_category["uncategorised"][:item_revenue], "blank category"
    assert_equal 20.0, by_category["pc_gamer"][:item_revenue], "untranslated keeps its Portuguese name"

    total_gross = mini_truth.revenue_by(dimension: "month").values.sum { |b| b[:gross_revenue] }
    assert_in_delta total_gross, by_category.values.sum { |b| b[:gross_revenue] }, 1e-9
  end

  test "category order counts overlap and do not add up to the order count" do
    by_category = mini_truth.revenue_by(dimension: "category")
    assert_equal 4, by_category.values.sum { |b| b[:orders] }
    assert_equal 3, mini_truth.completed_orders.size
  end

  test "a seller is credited with its own items, never the whole order" do
    by_seller = mini_truth.revenue_by(dimension: "seller")
    assert_equal 30.0, by_seller["s1"][:item_revenue]  # o1's p1 and o3, not o1's total
    assert_equal 12.75, by_seller["s2"][:item_revenue]
  end

  test "payment method breakdown sums payment values, splitting a two-method order" do
    by_method = mini_truth.revenue_by(dimension: "payment_method")
    assert_equal({ orders: 3, payment_value: 39.75 }, by_method["credit_card"])
    assert_equal({ orders: 1, payment_value: 10.0 }, by_method["voucher"])
    refute by_method.key?("boleto"), "boleto was only used by a cancelled order"
  end

  test "categories count catalogue products, sold or not, and review each order once" do
    cats = mini_truth.categories
    assert_equal({ products: 2, units_sold: 2, item_revenue: 17.25, avg_review: 4.5 }, cats["health_beauty"])
    assert_nil cats["pc_gamer"][:avg_review], "its only order has no review"
  end

  test "seller metrics share one population: completed orders" do
    sellers = mini_truth.sellers
    assert_equal({ orders: 2, item_revenue: 30.0, avg_review: 5.0, avg_days_late: 3.0 }, sellers["s1"])
    assert_equal({ orders: 2, item_revenue: 12.75, avg_review: 4.5, avg_days_late: 1.0 }, sellers["s2"])
  end

  test "delivery buckets cover delivered orders only" do
    buckets = mini_truth.delivery_by(dimension: "bucket")
    assert_equal %w[1-3\ days\ late on\ time\ or\ early].sort, buckets.keys.sort
    assert_equal 100.0, buckets["1-3 days late"][:late_rate]
    assert_equal 8.0, buckets["on time or early"][:avg_delivery_days]
  end

  test "search covers placed orders and filters on the order's score" do
    assert_equal 5, mini_truth.search_orders.size
    assert_equal %w[o2], mini_truth.search_orders(status: "canceled").map(&:id)
    assert_equal %w[o2 o5], mini_truth.search_orders(max_review_score: 1).map(&:id), "o1's latest review is 5"
    assert_equal %w[o2], mini_truth.search_orders(customer_state: "rj").map(&:id)
  end

  test "a date filter includes the whole of its last day" do
    assert_equal %w[o4], mini_truth.search_orders(from: "2017-02-01", to: "2017-02-01").map(&:id)
    assert_equal %w[o2 o5], mini_truth.search_orders(min_total: 50).map(&:id)
  end

  test "a customer is a unique id across per-order customer ids; lifetime value is completed orders" do
    assert_equal({ orders: 2, lifetime_value: 18.75, avg_review: 5.0 }, mini_truth.customer("u1"))
  end

  test "an order summary is the order as placed, with the score the policy picks" do
    assert_equal({ status: "shipped", item_total: 20.0, freight: 3.0, total: 23.0, line_items: 1, sellers: 1,
                   review_score: nil, days_late: nil }, mini_truth.order_summary("o3"))
    assert_equal 5, mini_truth.order_summary("o1")[:review_score]
  end

  test "policy-sensitive orders are the ones where the first review on file is not the latest" do
    assert_equal %w[o1 o4], mini_truth.policy_sensitive_order_ids
  end

  test "a product's sales exclude cancelled and unavailable orders" do
    # p1 also sold in o2 (cancelled, 100.00) and o5 (unavailable, 50.00)
    assert_equal({ units_sold: 2, item_revenue: 17.25, orders: 2, avg_review: 4.5, avg_days_late: 1.0 },
                 mini_truth.product("p1"))
    assert_equal "p1", mini_truth.best_selling_product
  end

  test "a category's products include those that never sold" do
    assert_equal({ "p1" => { units_sold: 2, item_revenue: 17.25 }, "p4" => { units_sold: 0, item_revenue: 0.0 } },
                 mini_truth.products_in_category("health_beauty"))
  end

  test "the most frequent customer counts orders of every status" do
    assert_equal "u1", mini_truth.most_frequent_customer # o1 delivered + o2 cancelled
  end

  test "the oracle never touches the database" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      truth = Eval::Oracle::Truth.new(Eval::Oracle::Dataset.load(MINI_OLIST))
      truth.revenue_by(dimension: "category")
      truth.categories
      truth.sellers
      truth.delivery_by(dimension: "seller")
      truth.customer("u1")
    end
    assert_empty queries
  end
end
