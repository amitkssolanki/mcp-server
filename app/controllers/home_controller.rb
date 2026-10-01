# The demo's homepage: a static page about the project. Not a Spree controller and not part of the
# storefront, so it carries none of the shop's layout, session or cart behaviour.
class HomeController < ActionController::Base
  layout "home"

  def show
    expires_in 10.minutes, public: true
  end
end
