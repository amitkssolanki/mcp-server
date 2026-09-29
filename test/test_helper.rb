# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require Rails.root.join("eval/harness").to_s

# Not parallelized. Parallel tests each get a copy of the test database, and
# this one holds the full 100k-order Olist import that the boundary and
# harness tests run against.
class ActiveSupport::TestCase
  MINI_OLIST = Rails.root.join("test/fixtures/olist_mini").to_s

  # The hand-built dataset in test/fixtures/olist_mini, small enough that every
  # expected value in the oracle tests is worked out by hand in the test.
  def mini_truth
    @mini_truth ||= Eval::Oracle::Truth.new(Eval::Oracle::Dataset.load(MINI_OLIST))
  end
end
