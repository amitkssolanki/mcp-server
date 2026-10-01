# The Spree storefront is the data the MCP tools query, not a shop. A banner at the top of every
# storefront page says so (with the dataset attribution) and links back to the demo's homepage; the
# shop controls are hidden by app/assets/stylesheets/storefront_demo.css. Nothing here touches store data.
#
# spree_storefront resets its partial lists in its own after_initialize, so this runs after it.
Rails.application.config.after_initialize do
  partials = Rails.application.config.spree_storefront.body_start_partials
  partials << "spree/shared/demo_banner" unless partials.include?("spree/shared/demo_banner")
end
