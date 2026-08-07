# frozen_string_literal: true

module StoreMcp
  module Tools
    class DeliveryPerformance < BaseTool
      tool_name "delivery_performance"
      title "Delivery performance vs reviews"
      description <<~DESC
        How late deliveries run, and what that does to review scores. Grouped
        into lateness buckets by default, or broken down by category, customer
        state, or seller.

        Call this for any question connecting logistics to customer
        satisfaction — "are late deliveries hurting us", "which categories have
        the worst delivery record", "is the problem shipping or the product".
        The bucket view is the one that answers "how much does lateness
        actually cost us in stars".
      DESC

      input_schema(
        properties: {
          group_by: {
            type: "string",
            enum: %w[bucket category state seller],
            description: "Dimension. Defaults to bucket (lateness bands)."
          },
          from: { type: "string", format: "date", description: "Only orders purchased on or after this date." },
          to: { type: "string", format: "date", description: "Only orders purchased on or before this date." },
          min_orders: { type: "integer", description: "Drop groups with fewer than this many orders. Defaults to 30 for non-bucket groupings." },
          limit: { type: "integer", description: "Max rows, 1-50. Defaults to 20." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      BUCKET = <<~SQL
        CASE WHEN d.days_late <= 0 THEN 'on time or early'
             WHEN d.days_late <= 3 THEN '1-3 days late'
             WHEN d.days_late <= 7 THEN '4-7 days late'
             ELSE 'more than a week late' END
      SQL

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        mode = args[:group_by].to_s.presence || "bucket"

        select, joins, label = case mode
                               when "category"
                                 ["t.name", <<~SQL, "CATEGORY"]
                                   JOIN spree_line_items li ON li.order_id = o.id
                                   JOIN spree_variants v ON v.id = li.variant_id
                                   JOIN spree_products_taxons pt ON pt.product_id = v.product_id
                                   JOIN spree_taxons t ON t.id = pt.taxon_id
                                 SQL
                               when "state"
                                 ["a.state_name", "LEFT JOIN spree_addresses a ON a.id = o.bill_address_id", "STATE"]
                               when "seller"
                                 ["s.olist_seller_id", <<~SQL, "SELLER"]
                                   JOIN spree_line_items li ON li.order_id = o.id
                                   JOIN olist_line_item_details lid ON lid.spree_line_item_id = li.id
                                   JOIN olist_sellers s ON s.id = lid.olist_seller_id
                                 SQL
                               else [BUCKET.strip, "", "DELIVERY"]
                               end

        where = ["o.store_id = #{store_id.to_i}", "d.days_late IS NOT NULL"]
        where << "d.purchased_at >= #{quote(args[:from])}" if args[:from].present?
        where << "d.purchased_at < (#{quote(args[:to])}::date + 1)" if args[:to].present?

        min_orders = args[:min_orders] || (mode == "bucket" ? 0 : 30)
        limit = limit_for(args[:limit])
        order_by = mode == "bucket" ? "MIN(days_late) ASC" : "avg_review ASC"

        rows = sql(<<~SQL).map do |r|
          SELECT bucket,
                 COUNT(*)                     AS orders,
                 ROUND(AVG(days_late), 1)     AS avg_days_late,
                 ROUND(AVG(delivery_days), 1) AS avg_delivery_days,
                 ROUND(AVG(score), 2)         AS avg_review,
                 MIN(days_late)               AS min_days_late,
                 SUM(CASE WHEN days_late > 0 THEN 1 ELSE 0 END) AS late_orders
            FROM (
              SELECT DISTINCT #{select} AS bucket, o.id AS order_id,
                     d.days_late, d.delivery_days, r.score
                FROM spree_orders o
                JOIN olist_order_details d ON d.spree_order_id = o.id
           LEFT JOIN olist_reviews r ON r.spree_order_id = o.id
                #{joins}
               WHERE #{where.join(' AND ')}
            ) grouped
           WHERE bucket IS NOT NULL
           GROUP BY bucket
          HAVING COUNT(*) >= #{min_orders.to_i}
           ORDER BY #{order_by}
           LIMIT #{limit}
        SQL
          orders = r["orders"].to_i
          late = r["late_orders"].to_i
          {
            label.downcase.to_sym => r["bucket"],
            orders: orders,
            late_orders: late,
            late_rate: orders.zero? ? 0.0 : (late.to_f / orders * 100).round(1),
            avg_days_late: r["avg_days_late"]&.to_f,
            avg_delivery_days: r["avg_delivery_days"]&.to_f,
            avg_review: r["avg_review"]&.to_f
          }
        end

        key = label.downcase.to_sym
        text = table(
          rows.map { |r| r.merge(late_rate: "#{r[:late_rate]}%") },
          [[key, label], [:orders, "ORDERS"], [:late_rate, "LATE%"],
           [:avg_days_late, "AVG LATE"], [:avg_delivery_days, "AVG DAYS"], [:avg_review, "AVG REVIEW"]]
        )
        text += "\n\nNegative 'AVG LATE' means delivered ahead of the estimate."
        text += "\nOnly orders with a recorded delivery estimate are counted." if mode != "bucket"

        ok(text, structured: { group_by: mode, rows: rows })
      end
    end
  end
end
