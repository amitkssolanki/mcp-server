# frozen_string_literal: true

# OAuth discovery documents an MCP client needs before it can talk to this
# server at all — see McpController for the 401 that points clients here in
# the first place.
#
# Every URL below is built from request.base_url rather than a fixed config
# value, on purpose: this app is reached through different hosts depending on
# context (localhost in dev, an ngrok tunnel for testing, a real domain once
# deployed), and the metadata must describe whichever host the client is
# actually talking to right now, not a guess baked in at boot time.
class WellKnownController < ActionController::API
  # RFC 9728 — OAuth 2.0 Protected Resource Metadata.
  # Tells a client, given the MCP endpoint, which authorization server(s)
  # issue tokens accepted here.
  def protected_resource
    render json: {
      resource: "#{request.base_url}/mcp",
      authorization_servers: [request.base_url],
      bearer_methods_supported: ["header"],
      scopes_supported: %w[mcp:read mcp:write]
    }
  end

  # RFC 8414 — OAuth 2.0 Authorization Server Metadata.
  # Tells a client where to send a resource owner for consent, where to
  # exchange a code for a token, and — via registration_endpoint — where to
  # dynamically register itself (RFC 7591) rather than needing a client_id
  # handed to it out of band.
  def authorization_server
    render json: {
      issuer: request.base_url,
      authorization_endpoint: "#{request.base_url}/oauth/authorize",
      token_endpoint: "#{request.base_url}/oauth/token",
      registration_endpoint: "#{request.base_url}/register",
      revocation_endpoint: "#{request.base_url}/oauth/revoke",
      introspection_endpoint: "#{request.base_url}/oauth/introspect",
      scopes_supported: %w[mcp:read mcp:write],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      # Doorkeeper also accepts the PKCE "plain" method; only S256 is
      # advertised here since OAuth 2.1 discourages "plain" and every client
      # we expect (Claude included) supports S256 natively.
      code_challenge_methods_supported: ["S256"],
      # "none" first and deliberately: DCR-registered clients (the expected
      # common case here) get no client_secret and authenticate via PKCE
      # alone. Doorkeeper also accepts a manually pre-registered confidential
      # client via either of the other two.
      token_endpoint_auth_methods_supported: %w[none client_secret_basic client_secret_post]
    }
  end
end
