# frozen_string_literal: true

class OlistLineItemDetail < ApplicationRecord
  belongs_to :spree_line_item, class_name: "Spree::LineItem"
  belongs_to :olist_seller
end
