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

      # How each grouping relates to the order population (docs/METRICS.md):
      #
      #   grain :order    month and state partition completed orders. Revenue
      #                   is summed from order totals, and orders add up.
      #   grain :item     category and seller are properties of an item. An
      #                   order with items in two categories is in both
      #                   buckets, so each bucket's revenue is summed from its
      #                   own items and freight, never from order totals, and
      #                   order counts do not add up across buckets.
      #   grain :payment  payment_method sums what was paid with each method.
      #                   An order paid by voucher and card is in both.
      GROUPINGS = {
        "month" => {
          grain: :order,
          select: "TO_CHAR(DATE_TRUNC('month', d.purchased_at), 'YYYY-MM')",
          joins: "",
          label: "MONTH",
          order: "bucket ASC"
        },
        "state" => {
          grain: :order,
          select: "a.state_name",
          joins: "LEFT JOIN spree_addresses a ON a.id = o.bill_address_id",
          label: "STATE",
          order: "revenue DESC, bucket ASC"
        },
        "category" => {
          grain: :item,
          select: "t.name",
          joins: <<~SQL,
            JOIN spree_variants v ON v.id = li.variant_id
            JOIN spree_products_taxons pt ON pt.product_id = v.product_id
            JOIN spree_taxons t ON t.id = pt.taxon_id
          SQL
          label: "CATEGORY",
          order: "revenue DESC, bucket ASC"
        },
        "seller" => {
          grain: :item,
          select: "s.olist_seller_id",
          joins: "JOIN olist_sellers s ON s.id = lid.olist_seller_id",
          label: "SELLER",
          order: "revenue DESC, bucket ASC"
        },
        "payment_method" => {
          grain: :payment,
          select: "pd.payment_type",
          joins: "",
          label: "METHOD",
          order: "revenue DESC, bucket ASC"
        }
      }.freeze

      def self.call(server_context:, **args)
        group_by = GROUPINGS.key?(args[:group_by].to_s) ? args[:group_by].to_s : "month"
        group = GROUPINGS.fetch(group_by)
        store_id = store(server_context).id

        where = ["o.store_id = #{store_id.to_i}", "o.state = 'complete'"]
        where << "d.purchased_at >= #{quote(args[:from])}" if args[:from].present?
        where << "d.purchased_at < (#{quote(args[:to])}::date + 1)" if args[:to].present?

        limit = group_by == "month" ? 500 : limit_for(args[:limit])
        rows = sql(query(group, where.join(" AND "), limit)).map do |r|
          row = { group[:label].downcase.to_sym => r["bucket"], orders: r["orders"].to_i }
          row.merge!(item_revenue: r["item_revenue"].to_f, freight: r["freight"].to_f) unless group[:grain] == :payment
          row.merge(revenue: r["revenue"].to_f, avg_order_value: r["avg_order"].to_f)
        end

        ok(render(group, group_by, rows), structured: structured(group, group_by, rows))
      end

      def self.query(group, where, limit)
        buckets = case group[:grain]
                  when :order then <<~SQL
                    SELECT #{group[:select]} AS bucket, o.id AS order_id,
                           o.item_total AS item_revenue, o.shipment_total AS freight, o.total AS revenue
                      FROM spree_orders o
                      JOIN olist_order_details d ON d.spree_order_id = o.id
                      #{group[:joins]}
                     WHERE #{where}
                  SQL
                  when :item then <<~SQL
                    SELECT #{group[:select]} AS bucket, o.id AS order_id,
                           li.price * li.quantity AS item_revenue, lid.freight_value AS freight,
                           li.price * li.quantity + lid.freight_value AS revenue
                      FROM spree_orders o
                      JOIN olist_order_details d ON d.spree_order_id = o.id
                      JOIN spree_line_items li ON li.order_id = o.id
                      JOIN olist_line_item_details lid ON lid.spree_line_item_id = li.id
                      #{group[:joins]}
                     WHERE #{where}
                  SQL
                  when :payment then <<~SQL
                    SELECT #{group[:select]} AS bucket, o.id AS order_id,
                           NULL::numeric AS item_revenue, NULL::numeric AS freight, pay.amount AS revenue
                      FROM spree_orders o
                      JOIN olist_order_details d ON d.spree_order_id = o.id
                      JOIN spree_payments pay ON pay.order_id = o.id
                      JOIN olist_payment_details pd ON pd.spree_payment_id = pay.id
                     WHERE #{where}
                  SQL
                  end

        # One row per order, item or payment, so every SUM counts each
        # contribution exactly once and orders are counted DISTINCT.
        <<~SQL
          SELECT bucket,
                 COUNT(DISTINCT order_id)                         AS orders,
                 ROUND(SUM(item_revenue), 2)                      AS item_revenue,
                 ROUND(SUM(freight), 2)                           AS freight,
                 ROUND(SUM(revenue), 2)                           AS revenue,
                 ROUND(SUM(revenue) / COUNT(DISTINCT order_id), 2) AS avg_order
            FROM (#{buckets}) contributions
           WHERE bucket IS NOT NULL
           GROUP BY bucket
           ORDER BY #{group[:order]}
           LIMIT #{limit.to_i}
        SQL
      end

      # Order counts only add up when the grouping partitions orders. For the
      # others, a total order count would count shared orders more than once,
      # so none is given.
      def self.orders_additive?(group) = group[:grain] == :order

      def self.structured(group, group_by, rows)
        totals = { revenue: rows.sum { |r| r[:revenue] }.round(2) }
        unless group[:grain] == :payment
          totals[:item_revenue] = rows.sum { |r| r[:item_revenue] }.round(2)
          totals[:freight] = rows.sum { |r| r[:freight] }.round(2)
        end
        totals[:orders] = rows.sum { |r| r[:orders] } if orders_additive?(group)

        { group_by: group_by, metric: group[:grain] == :payment ? "payment_value" : "gross_revenue",
          orders_additive: orders_additive?(group), totals: totals, rows: rows }
      end

      def self.render(group, group_by, rows)
        key = group[:label].downcase.to_sym
        columns = [[key, group[:label]], [:orders, "ORDERS"]]
        columns += [[:item_revenue, "ITEMS"], [:freight, "FREIGHT"]] unless group[:grain] == :payment
        columns += [[:revenue, group[:grain] == :payment ? "PAID" : "REVENUE"], [:avg_order_value, "PER ORDER"]]
        text = table(
          rows.map do |r|
            r.merge(%i[item_revenue freight revenue avg_order_value].to_h { |f| [f, r.key?(f) ? money(r[f]) : nil] })
          end,
          columns
        )

        total = money(rows.sum { |r| r[:revenue] })
        text += if orders_additive?(group)
                  "\n\nTotal across shown rows: #{rows.sum { |r| r[:orders] }} orders, #{total}."
                else
                  "\n\nTotal across shown rows: #{total}. Order counts are not summed: an order " \
                    "#{group[:grain] == :payment ? 'paid with two methods' : "with items from several #{group_by.pluralize}"} " \
                    "appears under each, so the per-row counts overlap."
                end
        text += case group[:grain]
                when :item then "\nRevenue is each #{group_by}'s own items plus their freight, from completed orders."
                when :payment then "\nAmounts are what was paid with each method, on completed orders."
                else "\nRevenue is items plus freight, from completed orders; cancelled and unavailable orders are excluded."
                end
        text
      end
    end
  end
end
