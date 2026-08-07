# frozen_string_literal: true

class OlistReview < ApplicationRecord
  belongs_to :spree_order, class_name: "Spree::Order"

  validates :score, inclusion: { in: 1..5 }

  scope :negative, -> { where(score: 1..2) }
  scope :positive, -> { where(score: 4..5) }
  scope :with_comment, -> { where.not(message: [nil, ""]) }
end
