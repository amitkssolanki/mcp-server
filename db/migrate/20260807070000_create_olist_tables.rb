# frozen_string_literal: true

# Companion tables for Olist data that Spree core has no home for.
#
# The rule: anything Spree already models (orders, line items, products,
# users, addresses, payments) goes into Spree's own tables. Everything
# Olist-specific hangs off those records 1:1 here, so Spree stays pristine
# and upgrades don't fight us.
class CreateOlistTables < ActiveRecord::Migration[8.1]
  def change
    create_table :olist_sellers do |t|
      t.string :olist_seller_id, null: false
      t.string :zip_code_prefix
      t.string :city
      t.string :state
      t.timestamps
    end
    add_index :olist_sellers, :olist_seller_id, unique: true
    add_index :olist_sellers, :state

    # The delivery timeline — the reason this dataset is worth importing.
    create_table :olist_order_details do |t|
      t.references :spree_order, null: false, foreign_key: { to_table: :spree_orders }, index: { unique: true }
      t.string :olist_order_id, null: false
      t.string :olist_customer_id, null: false
      t.string :olist_customer_unique_id, null: false
      t.string :olist_status, null: false
      t.datetime :purchased_at
      t.datetime :approved_at
      t.datetime :delivered_to_carrier_at
      t.datetime :delivered_to_customer_at
      t.datetime :estimated_delivery_at
      # Denormalised so "late deliveries" is an indexed query, not a scan.
      t.integer :delivery_days
      t.integer :days_late
      t.timestamps
    end
    add_index :olist_order_details, :olist_order_id, unique: true
    add_index :olist_order_details, :olist_customer_unique_id
    add_index :olist_order_details, :olist_status
    add_index :olist_order_details, :purchased_at
    add_index :olist_order_details, :days_late

    create_table :olist_reviews do |t|
      t.references :spree_order, null: false, foreign_key: { to_table: :spree_orders }
      t.string :olist_review_id, null: false
      t.integer :score, null: false
      t.string :title
      t.text :message
      t.datetime :reviewed_at
      t.datetime :answered_at
      t.timestamps
    end
    add_index :olist_reviews, :olist_review_id
    add_index :olist_reviews, :score

    create_table :olist_line_item_details do |t|
      t.references :spree_line_item, null: false, foreign_key: { to_table: :spree_line_items }, index: { unique: true }
      t.references :olist_seller, null: false, foreign_key: true
      t.decimal :freight_value, precision: 10, scale: 2, default: '0.0', null: false
      t.datetime :shipping_limit_at
      t.timestamps
    end

    create_table :olist_payment_details do |t|
      t.references :spree_payment, null: false, foreign_key: { to_table: :spree_payments }, index: { unique: true }
      t.string :payment_type, null: false
      t.integer :installments, default: 0, null: false
      t.timestamps
    end
    add_index :olist_payment_details, :payment_type
  end
end
