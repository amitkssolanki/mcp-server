# frozen_string_literal: true

namespace :olist do
  desc "Import the Olist dataset into Spree (DESTRUCTIVE: truncates Spree catalogue/order tables). LIMIT=n for a subset"
  task import: :environment do
    require Rails.root.join("lib/olist/importer")

    dir = ENV.fetch("OLIST_DIR", Rails.root.join("db/olist").to_s)
    abort "No CSVs found in #{dir} — see db/olist/README.md" unless Dir.glob("#{dir}/*.csv").any?

    Olist::Importer.new(dir: dir, limit: ENV["LIMIT"]).run!
  end

  desc "Check the imported data is internally consistent and valid to Spree"
  task verify: :environment do
    failures = []
    check = lambda do |label, actual, expected|
      ok = expected.is_a?(Proc) ? expected.call(actual) : (actual == expected)
      failures << label unless ok
      puts format("  %s %-46s %s", ok ? "ok  " : "FAIL", label, actual)
    end

    puts "Row counts"
    check.call("products",     Spree::Product.count,   32_951)
    check.call("variants",     Spree::Variant.count,   32_951)
    check.call("orders",       Spree::Order.count,     99_441)
    check.call("line items",   Spree::LineItem.count,  112_650)
    check.call("payments",     Spree::Payment.count,   103_886)
    check.call("sellers",      OlistSeller.count,      3_095)
    check.call("reviews",      OlistReview.count,      ->(n) { n > 98_000 })
    check.call("users",        Spree.user_class.count, ->(n) { n.between?(90_000, 99_441) })
    check.call("addresses",    Spree::Address.count,   99_441)

    puts "\nReferential integrity"
    check.call("line items with a missing order", Spree::LineItem.where.missing(:order).count, 0)
    check.call("orders with a missing user",
               Spree::Order.where.not(user_id: nil).where.missing(:user).count, 0)
    check.call("order details without an order",
               OlistOrderDetail.where.missing(:spree_order).count, 0)
    check.call("addresses without a BR state",
               Spree::Address.where(state_id: nil).count, 0)

    puts "\nSpree validity (derived columns Spree would normally maintain)"
    check.call("orders with total = 0 but line items",
               Spree::Order.joins(:line_items).where(total: 0).distinct.count, 0)
    check.call("orders where total != item_total + shipment_total",
               Spree::Order.where("total <> item_total + shipment_total").count, 0)
    check.call("master variants missing a BRL price",
               Spree::Variant.where.not(id: Spree::Price.where(currency: "BRL").select(:variant_id)).count, 0)
    check.call("products not linked to a taxon",
               Spree::Product.where.not(
                 id: ActiveRecord::Base.connection.select_values("select product_id from spree_products_taxons")
               ).count, 0)

    puts "\nSample record round-trips through ActiveRecord"
    order = Spree::Order.joins(:line_items).order("RANDOM()").first
    puts "  order #{order.number}: #{order.line_items.count} items, " \
         "total #{order.total} #{order.currency}, state=#{order.state}"
    product = Spree::Product.where("units_sold_count > 0").order("RANDOM()").first
    puts "  product #{product.name.inspect}: #{product.units_sold_count} sold, " \
         "revenue #{product.revenue}, price #{product.master.price_in('BRL').amount}"

    if failures.any?
      abort "\n#{failures.size} check(s) FAILED: #{failures.join(', ')}"
    else
      puts "\nAll checks passed."
    end
  end

  desc "Run sample analytics queries against the imported data"
  task queries: :environment do
    run = lambda do |title, sql|
      puts "\n#{title}"
      puts "-" * title.length
      rows = ActiveRecord::Base.connection.select_all(sql).to_a
      return puts("  (no rows)") if rows.empty?

      keys = rows.first.keys
      widths = keys.to_h { |k| [k, ([k.to_s] + rows.map { |r| r[k].to_s }).map(&:length).max + 2] }
      puts "  " + keys.map { |k| k.to_s.ljust(widths[k]) }.join
      rows.each { |r| puts "  " + keys.map { |k| r[k].to_s.ljust(widths[k]) }.join }
    end

    run.call "Review score vs delivery lateness", <<~SQL
      SELECT CASE
               WHEN d.days_late <= 0 THEN 'on time or early'
               WHEN d.days_late <= 3 THEN '1-3 days late'
               WHEN d.days_late <= 7 THEN '4-7 days late'
               ELSE 'more than a week late'
             END AS delivery,
             COUNT(*) AS orders,
             ROUND(AVG(r.score), 2) AS avg_review
        FROM olist_order_details d
        JOIN olist_reviews r ON r.spree_order_id = d.spree_order_id
       WHERE d.days_late IS NOT NULL
       GROUP BY 1
       ORDER BY MIN(d.days_late)
    SQL

    run.call "Top 10 categories by revenue", <<~SQL
      SELECT t.name AS category,
             COUNT(DISTINCT li.order_id) AS orders,
             ROUND(SUM(li.price * li.quantity), 2) AS revenue_brl
        FROM spree_line_items li
        JOIN spree_variants v  ON v.id = li.variant_id
        JOIN spree_products_taxons pt ON pt.product_id = v.product_id
        JOIN spree_taxons t    ON t.id = pt.taxon_id
       GROUP BY t.name
       ORDER BY revenue_brl DESC
       LIMIT 10
    SQL

    run.call "Monthly revenue, 2017", <<~SQL
      SELECT TO_CHAR(DATE_TRUNC('month', d.purchased_at), 'YYYY-MM') AS month,
             COUNT(*) AS orders,
             ROUND(SUM(o.total), 2) AS revenue_brl
        FROM olist_order_details d
        JOIN spree_orders o ON o.id = d.spree_order_id
       WHERE d.purchased_at >= '2017-01-01' AND d.purchased_at < '2018-01-01'
       GROUP BY 1 ORDER BY 1
    SQL

    run.call "Worst 5 sellers by review score (min 100 orders)", <<~SQL
      SELECT s.olist_seller_id, s.state,
             COUNT(DISTINCT li.order_id) AS orders,
             ROUND(AVG(r.score), 2) AS avg_review,
             ROUND(AVG(d.days_late), 1) AS avg_days_late
        FROM olist_sellers s
        JOIN olist_line_item_details lid ON lid.olist_seller_id = s.id
        JOIN spree_line_items li ON li.id = lid.spree_line_item_id
        JOIN olist_reviews r ON r.spree_order_id = li.order_id
        JOIN olist_order_details d ON d.spree_order_id = li.order_id
       GROUP BY s.id, s.olist_seller_id, s.state
      HAVING COUNT(DISTINCT li.order_id) >= 100
       ORDER BY avg_review ASC
       LIMIT 5
    SQL

    run.call "Payment method mix", <<~SQL
      SELECT payment_type,
             COUNT(*) AS payments,
             ROUND(AVG(installments), 2) AS avg_installments
        FROM olist_payment_details
       GROUP BY payment_type ORDER BY payments DESC
    SQL
  end
end
