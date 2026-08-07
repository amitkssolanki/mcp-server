# frozen_string_literal: true

module StoreMcp
  module Tools
    class SearchProducts < BaseTool
      tool_name "search_products"
      title "Search products"
      description <<~DESC
        Find products in the catalogue by name, SKU, or category, with optional
        price bounds. Call this when the question names a product or a category
        and you need IDs, prices, or sales figures before doing anything else —
        most other product tools take an ID this returns.

        Results are ranked by the sort you choose (revenue by default) and are
        truncated; the response says so when there are more matches. Returns a
        compact row per product, not the full record — use `get_product` for
        that.
      DESC

      input_schema(
        properties: {
          query: { type: "string", description: "Free text matched against product name and SKU." },
          category: { type: "string", description: "Category name, e.g. 'Health Beauty'. Partial matches allowed." },
          min_price: { type: "number", description: "Minimum unit price in BRL." },
          max_price: { type: "number", description: "Maximum unit price in BRL." },
          sort: {
            type: "string",
            enum: %w[revenue units_sold price_asc price_desc name],
            description: "Ordering. Defaults to revenue (highest first)."
          },
          limit: { type: "integer", description: "Max rows, 1-50. Defaults to 20." }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        # Joined by hand rather than through `master: :default_price` — that
        # association is deprecated in Spree 5 and warns on every call.
        scope = products_scope(server_context)
          .joins("JOIN spree_variants ON spree_variants.product_id = spree_products.id AND spree_variants.is_master = TRUE")
          .joins("JOIN spree_prices ON spree_prices.variant_id = spree_variants.id AND spree_prices.currency = 'BRL' AND spree_prices.price_list_id IS NULL")
          .joins("JOIN spree_products_taxons pt ON pt.product_id = spree_products.id")
          .joins("JOIN spree_taxons t ON t.id = pt.taxon_id")

        if args[:query].present?
          term = "%#{args[:query].to_s.downcase}%"
          scope = scope.where(
            "LOWER(spree_products.name) LIKE :t OR LOWER(spree_variants.sku) LIKE :t", t: term
          )
        end
        scope = scope.where("LOWER(t.name) LIKE ?", "%#{args[:category].to_s.downcase}%") if args[:category].present?
        scope = scope.where("spree_prices.amount >= ?", args[:min_price]) if args[:min_price]
        scope = scope.where("spree_prices.amount <= ?", args[:max_price]) if args[:max_price]

        scope = case args[:sort]
                when "units_sold" then scope.order(units_sold_count: :desc)
                when "price_asc"  then scope.order("spree_prices.amount ASC")
                when "price_desc" then scope.order("spree_prices.amount DESC")
                when "name"       then scope.order(:name)
                else scope.order(revenue: :desc)
                end

        total = scope.count
        limit = limit_for(args[:limit])
        rows = scope.limit(limit).pluck(
          "spree_products.id", "spree_products.name", "spree_variants.sku",
          "t.name", "spree_prices.amount", "spree_products.units_sold_count",
          "spree_products.revenue", "spree_products.status"
        ).map do |id, name, sku, taxon, price, units, revenue, status|
          {
            id: id, name: name, sku: sku, category: taxon,
            price: price.to_f, units_sold: units, revenue: revenue.to_f, status: status
          }
        end

        text = table(
          rows.map { |r| r.merge(price: money(r[:price]), revenue: money(r[:revenue])) },
          [[:id, "ID"], [:name, "PRODUCT"], [:category, "CATEGORY"], [:price, "PRICE"],
           [:units_sold, "SOLD"], [:revenue, "REVENUE"], [:status, "STATUS"]]
        ) + footer(rows.size, total, limit)

        ok(text, structured: { total_matches: total, products: rows })
      end
    end
  end
end
