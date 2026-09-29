# frozen_string_literal: true

require "test_helper"

# The trust boundary of the remote MCP endpoint, tested through the real
# stack: Rack, the controller, Doorkeeper token lookup, the MCP SDK's
# streamable-HTTP transport and its host checks. Tokens are real Doorkeeper
# records. Nothing here stubs the check it is testing.
#
# Each test pins a claim the README makes about the deployment.
class McpBoundaryTest < ActionDispatch::IntegrationTest
  READ_TOOLS = %w[delivery_performance find_customer get_order get_product list_categories
                  revenue_report search_orders search_products seller_performance].freeze
  WRITE_TOOLS = %w[update_order_status update_product_price].freeze

  setup do
    host! "localhost"
    @app = Doorkeeper::Application.create!(name: "boundary test", redirect_uri: "https://claude.ai/api/mcp/auth_callback",
                                           confidential: false)
  end

  # --- no credentials -------------------------------------------------------

  test "a request without a token is refused with a challenge that points at the resource metadata" do
    rpc("tools/list")

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    assert_match(/\ABearer /, challenge)
    assert_includes challenge, %(resource_metadata="http://localhost/.well-known/oauth-protected-resource")
    assert_equal "invalid_token", response.parsed_body["error"]
  end

  test "an unknown, expired or revoked token is refused the same way" do
    rpc("tools/list", token: "not-a-real-token")
    assert_response :unauthorized

    expired = token("mcp:read", expires_in: 60, created_at: 2.hours.ago)
    rpc("tools/list", token: expired.token)
    assert_response :unauthorized

    revoked = token("mcp:read").tap(&:revoke)
    rpc("tools/list", token: revoked.token)
    assert_response :unauthorized
  end

  test "a token without mcp:read is refused even if it carries mcp:write" do
    rpc("tools/list", token: token("mcp:write").token)
    assert_response :unauthorized
  end

  # --- read access ----------------------------------------------------------

  test "a read token sees exactly the nine read tools" do
    rpc("tools/list", token: token("mcp:read").token)

    assert_response :success
    assert_equal READ_TOOLS, tool_names
  end

  test "a read token can call a read tool and gets structured content back" do
    rpc("tools/call", { name: "search_orders", arguments: { limit: 1 } }, token: token("mcp:read").token)

    assert_response :success
    refute result["isError"]
    assert_kind_of Integer, result.dig("structuredContent", "total_matches")
  end

  test "a read token cannot call a write tool it was never shown" do
    product_id = Spree::Product.order(:id).pick(:id)
    before = Spree::Product.find(product_id).master.price_in("BRL").amount

    rpc("tools/call", { name: "update_product_price", arguments: { product_id: product_id, price: 1, confirm: true } },
        token: token("mcp:read").token)

    assert_tool_not_found "update_product_price"
    assert_equal before, Spree::Product.find(product_id).master.price_in("BRL").amount
  end

  # --- write scope ------------------------------------------------------------

  test "a write-scoped token sees the write tools when the deployment allows writes" do
    with_env("MCP_ALLOW_WRITE_SCOPE" => "true") do
      rpc("tools/list", token: token("mcp:read mcp:write").token)
      assert_equal (READ_TOOLS + WRITE_TOOLS).sort, tool_names
    end
  end

  # The deployed configuration. Doorkeeper checks scopes when it issues a
  # token, not when the token comes back, so a write token minted before the
  # flag was turned off still carries mcp:write. This is the request-time half
  # that stops it.
  test "with writes disabled, a token that still carries mcp:write gets read tools only and cannot write" do
    with_env("MCP_ALLOW_WRITE_SCOPE" => "false") do
      write_token = token("mcp:read mcp:write").token

      rpc("tools/list", token: write_token)
      assert_equal READ_TOOLS, tool_names

      rpc("tools/call", { name: "update_order_status",
                          arguments: { order_number: "OL000000001", status: "canceled", confirm: true } },
          token: write_token)
      assert_tool_not_found "update_order_status"
      assert_equal "complete", Spree::Order.find_by!(number: "OL000000001").state
    end
  end

  # --- discovery ----------------------------------------------------------------

  test "protected resource metadata names this server as the resource and its authorization server" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    body = response.parsed_body
    assert_equal "http://localhost/mcp", body["resource"]
    assert_equal ["http://localhost"], body["authorization_servers"]
    assert_equal Doorkeeper.config.scopes.map(&:to_s), body["scopes_supported"]
  end

  test "authorization server metadata advertises PKCE S256 only, the code flow, and dynamic registration" do
    get "/.well-known/oauth-authorization-server"

    body = response.parsed_body
    assert_equal "http://localhost", body["issuer"]
    assert_equal ["S256"], body["code_challenge_methods_supported"]
    assert_equal ["authorization_code"], body["grant_types_supported"]
    assert_equal "http://localhost/register", body["registration_endpoint"]
    assert_equal Doorkeeper.config.scopes.map(&:to_s), body["scopes_supported"]
  end

  test "a dynamically registered public client gets a client id and no secret" do
    post "/register", params: { client_name: "probe", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
                                token_endpoint_auth_method: "none" }, as: :json

    assert_response :created
    assert response.parsed_body["client_id"].present?
    assert_nil response.parsed_body["client_secret"]
    assert_equal "none", response.parsed_body["token_endpoint_auth_method"]
  end

  # F14: native clients (Claude Code) receive the code on a loopback port.
  test "a native client can register a loopback http redirect; any other http redirect is refused" do
    %w[http://localhost:52713/callback http://127.0.0.1:52713/callback http://[::1]:52713/callback].each do |uri|
      post "/register", params: { client_name: "cli", redirect_uris: [uri], token_endpoint_auth_method: "none" }, as: :json
      assert_response :created, uri
    end

    %w[http://example.com/callback http://localhost.example.com/callback].each do |uri|
      post "/register", params: { client_name: "web", redirect_uris: [uri], token_endpoint_auth_method: "none" }, as: :json
      assert_response :bad_request, uri
      assert_equal "invalid_client_metadata", response.parsed_body["error"]
    end
  end

  test "a loopback client still needs the admin's consent before any code is issued" do
    post "/register", params: { client_name: "cli", redirect_uris: ["http://localhost:52713/callback"],
                                token_endpoint_auth_method: "none" }, as: :json
    client = Doorkeeper::Application.find_by!(uid: response.parsed_body["client_id"])

    get "/oauth/authorize", params: { client_id: client.uid, redirect_uri: "http://localhost:52713/callback",
                                      response_type: "code", scope: "mcp:read",
                                      code_challenge: "x" * 43, code_challenge_method: "S256" }
    assert_response :redirect
    assert_match %r{/admin_user/sign_in\z}, response.location
    assert_empty Doorkeeper::AccessGrant.where(application: client)
  end

  test "registering a client grants nothing: it holds no token until an admin approves" do
    post "/register", params: { client_name: "probe", redirect_uris: ["https://example.com/cb"],
                                token_endpoint_auth_method: "none" }, as: :json
    client = Doorkeeper::Application.find_by!(uid: response.parsed_body["client_id"])

    assert_empty Doorkeeper::AccessToken.where(application: client)
    get "/oauth/authorize", params: { client_id: client.uid, redirect_uri: "https://example.com/cb",
                                      response_type: "code", scope: "mcp:read",
                                      code_challenge: "x" * 43, code_challenge_method: "S256" }
    assert_response :redirect
    assert_match %r{/admin_user/sign_in\z}, response.location, "consent requires the store admin to sign in"
  end

  test "the Doorkeeper applications admin is closed" do
    get "/oauth/applications"
    assert_response :forbidden
  end

  # --- host checks ------------------------------------------------------------

  # The MCP SDK has its own DNS-rebinding protection, separate from Rails'
  # config.hosts. An unlisted Host is refused even with a valid token.
  test "the MCP transport refuses a host that is not allowed, even with a valid token" do
    host! "attacker.example"
    rpc("tools/list", token: token("mcp:read").token)

    assert_response :forbidden
  end

  # --- protocol revision (F12) ------------------------------------------------

  # mcp 1.1.0 would agree to 2026-07-28 without implementing it, and a client
  # holding it to that revision rejects tools/list and sees zero tools.
  test "a client asking for 2026-07-28 is negotiated down to 2025-11-25, the newest revision implemented" do
    rpc("initialize", { protocolVersion: "2026-07-28", capabilities: {}, clientInfo: { name: "probe", version: "1" } },
        token: token("mcp:read").token)

    assert_response :success
    assert_equal "2025-11-25", result["protocolVersion"]
  end

  test "a client asking for an older revision the server implements gets that revision" do
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "probe", version: "1" } },
        token: token("mcp:read").token)

    assert_equal "2025-06-18", result["protocolVersion"]
  end

  test "sessionless discovery does not advertise 2026-07-28" do
    rpc("server/discover", {}, token: token("mcp:read").token)

    versions = result.fetch("supportedVersions")
    assert_equal "2025-11-25", versions.max
    refute_includes versions, "2026-07-28"
  end

  # --- store scoping ----------------------------------------------------------

  test "a server bound to another store sees none of this store's orders" do
    other = Spree::Store.create!(name: "Other", code: "other", url: "other.localhost",
                                 mail_from_address: "other@example.com", default_currency: "BRL",
                                 supported_currencies: "BRL", default_country: Spree::Country.find_by(iso: "BR"))
    with_env("MCP_STORE_CODE" => other.code) do
      read = token("mcp:read").token

      rpc("tools/call", { name: "search_orders", arguments: {} }, token: read)
      assert_equal 0, result.dig("structuredContent", "total_matches")

      rpc("tools/call", { name: "get_order", arguments: { order_number: "OL000000001" } }, token: read)
      assert result["isError"], "an order number from another store must not resolve"
    end
  end

  test "an unknown store code is a 404, not a fallback to the default store" do
    with_env("MCP_STORE_CODE" => "no-such-store") do
      rpc("tools/list", token: token("mcp:read").token)
      assert_response :not_found
    end
  end

  private

  def token(scopes, expires_in: 3600, created_at: Time.current)
    Doorkeeper::AccessToken.create!(application: @app, scopes: scopes, expires_in: expires_in, created_at: created_at)
  end

  def rpc(method, params = {}, token: nil)
    headers = { "Accept" => "application/json, text/event-stream" }
    headers["Authorization"] = "Bearer #{token}" if token
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: method, params: params }, headers: headers, as: :json
  end

  def result = response.parsed_body.fetch("result")

  # JSON-RPC -32602: the SDK does not know the tool, as opposed to knowing it
  # and refusing. A client cannot probe for write tools this way.
  def assert_tool_not_found(name)
    error = response.parsed_body.fetch("error")
    assert_equal(-32_602, error["code"])
    assert_equal "Tool not found: #{name}", error["data"]
  end

  def tool_names = result.fetch("tools").map { |t| t["name"] }.sort

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
