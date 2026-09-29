# frozen_string_literal: true

module Eval
  # Did the import land every source row, and every real in it? This compares
  # the database the tools query with the CSVs the oracle reads, table by
  # table, on row counts and on value sums.
  #
  # It is the check that catches the historical `insert_all` bug: rows that
  # vanish on the way in leave every tool's arithmetic correct and every
  # answer wrong. It queries the database directly, because it is auditing
  # the import and not the tools.
  class Reconciliation
    def initialize(truth)
      @truth = truth
      @data = truth.dataset
    end

    def run
      %i[counts values].map do |name|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        send(name).tap { |c| c.seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
      end
    end

    private

    def counts
      db = scalar_row(<<~SQL)
        SELECT (SELECT COUNT(*) FROM spree_orders)             AS orders,
               (SELECT COUNT(*) FROM spree_line_items)         AS items,
               (SELECT COUNT(*) FROM spree_products)           AS products,
               (SELECT COUNT(*) FROM spree_addresses)          AS customers,
               (SELECT COUNT(*) FROM olist_sellers)            AS sellers,
               (SELECT COUNT(*) FROM spree_payments)           AS payments,
               (SELECT COUNT(*) FROM olist_reviews)            AS reviews,
               (SELECT COUNT(DISTINCT email) FROM spree_users) AS customer_people
      SQL
      source = @data.counts.merge(customer_people: @data.customers.values.map(&:unique_id).uniq.size)
      compare("reconcile-row-counts", "Every source row was imported, table by table", source, db, :to_i)
    end

    def values
      db = scalar_row(<<~SQL)
        SELECT (SELECT SUM(price) FROM spree_line_items)                 AS item_price,
               (SELECT SUM(freight_value) FROM olist_line_item_details)  AS freight,
               (SELECT SUM(total) FROM spree_orders)                     AS order_totals,
               (SELECT SUM(amount) FROM spree_payments)                  AS payment_value,
               (SELECT SUM(score) FROM olist_reviews)                    AS review_scores,
               (SELECT COUNT(*) FROM olist_order_details WHERE olist_status IN
                  ('delivered','shipped','invoiced','processing','approved')) AS completed_orders
      SQL
      source = {
        item_price: @data.items.sum(BigDecimal("0"), &:price),
        freight: @data.items.sum(BigDecimal("0"), &:freight),
        order_totals: @truth.orders.sum(BigDecimal("0"), &:gross),
        payment_value: @data.payments.sum(BigDecimal("0"), &:value),
        review_scores: @data.reviews.sum(&:score),
        completed_orders: @truth.completed_orders.size
      }
      compare("reconcile-value-sums", "Imported money, scores and statuses sum to the source's", source, db, :to_d)
    end

    def compare(id, title, source, db, cast)
      diffs = source.filter_map do |field, expected|
        raw = db[field.to_s]
        actual = cast == :to_i ? raw.to_i : BigDecimal(raw.to_s)
        next if expected == actual

        Diff.new(key: field.to_s, field: field.to_s, expected: normalize(expected), actual: normalize(actual)).to_h
      end
      Check.new(id: id, kind: "reconciliation", title: title, status: diffs.empty? ? "pass" : "fail",
                expected: source.transform_values { |v| normalize(v) }, diffs: diffs)
    end

    def normalize(v) = v.is_a?(BigDecimal) ? v.to_f : v

    def scalar_row(sql) = ActiveRecord::Base.connection.select_all(sql).first
  end
end
