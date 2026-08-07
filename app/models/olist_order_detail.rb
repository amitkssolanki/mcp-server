# frozen_string_literal: true

class OlistOrderDetail < ApplicationRecord
  belongs_to :spree_order, class_name: "Spree::Order"

  # Both hang off the same Spree order, so join on that rather than on our id.
  has_one :review,
          class_name: "OlistReview",
          primary_key: :spree_order_id,
          foreign_key: :spree_order_id,
          inverse_of: false,
          dependent: nil

  scope :delivered, -> { where(olist_status: "delivered") }
  scope :late, -> { where(days_late: 1..) }
  scope :on_time, -> { where(days_late: ..0) }
  scope :purchased_between, ->(from, to) { where(purchased_at: from..to) }
end
