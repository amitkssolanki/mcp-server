# frozen_string_literal: true

require "csv"
require "bigdecimal"

module Eval
  module Oracle
    # The raw Olist CSVs, loaded into plain Ruby objects. This file and the
    # oracle next to it are the harness's independent path to the truth, so the
    # rules are strict:
    #
    # - Read the CSVs directly. No Spree model, no ActiveRecord, no SQL, and
    #   nothing from lib/olist/importer.rb.
    # - Keep money as BigDecimal from the source string. Never go through Float.
    # - Parse timestamps with our own code rather than the importer's #ts.
    #
    # What *is* shared with the importer is the input files and the business
    # definitions in docs/METRICS.md. Sharing definitions is unavoidable, since
    # both sides have to agree on what "revenue" means before they can be
    # compared. Sharing code is not.
    class Dataset
      FILES = {
        orders:       "olist_orders_dataset",
        items:        "olist_order_items_dataset",
        products:     "olist_products_dataset",
        customers:    "olist_customers_dataset",
        sellers:      "olist_sellers_dataset",
        payments:     "olist_order_payments_dataset",
        reviews:      "olist_order_reviews_dataset",
        translations: "product_category_name_translation"
      }.freeze

      Order    = Struct.new(:id, :customer_id, :status, :purchased_at, :delivered_at, :estimated_at, keyword_init: true)
      Item     = Struct.new(:order_id, :seq, :product_id, :seller_id, :price, :freight, keyword_init: true)
      Product  = Struct.new(:id, :category_pt, keyword_init: true)
      Customer = Struct.new(:id, :unique_id, :city, :state, keyword_init: true)
      Seller   = Struct.new(:id, :city, :state, keyword_init: true)
      Payment  = Struct.new(:order_id, :seq, :type, :installments, :value, keyword_init: true)
      Review   = Struct.new(:id, :order_id, :score, :created_at, :answered_at, keyword_init: true)

      attr_reader :dir, :orders, :items, :products, :customers, :sellers, :payments, :reviews, :translations

      def self.load(dir)
        new(dir).tap(&:load!)
      end

      def initialize(dir)
        @dir = Pathname.new(dir.to_s)
      end

      def load!
        missing = FILES.values.reject { |name| path(name).exist? }
        raise ArgumentError, "Olist CSVs missing from #{dir}: #{missing.join(', ')}" if missing.any?

        @orders = rows(:orders).map do |r|
          Order.new(id: r["order_id"], customer_id: r["customer_id"], status: r["order_status"],
                    purchased_at: r["order_purchase_timestamp"].presence,
                    delivered_at: r["order_delivered_customer_date"].presence,
                    estimated_at: r["order_estimated_delivery_date"].presence)
        end
        @items = rows(:items).map do |r|
          Item.new(order_id: r["order_id"], seq: r["order_item_id"].to_i, product_id: r["product_id"],
                   seller_id: r["seller_id"], price: money(r["price"]), freight: money(r["freight_value"]))
        end
        @products = rows(:products).to_h do |r|
          [r["product_id"], Product.new(id: r["product_id"], category_pt: r["product_category_name"].presence)]
        end
        @customers = rows(:customers).to_h do |r|
          [r["customer_id"], Customer.new(id: r["customer_id"], unique_id: r["customer_unique_id"],
                                          city: r["customer_city"], state: r["customer_state"])]
        end
        @sellers = rows(:sellers).to_h do |r|
          [r["seller_id"], Seller.new(id: r["seller_id"], city: r["seller_city"], state: r["seller_state"])]
        end
        @payments = rows(:payments).map do |r|
          Payment.new(order_id: r["order_id"], seq: r["payment_sequential"].to_i, type: r["payment_type"],
                      installments: r["payment_installments"].to_i, value: money(r["payment_value"]))
        end
        @reviews = rows(:reviews).map do |r|
          Review.new(id: r["review_id"], order_id: r["order_id"], score: Integer(r["review_score"]),
                     created_at: r["review_creation_date"].presence, answered_at: r["review_answer_timestamp"].presence)
        end
        @translations = rows(:translations, encoding: "bom|utf-8").to_h do |r|
          [r["product_category_name"], r["product_category_name_english"]]
        end
        self
      end

      # Raw file row counts, for reconciling against what the import produced.
      def counts
        { orders: orders.size, items: items.size, products: products.size, customers: customers.size,
          sellers: sellers.size, payments: payments.size, reviews: reviews.size }
      end

      private

      def path(name) = dir.join("#{name}.csv")

      def rows(key, encoding: "utf-8")
        CSV.read(path(FILES.fetch(key)), headers: true, encoding: encoding)
      end

      def money(value)
        BigDecimal(value.presence || "0")
      end
    end
  end
end
