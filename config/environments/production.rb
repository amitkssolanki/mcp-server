require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  #
  # RAILS_HOST is the one place the deployed hostname is configured (set in
  # config/deploy.yml); everything below derives from it. Spree generates
  # absolute URLs in order confirmations and in the OAuth consent screen's
  # redirect, so this has to be the real host, not a placeholder.
  config.action_mailer.default_url_options = { host: ENV.fetch("RAILS_HOST", "example.com"), protocol: "https" }
  routes.default_url_options = { host: ENV.fetch("RAILS_HOST", "example.com"), protocol: "https" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  #
  # Rails only installs the host-authorization middleware when config.hosts is
  # non-empty, so leaving this unset — the generated default — means no Host
  # check at all in production. The README lists that as something a real
  # deployment has to fix, and this is the fix. Note it is NOT the same check
  # as the MCP SDK's: MCP_ALLOWED_HOSTS guards the /mcp transport separately,
  # and one without the other leaves a hole.
  if ENV["RAILS_HOST"].present?
    config.hosts << ENV["RAILS_HOST"]

    # kamal-proxy health-checks the container directly rather than through the
    # public hostname, so /up arrives with a Host header that is not
    # RAILS_HOST. Without this exclusion every health check 403s and the
    # deploy never goes green.
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end

  # Demo content: 32k products with names synthesized from a category and an
  # ID fragment, over anonymised 2016-2018 Brazilian order history. None of it
  # should turn up in search results under amitsolanki.com. robots.txt asks
  # crawlers not to fetch; X-Robots-Tag tells the ones that fetch anyway not to
  # index. Set DEMO_NOINDEX=false if this ever fronts a real catalogue.
  if ENV.fetch("DEMO_NOINDEX", "true") != "false"
    config.action_dispatch.default_headers =
      config.action_dispatch.default_headers.merge("X-Robots-Tag" => "noindex, nofollow")
  end
end
