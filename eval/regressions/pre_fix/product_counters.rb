# frozen_string_literal: true

module Eval
  module Regressions
    module PreFix
      # PROVENANCE: the product sales counter backfill, verbatim from
      # lib/olist/importer.rb at commit 9fa9b02. It counted items from every
      # order, cancelled and unavailable ones included (F5). Applied inside a
      # transaction that is always rolled back.
      PRODUCT_COUNTERS_SQL = <<~SQL
      UPDATE spree_products p
         SET units_sold_count = t.units, revenue = t.revenue
        FROM (
          SELECT v.product_id,
                 SUM(li.quantity)             AS units,
                 SUM(li.price * li.quantity)  AS revenue
            FROM spree_line_items li
            JOIN spree_variants v ON v.id = li.variant_id
           GROUP BY v.product_id
        ) t
       WHERE p.id = t.product_id
      SQL

      PRODUCT_COUNTERS = -> { ActiveRecord::Base.connection.execute(PRODUCT_COUNTERS_SQL) }
    end
  end
end
