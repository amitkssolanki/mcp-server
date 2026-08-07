# frozen_string_literal: true

# Streamable HTTP transport — the remote half of the server.
#
# Stateless mode is the right default for a Rails app: no session state to keep
# between requests, so this scales across processes without sticky routing.
class McpController < ActionController::API
  def handle
    store = resolve_store
    return render(json: { error: "unknown store" }, status: :not_found) if store.nil?

    server = StoreMcp.server(store: store, read_only: read_only?)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      # Loopback hosts are allowed by default; add real hostnames here before
      # this is reachable from anywhere but localhost.
      allowed_origins: Array(ENV["MCP_ALLOWED_ORIGINS"]&.split(",")),
      allowed_hosts: Array(ENV["MCP_ALLOWED_HOSTS"]&.split(","))
    )

    status, headers, body = transport.handle_request(request)
    headers.each { |key, value| response.set_header(key, value) }
    render(json: body.first, status: status)
  end

  private

  # Placeholder for real auth. A production deployment terminates OAuth here and
  # derives the store from the verified token — never from a client-supplied
  # header, which is exactly how a tenant reads another tenant's orders.
  def resolve_store
    return StoreMcp.default_store if ENV["MCP_STORE_CODE"].blank?

    Spree::Store.find_by(code: ENV["MCP_STORE_CODE"])
  end

  def read_only?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("MCP_READ_ONLY", "false"))
  end
end
