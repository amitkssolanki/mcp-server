# frozen_string_literal: true

require "csv"

module Olist
  # Spree exposes no models for these join tables, so we declare our own
  # rather than hand-rolling SQL for them.
  class ProductTaxon < ActiveRecord::Base
    self.table_name = "spree_products_taxons"
  end

  class ProductStore < ActiveRecord::Base
    self.table_name = "spree_products_stores"
  end

  # Imports the Brazilian E-Commerce Public Dataset by Olist into Spree.
  #
  # Why this bypasses ActiveRecord:
  #
  # Spree's Order model runs a state machine, totals recalculation, inventory
  # unit generation and a pile of callbacks on every save. That is correct for
  # one order placed by one human; it is unusable for 100k. A callback-driven
  # import of this dataset takes hours. Everything here goes in through
  # `insert_all` with explicitly assigned primary keys, and the derived columns
  # Spree would normally maintain (order totals, product counters) are
  # backfilled afterwards in SQL — see #backfill_derived_columns.
  #
  # The tradeoff is real and worth stating: we are responsible for producing
  # rows Spree would consider valid. That is why #verify! exists.
  class Importer
    BATCH = 5_000
    CURRENCY = "BRL"

    # Olist ships anonymised customers with no street address. Rather than
    # invent one and have the data quietly lie, we mark it.
    UNKNOWN_STREET = "(not in dataset)"

    # Olist order status -> Spree order state.
    # Anything that reached the seller is "complete" as far as Spree is
    # concerned; the finer-grained Olist status stays on OlistOrderDetail.
    STATE_MAP = {
      "delivered"   => "complete",
      "shipped"     => "complete",
      "invoiced"    => "complete",
      "processing"  => "complete",
      "approved"    => "complete",
      "created"     => "cart",
      "unavailable" => "canceled",
      "canceled"    => "canceled"
    }.freeze

    attr_reader :dir, :limit, :stats

    def initialize(dir:, limit: nil, io: $stdout)
      @dir = Pathname.new(dir)
      @limit = limit&.to_i
      @io = io
      @stats = {}
      @skipped = Hash.new(0)
    end

    def run!
      started = Time.now
      log "Importing from #{dir}#{limit ? " (limit: #{limit} orders)" : ""}"

      truncate!
      prepare_store!
      import_sellers
      import_taxons
      import_products
      import_customers
      import_orders
      import_line_items
      import_payments
      import_reviews
      backfill_derived_columns
      reset_sequences!

      log ""
      log "Done in #{(Time.now - started).round(1)}s"
      report_skips
      stats
    end

    private

    def log(msg) = @io.puts(msg)

    def path(name) = dir.join("#{name}.csv")

    # Olist timestamps are "YYYY-MM-DD HH:MM:SS" in Brazil local time. We store
    # them as-is and treat them as UTC: the dataset has no offset information,
    # and inventing one would be worse than being consistent. Hand-sliced
    # rather than Time.parse — this runs ~500k times.
    def ts(value)
      return nil if value.nil? || value.empty?

      Time.utc(value[0, 4].to_i, value[5, 2].to_i, value[8, 2].to_i,
               value[11, 2].to_i, value[14, 2].to_i, value[17, 2].to_i)
    rescue ArgumentError
      nil
    end

    def now = @now ||= Time.now.utc

    def truncate!
      tables = %w[
        olist_payment_details olist_line_item_details olist_reviews
        olist_order_details olist_sellers
        spree_payments spree_line_items spree_orders
        spree_stock_items spree_products_taxons spree_products_stores
        spree_prices spree_variants spree_products
        spree_taxons spree_taxonomies
        spree_addresses spree_users
      ]
      log "Truncating #{tables.size} tables"
      ActiveRecord::Base.connection.execute(
        "TRUNCATE TABLE #{tables.join(', ')} RESTART IDENTITY CASCADE"
      )
    end

    def store
      @store ||= Spree::Store.default
    end

    def prepare_store!
      store.update_columns(
        default_currency: CURRENCY,
        supported_currencies: CURRENCY,
        updated_at: now
      )
      @channel_id = Spree::Channel.where(store_id: store.id).order(default: :desc).first&.id
      @shipping_category_id = Spree::ShippingCategory.first&.id ||
                              Spree::ShippingCategory.create!(name: "Default").id
      @payment_method_id = Spree::PaymentMethod.first&.id
      @stock_location_id = Spree::StockLocation.first&.id
      @country_id = Spree::Country.find_by(iso: "BR")&.id
      @state_ids = Spree::State.joins(:country)
                               .where(spree_countries: { iso: "BR" })
                               .pluck(:abbr, :id).to_h
      log "Store ##{store.id} set to #{CURRENCY}; #{@state_ids.size} BR states available"
    end

    # --- sellers -----------------------------------------------------------

    def import_sellers
      rows = []
      @seller_ids = {}
      id = 0

      CSV.foreach(path("olist_sellers_dataset"), headers: true) do |r|
        id += 1
        @seller_ids[r["seller_id"]] = id
        rows << {
          id: id,
          olist_seller_id: r["seller_id"],
          zip_code_prefix: r["seller_zip_code_prefix"],
          city: r["seller_city"],
          state: r["seller_state"],
          created_at: now, updated_at: now
        }
      end

      flush(OlistSeller, rows)
      record(:sellers, id)
    end

    # --- categories --------------------------------------------------------

    # Only 71 of these, and awesome_nested_set has to maintain lft/rgt/depth,
    # so this one goes through ActiveRecord. Bulk-inserting a nested set by
    # hand is a great way to produce a subtly broken tree.
    def import_taxons
      translations = {}
      # This file carries a UTF-8 BOM; without bom|utf-8 the first header key
      # comes back as "﻿product_category_name" and every lookup misses.
      CSV.foreach(path("product_category_name_translation"),
                  headers: true, encoding: "bom|utf-8") do |r|
        translations[r["product_category_name"]] = r["product_category_name_english"]
      end

      taxonomy = Spree::Taxonomy.create!(name: "Categories", store: store)
      root = taxonomy.root

      @taxon_ids = {}
      @category_titles = {}

      categories = CSV.read(path("olist_products_dataset"), headers: true)
                      .map { |r| r["product_category_name"] }
                      .compact.uniq.sort

      categories.each do |pt_name|
        title = titleize(translations[pt_name] || pt_name)
        taxon = Spree::Taxon.create!(name: title, taxonomy: taxonomy, parent: root)
        @taxon_ids[pt_name] = taxon.id
        @category_titles[pt_name] = title
      end

      # Olist has ~600 products with a blank category.
      uncategorised = Spree::Taxon.create!(name: "Uncategorised", taxonomy: taxonomy, parent: root)
      @taxon_ids[nil] = uncategorised.id
      @category_titles[nil] = "Uncategorised"

      record(:taxons, @taxon_ids.size)
    end

    def titleize(slug)
      slug.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    # --- products ----------------------------------------------------------

    def import_products
      # Olist prices live on order_items, not products — the same product sells
      # at different prices across orders. One pass to take a representative
      # price per product before we can write spree_prices.
      prices = {}
      CSV.foreach(path("olist_order_items_dataset"), headers: true) do |r|
        prices[r["product_id"]] ||= r["price"]
      end

      products, variants, price_rows, classifications, product_stores, stock_items = [], [], [], [], [], []
      @product_ids = {}   # olist product_id -> [product_id, variant_id]
      pid = 0

      CSV.foreach(path("olist_products_dataset"), headers: true) do |r|
        pid += 1
        olist_id = r["product_id"]
        category = r["product_category_name"].presence
        title = @category_titles.fetch(category, "Uncategorised")

        @product_ids[olist_id] = [pid, pid]

        products << {
          id: pid,
          name: "#{title} #{olist_id[0, 6].upcase}",
          # Olist products carry no title or copy — only a category and
          # measurements. Describing exactly that beats inventing marketing text.
          description: product_description(r),
          slug: "#{title.parameterize}-#{olist_id[0, 10]}",
          status: "active",
          available_on: Time.utc(2016, 1, 1),
          store_id: store.id,
          shipping_category_id: @shipping_category_id,
          variant_count: 1,
          classification_count: 1,
          created_at: now, updated_at: now
        }

        variants << {
          id: pid,
          product_id: pid,
          sku: olist_id,
          is_master: true,
          position: 1,
          track_inventory: false,
          weight: r["product_weight_g"].presence || 0,
          weight_unit: "g",
          height: r["product_height_cm"].presence,
          width: r["product_width_cm"].presence,
          depth: r["product_length_cm"].presence,
          dimensions_unit: "cm",
          created_at: now, updated_at: now
        }

        price_rows << {
          variant_id: pid,
          amount: prices[olist_id] || 0,
          currency: CURRENCY,
          created_at: now, updated_at: now
        }

        classifications << {
          product_id: pid, taxon_id: @taxon_ids.fetch(category, @taxon_ids[nil]),
          position: 1, created_at: now, updated_at: now
        }

        product_stores << {
          product_id: pid, store_id: store.id, created_at: now, updated_at: now
        }

        if @stock_location_id
          stock_items << {
            variant_id: pid, stock_location_id: @stock_location_id,
            count_on_hand: 0, backorderable: true,
            created_at: now, updated_at: now
          }
        end

        if products.size >= BATCH
          flush_products(products, variants, price_rows, classifications, product_stores, stock_items)
        end
      end

      flush_products(products, variants, price_rows, classifications, product_stores, stock_items)
      record(:products, pid)
    end

    def product_description(row)
      parts = []
      parts << "#{row['product_weight_g']}g" if row["product_weight_g"].present?
      dims = [row["product_length_cm"], row["product_height_cm"], row["product_width_cm"]]
      parts << "#{dims.join(' x ')} cm" if dims.all?(&:present?)
      parts << "#{row['product_photos_qty']} photos" if row["product_photos_qty"].present?
      "Olist catalogue item. #{parts.join(', ')}."
    end

    def flush_products(products, variants, prices, classifications, product_stores, stock_items)
      flush(Spree::Product, products)
      flush(Spree::Variant, variants)
      flush(Spree::Price, prices)
      flush(ProductTaxon, classifications)
      flush(ProductStore, product_stores)
      flush(Spree::StockItem, stock_items)
    end

    # --- customers ---------------------------------------------------------

    # Olist has one customers row per order (customer_id), with
    # customer_unique_id identifying the actual person. So: one Spree user per
    # unique person, one address per order-customer row.
    def import_customers
      users, addresses = [], []
      @user_ids = {}      # customer_unique_id -> spree user id
      @address_ids = {}   # customer_id -> [user_id, address_id]
      uid = 0
      aid = 0

      CSV.foreach(path("olist_customers_dataset"), headers: true) do |r|
        unique_id = r["customer_unique_id"]

        user_id = @user_ids[unique_id]
        unless user_id
          uid += 1
          user_id = uid
          @user_ids[unique_id] = uid
          users << {
            id: uid,
            email: "#{unique_id}@olist.invalid", # RFC 2606 — never routable
            first_name: "Customer",
            last_name: unique_id[0, 8].upcase,
            created_at: now, updated_at: now
          }
        end

        aid += 1
        @address_ids[r["customer_id"]] = [user_id, aid]
        addresses << {
          id: aid,
          user_id: user_id,
          firstname: "Customer",
          lastname: unique_id[0, 8].upcase,
          address1: UNKNOWN_STREET,
          city: titleize(r["customer_city"]),
          zipcode: r["customer_zip_code_prefix"],
          state_id: @state_ids[r["customer_state"]],
          state_name: r["customer_state"],
          country_id: @country_id,
          created_at: now, updated_at: now
        }

        if addresses.size >= BATCH
          flush(Spree.user_class, users)
          flush(Spree::Address, addresses)
        end
      end

      flush(Spree.user_class, users)
      flush(Spree::Address, addresses)
      record(:users, uid)
      record(:addresses, aid)
    end

    # --- orders ------------------------------------------------------------

    def import_orders
      orders, details = [], []
      @order_ids = {}
      oid = 0

      CSV.foreach(path("olist_orders_dataset"), headers: true) do |r|
        break if limit && oid >= limit

        customer = @address_ids[r["customer_id"]]
        unless customer
          @skipped[:orders_without_customer] += 1
          next
        end
        user_id, address_id = customer

        oid += 1
        olist_id = r["order_id"]
        @order_ids[olist_id] = oid

        status = r["order_status"]
        state = STATE_MAP.fetch(status, "complete")
        purchased = ts(r["order_purchase_timestamp"])
        delivered = ts(r["order_delivered_customer_date"])
        estimated = ts(r["order_estimated_delivery_date"])
        approved = ts(r["order_approved_at"])

        orders << {
          id: oid,
          number: format("OL%09d", oid),
          user_id: user_id,
          email: "#{r['customer_id']}@olist.invalid",
          bill_address_id: address_id,
          ship_address_id: address_id,
          state: state,
          currency: CURRENCY,
          store_id: store.id,
          channel_id: @channel_id,
          completed_at: (state == "complete" ? (approved || purchased) : nil),
          canceled_at: (state == "canceled" ? purchased : nil),
          created_at: purchased || now,
          updated_at: delivered || approved || purchased || now
        }

        details << {
          spree_order_id: oid,
          olist_order_id: olist_id,
          olist_customer_id: r["customer_id"],
          olist_customer_unique_id: customer_unique_for(r["customer_id"]),
          olist_status: status,
          purchased_at: purchased,
          approved_at: approved,
          delivered_to_carrier_at: ts(r["order_delivered_carrier_date"]),
          delivered_to_customer_at: delivered,
          estimated_delivery_at: estimated,
          delivery_days: day_diff(purchased, delivered),
          days_late: day_diff(estimated, delivered),
          created_at: now, updated_at: now
        }

        if orders.size >= BATCH
          flush(Spree::Order, orders)
          flush(OlistOrderDetail, details)
        end
      end

      flush(Spree::Order, orders)
      flush(OlistOrderDetail, details)
      record(:orders, oid)
    end

    # We only kept customer_id -> [user_id, address_id]; recover the unique id
    # from the user row we created for it.
    def customer_unique_for(customer_id)
      @customer_unique_ids ||= @user_ids.invert
      user_id = @address_ids[customer_id]&.first
      @customer_unique_ids[user_id]
    end

    def day_diff(from, to)
      return nil if from.nil? || to.nil?

      ((to - from) / 86_400.0).round
    end

    # --- line items --------------------------------------------------------

    # One Spree line item per Olist order_items row, quantity 1. Olist models
    # "two of the same product" as two rows with different order_item_id and
    # its own freight on each, so collapsing them into quantity: 2 would throw
    # away per-row freight. Faithful beats tidy here.
    def import_line_items
      items, details = [], []
      lid = 0

      CSV.foreach(path("olist_order_items_dataset"), headers: true) do |r|
        order_id = @order_ids[r["order_id"]]
        next unless order_id # filtered out by :limit, or absent order

        product = @product_ids[r["product_id"]]
        unless product
          @skipped[:line_items_without_product] += 1
          next
        end

        seller_id = @seller_ids[r["seller_id"]]
        unless seller_id
          @skipped[:line_items_without_seller] += 1
          next
        end

        lid += 1
        items << {
          id: lid,
          order_id: order_id,
          variant_id: product[1],
          quantity: 1,
          price: r["price"],
          currency: CURRENCY,
          created_at: now, updated_at: now
        }

        details << {
          spree_line_item_id: lid,
          olist_seller_id: seller_id,
          freight_value: r["freight_value"] || 0,
          shipping_limit_at: ts(r["shipping_limit_date"]),
          created_at: now, updated_at: now
        }

        if items.size >= BATCH
          flush(Spree::LineItem, items)
          flush(OlistLineItemDetail, details)
        end
      end

      flush(Spree::LineItem, items)
      flush(OlistLineItemDetail, details)
      record(:line_items, lid)
    end

    # --- payments ----------------------------------------------------------

    def import_payments
      payments, details = [], []
      pid = 0

      CSV.foreach(path("olist_order_payments_dataset"), headers: true) do |r|
        order_id = @order_ids[r["order_id"]]
        next unless order_id

        pid += 1
        payments << {
          id: pid,
          order_id: order_id,
          amount: r["payment_value"],
          payment_method_id: @payment_method_id,
          state: "completed",
          number: format("P%09d", pid),
          # NB: not response_code. Spree has a unique index on
          # (order_id, payment_method_id, response_code) and Olist orders
          # routinely carry several payments of the same type — the type
          # lives on OlistPaymentDetail instead.
          created_at: now, updated_at: now
        }

        details << {
          spree_payment_id: pid,
          payment_type: r["payment_type"],
          installments: r["payment_installments"].to_i,
          created_at: now, updated_at: now
        }

        if payments.size >= BATCH
          flush(Spree::Payment, payments)
          flush(OlistPaymentDetail, details)
        end
      end

      flush(Spree::Payment, payments)
      flush(OlistPaymentDetail, details)
      record(:payments, pid)
    end

    # --- reviews -----------------------------------------------------------

    def import_reviews
      reviews = []
      count = 0

      # Review comments contain embedded newlines and commas, so this must go
      # through a real CSV parser — splitting on \n silently mangles ~6k rows.
      CSV.foreach(path("olist_order_reviews_dataset"), headers: true) do |r|
        order_id = @order_ids[r["order_id"]]
        next unless order_id

        count += 1
        reviews << {
          spree_order_id: order_id,
          olist_review_id: r["review_id"],
          score: r["review_score"].to_i,
          title: r["review_comment_title"],
          message: r["review_comment_message"],
          reviewed_at: ts(r["review_creation_date"]),
          answered_at: ts(r["review_answer_timestamp"]),
          created_at: now, updated_at: now
        }

        flush(OlistReview, reviews) if reviews.size >= BATCH
      end

      flush(OlistReview, reviews)
      record(:reviews, count)
    end

    # --- derived columns ---------------------------------------------------

    # Everything Spree's callbacks would normally maintain. Doing it in one
    # SQL pass per column is the whole reason the import finishes in minutes.
    def backfill_derived_columns
      log "Backfilling derived columns"
      exec <<~SQL, "line item timestamps"
        UPDATE spree_line_items li
           SET created_at = o.created_at, updated_at = o.created_at
          FROM spree_orders o
         WHERE li.order_id = o.id
      SQL

      exec <<~SQL, "order item totals"
        UPDATE spree_orders o
           SET item_total = t.item_total,
               item_count = t.item_count
          FROM (
            SELECT order_id,
                   SUM(price * quantity) AS item_total,
                   SUM(quantity)         AS item_count
              FROM spree_line_items GROUP BY order_id
          ) t
         WHERE o.id = t.order_id
      SQL

      exec <<~SQL, "order shipment totals (freight)"
        UPDATE spree_orders o
           SET shipment_total = t.freight
          FROM (
            SELECT li.order_id, SUM(d.freight_value) AS freight
              FROM spree_line_items li
              JOIN olist_line_item_details d ON d.spree_line_item_id = li.id
             GROUP BY li.order_id
          ) t
         WHERE o.id = t.order_id
      SQL

      exec <<~SQL, "order payment totals"
        UPDATE spree_orders o
           SET payment_total = t.paid
          FROM (
            SELECT order_id, SUM(amount) AS paid
              FROM spree_payments GROUP BY order_id
          ) t
         WHERE o.id = t.order_id
      SQL

      exec <<~SQL, "order grand totals"
        UPDATE spree_orders
           SET total = item_total + shipment_total,
               payment_state = CASE
                 WHEN payment_total >= item_total + shipment_total AND payment_total > 0 THEN 'paid'
                 WHEN payment_total > 0 THEN 'balance_due'
                 ELSE NULL END,
               shipment_state = CASE WHEN state = 'complete' THEN 'shipped' ELSE NULL END
      SQL

      exec <<~SQL, "product sales counters"
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

      exec <<~SQL, "taxon product counts"
        UPDATE spree_taxons tx
           SET products_count = t.cnt
          FROM (
            SELECT taxon_id, COUNT(*) AS cnt FROM spree_products_taxons GROUP BY taxon_id
          ) t
         WHERE tx.id = t.taxon_id
      SQL
    end

    def exec(sql, label)
      started = Time.now
      result = ActiveRecord::Base.connection.execute(sql)
      log format("  %-34s %6.1fs", label, Time.now - started)
      result
    end

    def reset_sequences!
      %w[
        spree_products spree_variants spree_prices spree_orders spree_line_items
        spree_payments spree_users spree_addresses spree_taxons spree_taxonomies
        spree_stock_items spree_products_taxons spree_products_stores
        olist_sellers olist_order_details olist_reviews
        olist_line_item_details olist_payment_details
      ].each do |table|
        ActiveRecord::Base.connection.reset_pk_sequence!(table)
      end
      log "Primary key sequences reset"
    end

    # --- plumbing ----------------------------------------------------------

    # insert_all! and not insert_all: the non-bang form compiles to
    # ON CONFLICT DO NOTHING, so a row that trips a unique index vanishes
    # without an error and the import quietly under-reports. In an importer,
    # a loud failure is worth far more than a complete-looking result.
    def flush(model, rows)
      return if rows.empty?

      model.insert_all!(rows, record_timestamps: false)
      rows.clear
    end

    def record(key, count)
      @stats[key] = count
      log format("  %-14s %8d", key, count)
    end

    def report_skips
      return if @skipped.empty?

      log ""
      log "Skipped rows:"
      @skipped.each { |reason, count| log format("  %-32s %6d", reason, count) }
    end
  end
end
