# frozen_string_literal: true

module StoreMcp
  module Tools
    class SellerPerformance < BaseTool
      tool_name "seller_performance"
      title "Seller performance"
      description <<~DESC
        Rank marketplace sellers by revenue, review score, or delivery lateness,
        with a minimum order threshold so a seller with three orders and one
        five-star review does not top the list.

        Call this for questions about who to promote or investigate. Ranking by
        `avg_review` ascending surfaces the sellers to look at first — and note
        that a seller can deliver early and still be badly reviewed, which
        points at the product rather than the logistics.
      DESC

      input_schema(
        properties: {
          sort: {
            type: "string",
            enum: %w[revenue avg_review days_late orders],
            description: "Ranking. Defaults to revenue (highest first); avg_review sorts worst-first."
          },
          state: { type: "string", description: "Restrict to sellers in a Brazilian state, e.g. SP." },
          min_orders: { type: "integer", description: "Minimum orders to qualify. Defaults to 50." },
          limit: { type: "integer", description: "Max rows, 1-50. Defaults to 20." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        min_orders = (args[:min_orders] || 50).to_i
        limit = limit_for(args[:limit])

        order_by = case args[:sort]
                   when "avg_review" then "avg_review ASC NULLS LAST"
                   when "days_late"  then "avg_days_late DESC NULLS LAST"
                   when "orders"     then "orders DESC"
                   else "revenue DESC"
                   end

        where = ["o.store_id = #{store_id.to_i}"]
        where << "s.state = #{quote(args[:state].to_s.upcase)}" if args[:state].present?

        # AVG(rev.score) / AVG(d.days_late) must not be computed over the same
        # join as revenue: a seller with two line items in one order would
        # have that order's score and lateness counted twice. seller_orders
        # dedupes to one row per (seller, order) for the averages; revenue is
        # summed separately over every line item, which is correct as-is —
        # each item's own price should count once. Same pattern as the
        # list_categories fan-out fix.
        rows = sql(<<~SQL).map do |r|
          WITH seller_orders AS (
            SELECT DISTINCT s.id AS seller_id, o.id AS order_id, d.days_late, rev.score
              FROM olist_sellers s
              JOIN olist_line_item_details lid ON lid.olist_seller_id = s.id
              JOIN spree_line_items li ON li.id = lid.spree_line_item_id
              JOIN spree_orders o ON o.id = li.order_id
              JOIN olist_order_details d ON d.spree_order_id = o.id
         LEFT JOIN olist_reviews rev ON rev.spree_order_id = o.id
             WHERE #{where.join(' AND ')}
          ),
          seller_revenue AS (
            SELECT s.id AS seller_id, SUM(li.price * li.quantity) AS revenue
              FROM olist_sellers s
              JOIN olist_line_item_details lid ON lid.olist_seller_id = s.id
              JOIN spree_line_items li ON li.id = lid.spree_line_item_id
              JOIN spree_orders o ON o.id = li.order_id
             WHERE #{where.join(' AND ')}
             GROUP BY s.id
          )
          SELECT s.olist_seller_id AS seller, s.city, s.state,
                 COUNT(DISTINCT so.order_id)  AS orders,
                 ROUND(sr.revenue, 2)         AS revenue,
                 ROUND(AVG(so.score), 2)      AS avg_review,
                 ROUND(AVG(so.days_late), 1)  AS avg_days_late
            FROM olist_sellers s
            JOIN seller_orders so ON so.seller_id = s.id
            JOIN seller_revenue sr ON sr.seller_id = s.id
           GROUP BY s.id, s.olist_seller_id, s.city, s.state, sr.revenue
          HAVING COUNT(DISTINCT so.order_id) >= #{min_orders}
           ORDER BY #{order_by}
           LIMIT #{limit}
        SQL
          {
            seller: r["seller"], location: [r["city"], r["state"]].compact.join(", "),
            orders: r["orders"].to_i, revenue: r["revenue"].to_f,
            avg_review: r["avg_review"]&.to_f, avg_days_late: r["avg_days_late"]&.to_f
          }
        end

        text = table(
          rows.map { |r| r.merge(seller: r[:seller].to_s[0, 12], revenue: money(r[:revenue])) },
          [[:seller, "SELLER"], [:location, "LOCATION"], [:orders, "ORDERS"],
           [:revenue, "REVENUE"], [:avg_review, "AVG REVIEW"], [:avg_days_late, "AVG LATE"]]
        )
        text += "\n\nSeller IDs are truncated to 12 characters for display; the full ID is in the structured output."
        text += "\nMinimum #{min_orders} orders to qualify. Negative 'AVG LATE' means delivered ahead of estimate."

        ok(text, structured: { min_orders: min_orders, sellers: rows })
      end
    end
  end
end
