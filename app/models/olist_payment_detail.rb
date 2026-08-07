# frozen_string_literal: true

class OlistPaymentDetail < ApplicationRecord
  belongs_to :spree_payment, class_name: "Spree::Payment"

  scope :installment_plans, -> { where(installments: 2..) }
end
