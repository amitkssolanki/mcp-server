# frozen_string_literal: true

# Streamable HTTP transport — the remote half of the server, now sitting
# behind real OAuth 2.1 (Doorkeeper) rather than the MCP_READ_ONLY env var
# this used to read. Every request must carry a Doorkeeper-issued Bearer
# token; which MCP tools it can see is derived from that token's granted
# scopes (mcp:read / mcp:write), not from how the process happened to be
# launched — so read vs. write access is a property of who the admin
# actually authorized, not a deploy-time flag anyone could forget.
class McpController < ActionController::API
  before_action :authenticate_mcp_client!

  def handle
    store = resolve_store
    return render(json: { error: "unknown store" }, status: :not_found) if store.nil?

    server = StoreMcp.server(store: store, read_only: !write_scope_granted?)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      # Loopback hosts are allowed by default; set these once this is
      # reachable from anywhere but localhost/a throwaway tunnel.
      allowed_origins: Array(ENV["MCP_ALLOWED_ORIGINS"]&.split(",")),
      allowed_hosts: Array(ENV["MCP_ALLOWED_HOSTS"]&.split(","))
    )

    status, headers, body = transport.handle_request(request)
    headers.each { |key, value| response.set_header(key, value) }
    render(json: body.first, status: status)
  end

  private

  # RFC 6750 (Bearer Token Usage) says a 401 for a missing/invalid token
  # carries a WWW-Authenticate: Bearer challenge; RFC 9728 extends that
  # challenge with a resource_metadata parameter pointing at the protected
  # resource metadata document, which is how a client that shows up with no
  # token at all discovers where to go to get one. Both belong on the same
  # header, so this is hand-rolled rather than routed through Doorkeeper's
  # own error renderer, which only knows about the first part.
  def authenticate_mcp_client!
    return if doorkeeper_token&.acceptable?(["mcp:read"])

    response.set_header(
      "WWW-Authenticate",
      %(Bearer error="invalid_token", resource_metadata="#{request.base_url}/.well-known/oauth-protected-resource")
    )
    render(
      json: {
        error: "invalid_token",
        error_description: "A valid access token with the mcp:read scope is required."
      },
      status: :unauthorized
    )
  end

  def write_scope_granted?
    doorkeeper_token.includes_scope?("mcp:write")
  end

  # Placeholder for real multi-tenancy. A deployment serving more than one
  # store would derive this from the token/client rather than an env var —
  # this app only has one store, so an env var is enough for now.
  def resolve_store
    return StoreMcp.default_store if ENV["MCP_STORE_CODE"].blank?

    Spree::Store.find_by(code: ENV["MCP_STORE_CODE"])
  end
end
