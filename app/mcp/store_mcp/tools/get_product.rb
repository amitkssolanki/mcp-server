# frozen_string_literal: true

module StoreMcp
  module Tools
    class GetProduct < BaseTool
      tool_name "get_product"
      title "Get one product"
      description <<~DESC
        Full detail for a single product: price, category, physical dimensions,
        lifetime sales, and how its recent buyers rated their orders. Call this
        after `search_products` when you need more than the summary row, or
        whenever the user names a specific SKU.

        Accepts either the numeric product ID or the SKU. Returns an error if
        neither is given.
      DESC

      input_schema(
        properties: {
          product_id: { type: "integer", description: "Numeric product ID." },
          sku: { type: "string", description: "Product SKU (the original Olist product_id)." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        scope = products_scope(server_context)
        product =
          if args[:product_id]
            scope.find_by(id: args[:product_id])
          elsif args[:sku].present?
            scope.joins(:variants_including_master).find_by(spree_variants: { sku: args[:sku] })
          else
            return failure("Provide either product_id or sku.")
          end

        return failure("No product found for #{args[:product_id] || args[:sku]}.") if product.nil?

        master = product.master
        taxon = product.taxons.first
        stats = sql(<<~SQL).first
          SELECT COUNT(DISTINCT li.order_id)   AS orders,
                 ROUND(AVG(r.score), 2)        AS avg_review,
                 ROUND(AVG(d.days_late), 1)    AS avg_days_late
            FROM spree_line_items li
            JOIN spree_variants v ON v.id = li.variant_id
       LEFT JOIN olist_reviews r ON r.spree_order_id = li.order_id
       LEFT JOIN olist_order_details d ON d.spree_order_id = li.order_id
           WHERE v.product_id = #{product.id.to_i}
        SQL

        detail = {
          id: product.id,
          name: product.name,
          sku: master.sku,
          slug: product.slug,
          status: product.status,
          category: taxon&.name,
          price: master.price_in("BRL")&.amount.to_f,
          units_sold: product.units_sold_count,
          revenue: product.revenue.to_f,
          orders: stats["orders"].to_i,
          avg_review: stats["avg_review"]&.to_f,
          avg_days_late: stats["avg_days_late"]&.to_f,
          weight_g: master.weight&.to_f,
          dimensions_cm: [master.depth, master.height, master.width].map { |d| d&.to_f }
        }

        text = <<~TEXT.strip
          #{product.name} (ID #{product.id})
          SKU          #{master.sku}
          Category     #{taxon&.name || '—'}
          Price        #{money(detail[:price])}
          Status       #{product.status}
          Lifetime     #{product.units_sold_count} units across #{detail[:orders]} orders, #{money(detail[:revenue])}
          Reviews      #{detail[:avg_review] || '—'} average
          Delivery     #{delivery_phrase(detail[:avg_days_late])}
          Physical     #{master.weight&.to_i}g, #{detail[:dimensions_cm].compact.join(' x ')} cm
          Description  #{product.description}
        TEXT

        ok(text, structured: detail)
      end

      def self.delivery_phrase(days_late)
        return "—" if days_late.nil?
        return "#{days_late.abs} days early on average" if days_late.negative?

        "#{days_late} days late on average"
      end
    end
  end
end
