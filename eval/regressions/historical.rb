# frozen_string_literal: true

module Eval
  module Regressions
    # Gives a stand-in tool the published name, description and input schema
    # of the tool it replaces. A client cannot tell it apart; only its
    # answers differ.
    module Mirror
      def mirrors(tool)
        tool_name tool.name_value
        title tool.title
        description tool.description
        input_schema tool.input_schema_value
      end
    end

    # --- H1: category revenue join fan-out (the 42x bug) --------------------
    #
    # PROVENANCE: reconstructed, not recovered. The original query predates
    # the first commit. This is rebuilt from the article's description ("each
    # product already carries its own running revenue total ... joined against
    # every matching line item and every matching review before summing").
    # Checked against the article's figure: on the pre-fix product counters it
    # reports Health Beauty at R$52,545,084.05, the R$52,545,084 the article
    # quotes.
    class CategoryRevenueFanOut < StoreMcp::BaseTool
      extend Mirror
      mirrors StoreMcp::Tools::ListCategories

      def self.call(server_context:, **_args)
        store_id = store(server_context).id
        rows = sql(<<~SQL).map do |r|
          SELECT t.name AS category,
                 COUNT(DISTINCT p.id)                AS products,
                 SUM(COALESCE(p.units_sold_count,0)) AS units,
                 SUM(COALESCE(p.revenue,0))          AS revenue,
                 ROUND(AVG(rev.score), 2)            AS avg_review
            FROM spree_taxons t
            JOIN spree_products_taxons pt ON pt.taxon_id = t.id
            JOIN spree_products p ON p.id = pt.product_id AND p.store_id = #{store_id.to_i}
            JOIN spree_variants v ON v.product_id = p.id
            JOIN spree_line_items li ON li.variant_id = v.id
       LEFT JOIN olist_reviews rev ON rev.spree_order_id = li.order_id
           GROUP BY t.name
           ORDER BY revenue DESC NULLS LAST
        SQL
          { category: r["category"], products: r["products"].to_i, units_sold: r["units"].to_i,
            revenue: r["revenue"].to_f, avg_review: r["avg_review"]&.to_f }
        end
        ok("#{rows.size} categories.", structured: { categories: rows })
      end
    end

    # --- H2: seller review average over a line-item join --------------------
    #
    # PROVENANCE: reconstructed, not recovered. Rebuilt from the article: "one
    # seller, who happened to have 21 line items in a single order, had that
    # one order's score counted 21 times in their average, dragging a real
    # 3.81 down to a reported 2.57". Checked against it: seller 2709af9587...
    # comes out at 2.57 here and at 3.81 deduplicated.
    class SellerAverageFanOut < StoreMcp::BaseTool
      extend Mirror
      mirrors StoreMcp::Tools::SellerPerformance

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        min_orders = (args[:min_orders] || 50).to_i
        order_by = case args[:sort]
                   when "avg_review" then "avg_review ASC NULLS LAST"
                   when "days_late"  then "avg_days_late DESC NULLS LAST"
                   when "orders"     then "orders DESC"
                   else "revenue DESC"
                   end
        rows = sql(<<~SQL).map do |r|
          SELECT s.olist_seller_id AS seller, s.city, s.state,
                 COUNT(DISTINCT o.id)            AS orders,
                 ROUND(SUM(li.price * li.quantity), 2) AS revenue,
                 ROUND(AVG(rev.score), 2)        AS avg_review,
                 ROUND(AVG(d.days_late), 1)      AS avg_days_late
            FROM olist_sellers s
            JOIN olist_line_item_details lid ON lid.olist_seller_id = s.id
            JOIN spree_line_items li ON li.id = lid.spree_line_item_id
            JOIN spree_orders o ON o.id = li.order_id
            JOIN olist_order_details d ON d.spree_order_id = o.id
       LEFT JOIN olist_reviews rev ON rev.spree_order_id = o.id
           WHERE o.store_id = #{store_id.to_i}
           GROUP BY s.id, s.olist_seller_id, s.city, s.state
          HAVING COUNT(DISTINCT o.id) >= #{min_orders}
           ORDER BY #{order_by}
           LIMIT #{limit_for(args[:limit])}
        SQL
          { seller: r["seller"], location: [r["city"], r["state"]].compact.join(", "),
            orders: r["orders"].to_i, revenue: r["revenue"].to_f,
            avg_review: r["avg_review"]&.to_f, avg_days_late: r["avg_days_late"]&.to_f }
        end
        ok("#{rows.size} sellers.", structured: { min_orders: min_orders, sellers: rows })
      end
    end

    # --- H3: rows silently dropped on import (the 33-row bug) ---------------
    #
    # PROVENANCE: simulated effect, not reconstructed cause. The original loss
    # came from `insert_all` (ON CONFLICT DO NOTHING) meeting a unique index,
    # and dropped 33 payment rows. The exact index and column combination is
    # not recoverable: the obvious reconstruction, payment type written into
    # response_code under a unique (order, method, response_code) index, would
    # drop 2,200 rows, not 33. So this reproduces what the harness has to
    # detect, 33 legitimate payments missing with no error, by deleting 33
    # repeat payments inside a transaction that is always rolled back.
    DROP_33_PAYMENTS = lambda do
      ids = ActiveRecord::Base.connection.select_values(<<~SQL)
        SELECT id FROM (
          SELECT p.id, ROW_NUMBER() OVER (PARTITION BY p.order_id, pd.payment_type ORDER BY p.id) AS n
            FROM spree_payments p JOIN olist_payment_details pd ON pd.spree_payment_id = p.id
        ) repeats
         WHERE n > 1
         ORDER BY id
         LIMIT 33
      SQL
      OlistPaymentDetail.where(spree_payment_id: ids).delete_all
      Spree::Payment.where(id: ids).delete_all
    end
  end
end
