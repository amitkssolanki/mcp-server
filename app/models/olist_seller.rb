# frozen_string_literal: true

class OlistSeller < ApplicationRecord
  has_many :line_item_details, class_name: "OlistLineItemDetail", dependent: :destroy
  has_many :line_items, through: :line_item_details, source: :spree_line_item

  validates :olist_seller_id, presence: true, uniqueness: true
end
