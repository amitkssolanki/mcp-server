# frozen_string_literal: true

module StoreMcp
  module Tools
    class SearchOrders < BaseTool
      tool_name "search_orders"
      title "Search orders"
      description <<~DESC
        Find orders by date range, status, value, delivery lateness, or review
        score. Call this for any question about what happened in a period
        ("orders last November"), or to locate the specific orders behind a
        problem ("show me the one-star orders that arrived late").

        Returns one compact row per order including its delivery timeline and
        review score. For the full contents of a single order — line items,
        payments, the review text — call `get_order` with an order number from
        these results.
      DESC

      input_schema(
        properties: {
          from: { type: "string", format: "date", description: "Only orders purchased on or after this date (YYYY-MM-DD)." },
          to: { type: "string", format: "date", description: "Only orders purchased on or before this date (YYYY-MM-DD)." },
          status: {
            type: "string",
            enum: %w[delivered shipped invoiced processing approved created canceled unavailable],
            description: "Original Olist fulfilment status."
          },
          min_total: { type: "number", description: "Minimum order total in BRL." },
          max_total: { type: "number", description: "Maximum order total in BRL." },
          min_days_late: { type: "integer", description: "Only orders delivered at least this many days after the estimate. Use 1 for 'late'." },
          max_review_score: { type: "integer", description: "Only orders reviewed at or below this score, 1-5. Use 2 for 'unhappy customers'." },
          customer_state: { type: "string", description: "Two-letter Brazilian state code, e.g. SP." },
          sort: {
            type: "string",
            enum: %w[recent total_desc days_late review_asc],
            description: "Ordering. Defaults to most recent."
          },
          limit: { type: "integer", description: "Max rows, 1-50. Defaults to 20." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        where = ["o.store_id = #{store_id.to_i}"]
        where << "d.purchased_at >= #{quote(args[:from])}" if args[:from].present?
        where << "d.purchased_at < (#{quote(args[:to])}::date + 1)" if args[:to].present?
        where << "d.olist_status = #{quote(args[:status])}" if args[:status].present?
        where << "o.total >= #{args[:min_total].to_f}" if args[:min_total]
        where << "o.total <= #{args[:max_total].to_f}" if args[:max_total]
        where << "d.days_late >= #{args[:min_days_late].to_i}" if args[:min_days_late]
        where << "r.score <= #{args[:max_review_score].to_i}" if args[:max_review_score]
        where << "a.state_name = #{quote(args[:customer_state].to_s.upcase)}" if args[:customer_state].present?

        order_by = case args[:sort]
                   when "total_desc" then "o.total DESC"
                   when "days_late"  then "d.days_late DESC NULLS LAST"
                   when "review_asc" then "r.score ASC NULLS LAST"
                   else "d.purchased_at DESC"
                   end

        from_sql = <<~SQL
          FROM spree_orders o
          JOIN olist_order_details d ON d.spree_order_id = o.id
     LEFT JOIN olist_reviews r ON r.spree_order_id = o.id
     LEFT JOIN spree_addresses a ON a.id = o.bill_address_id
         WHERE #{where.join(' AND ')}
        SQL

        total = sql("SELECT COUNT(*) AS c #{from_sql}").first["c"].to_i
        limit = limit_for(args[:limit])

        rows = sql(<<~SQL).map do |r|
          SELECT o.number, d.purchased_at, d.olist_status, o.total, o.item_count,
                 a.city, a.state_name AS state, d.delivery_days, d.days_late, r.score
          #{from_sql}
          ORDER BY #{order_by}
          LIMIT #{limit}
        SQL
          {
            number: r["number"],
            purchased_at: date(r["purchased_at"]),
            status: r["olist_status"],
            total: r["total"].to_f,
            items: r["item_count"].to_i,
            city: r["city"],
            state: r["state"],
            delivery_days: r["delivery_days"]&.to_i,
            days_late: r["days_late"]&.to_i,
            review: r["score"]&.to_i
          }
        end

        text = table(
          rows.map { |r| r.merge(total: money(r[:total])) },
          [[:number, "ORDER"], [:purchased_at, "PURCHASED"], [:status, "STATUS"],
           [:total, "TOTAL"], [:items, "ITEMS"], [:state, "ST"],
           [:delivery_days, "DAYS"], [:days_late, "LATE"], [:review, "REVIEW"]]
        ) + footer(rows.size, total, limit)

        ok(text, structured: { total_matches: total, orders: rows })
      end
    end
  end
end
