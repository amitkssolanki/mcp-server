# frozen_string_literal: true

# Overrides spree_core's Spree::LegacyUser (a bcrypt placeholder) with a real
# Devise-backed model — required once config/routes.rb calls `devise_for` on
# it (via the spree:storefront:devise generator), since Devise introspects
# the model's own `devise(...)` modules when building the mapping. See
# app/models/spree/legacy_admin_user.rb for the fuller explanation; same
# reasoning applies here. spree_users already has every column these modules
# need — no new migration.
module Spree
  class LegacyUser < Spree.base_class
    # :registerable is required — spree:storefront:devise wires a
    # `registrations` controller and the storefront theme's header calls
    # spree_signup_path (-> new_registration_path) on every page. Devise
    # only generates a model's registration routes when the model itself
    # declares :registerable, so without it every themed storefront page
    # 500s, not just the signup page. Needs no extra columns beyond what
    # :database_authenticatable already uses (email + encrypted_password).
    devise :database_authenticatable, :registerable, :recoverable, :rememberable, :trackable, :lockable

    include Spree::UserAddress
    include Spree::UserPaymentSource
    include Spree::UserMethods

    self.table_name = "spree_users"
  end
end
