# frozen_string_literal: true

module StoreMcp
  module Tools
    class ListCategories < BaseTool
      tool_name "list_categories"
      title "List categories"
      description <<~DESC
        Every category in the store with its product count, revenue, units sold,
        and average review score. Call this first when a question is about the
        catalogue as a whole ("which categories underperform?"), or when you
        need the exact category name to pass to another tool — category filters
        elsewhere expect the names this returns.

        Small and cheap: the whole catalogue is a few dozen rows.
      DESC

      input_schema(
        properties: {
          sort: {
            type: "string",
            enum: %w[revenue products units avg_review name],
            description: "Ordering. Defaults to revenue (highest first)."
          }
        },
        required: []
      )

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, **args)
        store_id = store(server_context).id
        order_by = case args[:sort]
                   when "products"   then "products DESC"
                   when "units"      then "units DESC"
                   when "avg_review" then "avg_review ASC NULLS LAST"
                   when "name"       then "category ASC"
                   else "revenue DESC NULLS LAST"
                   end

        # p.units_sold_count and p.revenue are already per-product totals
        # (maintained by the importer's backfill pass), so they must be summed
        # over one row per product — never over a join to line items or
        # reviews, which multiplies each product's total by however many of
        # each it matches. category_products enforces the one-row-per-product
        # shape; avg_review is computed separately, deduplicated to one row
        # per (category, order) so an order with several line items in the
        # same category doesn't weight that order's score more than once.
        rows = sql(<<~SQL).map do |r|
          WITH category_products AS (
            SELECT t.name AS category, p.id AS product_id,
                   COALESCE(p.units_sold_count, 0) AS units_sold_count,
                   COALESCE(p.revenue, 0)          AS revenue
              FROM spree_taxons t
              JOIN spree_products_taxons pt ON pt.taxon_id = t.id
              JOIN spree_products p ON p.id = pt.product_id AND p.store_id = #{store_id.to_i}
          ),
          category_order_reviews AS (
            SELECT DISTINCT cp.category, li.order_id, rev.score
              FROM category_products cp
              JOIN spree_variants v ON v.product_id = cp.product_id AND v.is_master = TRUE
              JOIN spree_line_items li ON li.variant_id = v.id
              JOIN olist_reviews rev ON rev.spree_order_id = li.order_id
          )
          SELECT cp.category,
                 COUNT(DISTINCT cp.product_id) AS products,
                 SUM(cp.units_sold_count)      AS units,
                 SUM(cp.revenue)               AS revenue,
                 (SELECT ROUND(AVG(cor.score), 2)
                    FROM category_order_reviews cor
                   WHERE cor.category = cp.category) AS avg_review
            FROM category_products cp
           GROUP BY cp.category
           ORDER BY #{order_by}
        SQL
          {
            category: r["category"],
            products: r["products"].to_i,
            units_sold: r["units"].to_i,
            revenue: r["revenue"].to_f,
            avg_review: r["avg_review"]&.to_f
          }
        end

        text = table(
          rows.map { |r| r.merge(revenue: money(r[:revenue])) },
          [[:category, "CATEGORY"], [:products, "PRODUCTS"], [:units_sold, "UNITS"],
           [:revenue, "REVENUE"], [:avg_review, "AVG REVIEW"]]
        ) + "\n\n#{rows.size} categories."

        ok(text, structured: { categories: rows })
      end
    end
  end
end
