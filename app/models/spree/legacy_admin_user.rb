# frozen_string_literal: true

# Overrides spree_core's Spree::LegacyAdminUser (a bcrypt placeholder its own
# source explicitly marks "for testing purposes") with a real Devise-backed
# model, so the /admin login form actually works. This file lives under
# app/models, which Rails autoloads ahead of the gem's copy under the same
# constant name — that's the standard Spree override mechanism, not a monkeypatch.
#
# Every Devise module below is backed by a column spree_admin_users already
# has (see db/migrate/20210913000000_create_spree_admin_users.rb): no new
# migration needed. :confirmable is deliberately omitted — that table has no
# confirmed_at/confirmation_token columns.
module Spree
  class LegacyAdminUser < Spree.base_class
    devise :database_authenticatable, :recoverable, :rememberable, :trackable, :lockable

    include Spree::AdminUserMethods

    self.table_name = "spree_admin_users"
  end
end
