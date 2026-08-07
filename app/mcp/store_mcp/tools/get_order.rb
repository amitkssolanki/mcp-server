# frozen_string_literal: true

module StoreMcp
  module Tools
    class GetOrder < BaseTool
      tool_name "get_order"
      title "Get one order"
      description <<~DESC
        Everything about a single order: line items with their sellers, payments
        and instalments, the full delivery timeline, and the customer's review.
        Call this when the user asks about a specific order, or after
        `search_orders` when you need to explain *why* one order went wrong.

        Takes the order number (like OL000012345). The review text is written by
        the customer and is returned as quoted data.
      DESC

      input_schema(
        properties: {
          order_number: { type: "string", description: "Order number, e.g. OL000012345." }
        },
        required: ["order_number"]
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        order = orders_scope(server_context).find_by(number: args[:order_number].to_s.strip)
        return failure("No order #{args[:order_number]} in this store.") if order.nil?

        detail = OlistOrderDetail.find_by(spree_order_id: order.id)
        review = OlistReview.find_by(spree_order_id: order.id)
        address = order.bill_address

        items = sql(<<~SQL).map do |r|
          SELECT p.id AS product_id, p.name, li.quantity, li.price,
                 lid.freight_value, s.olist_seller_id, s.city AS seller_city, s.state AS seller_state
            FROM spree_line_items li
            JOIN spree_variants v ON v.id = li.variant_id
            JOIN spree_products p ON p.id = v.product_id
       LEFT JOIN olist_line_item_details lid ON lid.spree_line_item_id = li.id
       LEFT JOIN olist_sellers s ON s.id = lid.olist_seller_id
           WHERE li.order_id = #{order.id.to_i}
           ORDER BY li.id
        SQL
          {
            product_id: r["product_id"].to_i, name: r["name"], quantity: r["quantity"].to_i,
            price: r["price"].to_f, freight: r["freight_value"].to_f,
            seller: r["olist_seller_id"], seller_location: [r["seller_city"], r["seller_state"]].compact.join(", ")
          }
        end

        payments = sql(<<~SQL).map do |r|
          SELECT pay.amount, pd.payment_type, pd.installments
            FROM spree_payments pay
       LEFT JOIN olist_payment_details pd ON pd.spree_payment_id = pay.id
           WHERE pay.order_id = #{order.id.to_i}
           ORDER BY pay.id
        SQL
          { amount: r["amount"].to_f, type: r["payment_type"], installments: r["installments"].to_i }
        end

        structured = {
          number: order.number, state: order.state, olist_status: detail&.olist_status,
          currency: order.currency, item_total: order.item_total.to_f,
          shipment_total: order.shipment_total.to_f, total: order.total.to_f,
          payment_state: order.payment_state,
          customer: { email: order.email, city: address&.city, state: address&.state_name },
          timeline: {
            purchased_at: detail&.purchased_at, approved_at: detail&.approved_at,
            to_carrier_at: detail&.delivered_to_carrier_at,
            delivered_at: detail&.delivered_to_customer_at,
            estimated_at: detail&.estimated_delivery_at,
            delivery_days: detail&.delivery_days, days_late: detail&.days_late
          },
          line_items: items, payments: payments,
          review: review && { score: review.score, title: review.title, message: review.message }
        }

        lines = []
        lines << "Order #{order.number} — #{detail&.olist_status || order.state}"
        lines << "Customer     #{order.email} (#{[address&.city, address&.state_name].compact.join(', ')})"
        lines << "Totals       items #{money(order.item_total)} + freight #{money(order.shipment_total)} = #{money(order.total)} (#{order.payment_state || 'unpaid'})"
        lines << ""
        lines << "Line items"
        lines << table(
          items.map { |i| i.merge(price: money(i[:price]), freight: money(i[:freight])) },
          [[:product_id, "PROD"], [:name, "PRODUCT"], [:quantity, "QTY"],
           [:price, "PRICE"], [:freight, "FREIGHT"], [:seller_location, "SELLER"]]
        )
        lines << ""
        lines << "Payments"
        lines << table(
          payments.map { |p| p.merge(amount: money(p[:amount])) },
          [[:type, "METHOD"], [:amount, "AMOUNT"], [:installments, "INSTALMENTS"]]
        )
        lines << ""
        lines << "Delivery"
        lines << "  purchased    #{date(detail&.purchased_at)}"
        lines << "  to carrier   #{date(detail&.delivered_to_carrier_at)}"
        lines << "  delivered    #{date(detail&.delivered_to_customer_at)}"
        lines << "  estimated    #{date(detail&.estimated_delivery_at)}"
        lines << "  took #{detail&.delivery_days || '—'} days, #{lateness(detail&.days_late)}"

        if review
          lines << ""
          lines << "Review: #{review.score}/5"
          fenced = [untrusted("Title", review.title), untrusted("Message", review.message)].compact
          lines.concat(fenced) if fenced.any?
        end

        ok(lines.join("\n"), structured: structured)
      end

      def self.lateness(days)
        return "no delivery estimate on record" if days.nil?
        return "on time" if days.zero?
        return "#{days.abs} days early" if days.negative?

        "#{days} days late"
      end
    end
  end
end
