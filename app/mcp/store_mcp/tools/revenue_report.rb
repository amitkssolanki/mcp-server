# frozen_string_literal: true

module StoreMcp
  module Tools
    class RevenueReport < BaseTool
      tool_name "revenue_report"
      title "Revenue report"
      description <<~DESC
        Aggregate revenue, order count, and average order value, grouped by
        month, category, customer state, payment method, or seller. Call this
        for any "how much / how many / which sells best" question instead of
        pulling orders and adding them up yourself — this runs one aggregate
        query and returns a handful of rows.

        Optionally restrict to a date range. Grouping by month is the right
        choice for trend and seasonality questions.
      DESC

      input_schema(
        properties: {
          group_by: {
            type: "string",
            enum: %w[month category state payment_method seller],
            description: "Dimension to group by. Defaults to month."
          },
          from: { type: "string", format: "date", description: "Only orders purchased on or after this date." },
          to: { type: "string", format: "date", description: "Only orders purchased on or before this date." },
          limit: { type: "integer", description: "Max rows, 1-50. Defaults to 20. Ignored for month grouping." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      GROUPINGS = {
        "month" => {
          select: "TO_CHAR(DATE_TRUNC('month', d.purchased_at), 'YYYY-MM')",
          joins: "",
          label: "MONTH",
          order: "bucket ASC"
        },
        "category" => {
          select: "t.name",
          joins: <<~SQL,
            JOIN spree_line_items li ON li.order_id = o.id
            JOIN spree_variants v ON v.id = li.variant_id
            JOIN spree_products_taxons pt ON pt.product_id = v.product_id
            JOIN spree_taxons t ON t.id = pt.taxon_id
          SQL
          label: "CATEGORY",
          order: "revenue DESC"
        },
        "state" => {
          select: "a.state_name",
          joins: "LEFT JOIN spree_addresses a ON a.id = o.bill_address_id",
          label: "STATE",
          order: "revenue DESC"
        },
        "payment_method" => {
          select: "pd.payment_type",
          joins: <<~SQL,
            JOIN spree_payments pay ON pay.order_id = o.id
            JOIN olist_payment_details pd ON pd.spree_payment_id = pay.id
          SQL
          label: "METHOD",
          order: "revenue DESC"
        },
        "seller" => {
          select: "s.olist_seller_id",
          joins: <<~SQL,
            JOIN spree_line_items li ON li.order_id = o.id
            JOIN olist_line_item_details lid ON lid.spree_line_item_id = li.id
            JOIN olist_sellers s ON s.id = lid.olist_seller_id
          SQL
          label: "SELLER",
          order: "revenue DESC"
        }
      }.freeze

      def self.call(server_context:, **args)
        group = GROUPINGS.fetch(args[:group_by].to_s, GROUPINGS["month"])
        store_id = store(server_context).id

        where = ["o.store_id = #{store_id.to_i}", "o.state = 'complete'"]
        where << "d.purchased_at >= #{quote(args[:from])}" if args[:from].present?
        where << "d.purchased_at < (#{quote(args[:to])}::date + 1)" if args[:to].present?

        limit = args[:group_by].to_s == "month" ? 500 : limit_for(args[:limit])

        # Revenue is summed over DISTINCT orders even when the grouping joins
        # line items, so a two-item order is not counted twice in its category.
        rows = sql(<<~SQL).map do |r|
          SELECT bucket,
                 COUNT(DISTINCT order_id) AS orders,
                 ROUND(SUM(total), 2)     AS revenue,
                 ROUND(AVG(total), 2)     AS avg_order
            FROM (
              SELECT DISTINCT #{group[:select]} AS bucket, o.id AS order_id, o.total AS total
                FROM spree_orders o
                JOIN olist_order_details d ON d.spree_order_id = o.id
                #{group[:joins]}
               WHERE #{where.join(' AND ')}
            ) grouped
           WHERE bucket IS NOT NULL
           GROUP BY bucket
           ORDER BY #{group[:order]}
           LIMIT #{limit}
        SQL
          {
            group[:label].downcase.to_sym => r["bucket"],
            orders: r["orders"].to_i,
            revenue: r["revenue"].to_f,
            avg_order_value: r["avg_order"].to_f
          }
        end

        key = group[:label].downcase.to_sym
        text = table(
          rows.map { |r| r.merge(revenue: money(r[:revenue]), avg_order_value: money(r[:avg_order_value])) },
          [[key, group[:label]], [:orders, "ORDERS"], [:revenue, "REVENUE"], [:avg_order_value, "AVG ORDER"]]
        )

        totals = { orders: rows.sum { |r| r[:orders] }, revenue: rows.sum { |r| r[:revenue] } }
        text += "\n\nTotal across shown rows: #{totals[:orders]} orders, #{money(totals[:revenue])}."
        text += "\nCompleted orders only; cancelled and unavailable orders are excluded."

        ok(text, structured: { group_by: args[:group_by] || "month", totals: totals, rows: rows })
      end
    end
  end
end
