# frozen_string_literal: true

module StoreMcp
  module Tools
    class FindCustomer < BaseTool
      tool_name "find_customer"
      title "Find a customer"
      description <<~DESC
        Look up a customer by email and return their order history summary:
        lifetime spend, order count, where they are, and how they have rated
        their orders. Call this when the user names a customer, or when you
        need to judge whether a complaint comes from a repeat buyer.

        Returns the customer's orders in date order. Use `get_order` for the
        contents of any one of them.
      DESC

      input_schema(
        properties: {
          email: { type: "string", description: "Customer email address, exact or partial." },
          limit: { type: "integer", description: "Max orders to list, 1-50. Defaults to 20." }
        },
        required: ["email"]
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        term = "%#{args[:email].to_s.downcase.strip}%"

        user = Spree.user_class.where("LOWER(email) LIKE ?", term).first
        return failure("No customer matching #{args[:email]}.") if user.nil?

        limit = limit_for(args[:limit])
        rows = sql(<<~SQL).map do |r|
          SELECT o.number, d.purchased_at, d.olist_status, o.total,
                 d.days_late, rev.score, a.city, a.state_name AS state
            FROM spree_orders o
            JOIN olist_order_details d ON d.spree_order_id = o.id
       LEFT JOIN olist_reviews rev ON rev.spree_order_id = o.id
       LEFT JOIN spree_addresses a ON a.id = o.bill_address_id
           WHERE o.user_id = #{user.id.to_i} AND o.store_id = #{store_id.to_i}
           ORDER BY d.purchased_at DESC
           LIMIT #{limit}
        SQL
          {
            number: r["number"], purchased_at: date(r["purchased_at"]), status: r["olist_status"],
            total: r["total"].to_f, days_late: r["days_late"]&.to_i, review: r["score"]&.to_i,
            city: r["city"], state: r["state"]
          }
        end

        summary = sql(<<~SQL).first
          SELECT COUNT(*) AS orders, COALESCE(SUM(o.total),0) AS lifetime,
                 ROUND(AVG(rev.score), 2) AS avg_review
            FROM spree_orders o
       LEFT JOIN olist_reviews rev ON rev.spree_order_id = o.id
           WHERE o.user_id = #{user.id.to_i} AND o.store_id = #{store_id.to_i}
        SQL

        structured = {
          email: user.email, name: [user.first_name, user.last_name].compact.join(" "),
          orders: summary["orders"].to_i, lifetime_value: summary["lifetime"].to_f,
          avg_review: summary["avg_review"]&.to_f,
          location: [rows.first&.dig(:city), rows.first&.dig(:state)].compact.join(", "),
          recent_orders: rows
        }

        text = <<~TEXT.strip
          #{user.email}
          Orders       #{structured[:orders]}
          Lifetime     #{money(structured[:lifetime_value])}
          Avg review   #{structured[:avg_review] || '—'}
          Location     #{structured[:location].presence || '—'}

          #{table(rows.map { |r| r.merge(total: money(r[:total])) },
                  [[:number, 'ORDER'], [:purchased_at, 'PURCHASED'], [:status, 'STATUS'],
                   [:total, 'TOTAL'], [:days_late, 'LATE'], [:review, 'REVIEW']])}
        TEXT

        ok(text, structured: structured)
      end
    end
  end
end
