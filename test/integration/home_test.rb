# frozen_string_literal: true

require "test_helper"

# The demo homepage. Its figures and caveats are governed by the project's claims ledger; this pins the
# ones it publishes, and checks the page does not drift into claims the evidence does not support.
class HomeTest < ActionDispatch::IntegrationTest
  VIDEO_URL = "https://amitsolanki.com/writing/mcp-server/mcp-verification-eric-portfolio.mp4"
  VIDEO_TITLE = "MCP Server verification demo (AI voice: elevenlabs.io)"
  READ_TOOLS = %w[delivery_performance find_customer get_order get_product list_categories
                  revenue_report search_orders search_products seller_performance].freeze
  WRITE_TOOLS = %w[update_order_status update_product_price].freeze

  setup { host! "localhost" }

  test "the homepage is the demo's own page, not the storefront" do
    get "/"

    assert_response :success
    assert_includes response.body, "Ask an AI about a real commerce system."
    assert_not_includes response.body, "Welcome to our shop"
  end

  test "it publishes the ledger's figures with their documented meaning" do
    get "/"
    page = response.body

    [
      "99,441",                                  # orders, real and anonymised
      "9 read-only tools",                       # the deployed tool surface
      "OAuth with PKCE",
      "334 orders</strong> placed in 2018 were cancelled",
      "R$1,172,191.68",                          # November 2017 gross revenue
      "5 of 35 canonical questions correctly",   # before the fixes
      "35 / 35", "9 / 9", "6 / 6",
      "12 / 12", "3 historical, 9 pre-fix",      # what 12/12 means
      "45 / 45",
      "f4841a48894b268d"
    ].each { |figure| assert_includes page, figure }
  end

  test "it carries the demo, not-a-benchmark and anonymised-data caveats" do
    get "/"
    page = response.body

    assert_includes page, "not a benchmark"
    assert_includes page, "not a guarantee beyond the checks run"
    assert_includes page, "A live, read-only demo deployment, not a business"
    assert_includes page, "anonymised"
    assert_includes page, "Brazilian E-Commerce Public Dataset by Olist, CC BY-NC-SA 4.0"
    assert_equal page.scan(/benchmark/i).size, page.scan(/not a benchmark/i).size, "benchmark appears outside 'not a benchmark'"
  end

  test "it names the 9 read tools and no write tool" do
    get "/"

    READ_TOOLS.each { |tool| assert_includes response.body, "<code>#{tool}</code>" }
    WRITE_TOOLS.each { |tool| assert_not_includes response.body, tool }
  end

  test "it embeds the approved video from amitsolanki.com with its attribution title" do
    get "/"

    assert_includes response.body, %(<source src="#{VIDEO_URL}" type="video/mp4">)
    assert_includes response.body, %(title="#{VIDEO_TITLE}")
    assert_includes response.body, "<strong>#{VIDEO_TITLE}.</strong>"
  end

  test "its canonical and share URLs use the primary host, also on the alias host" do
    previous, ENV["RAILS_HOST"] = ENV["RAILS_HOST"], "primary.example"
    host! "alias.example"
    get "/"

    assert_includes response.body, %(<link rel="canonical" href="https://primary.example/">)
    assert_includes response.body, %(<meta property="og:url" content="https://primary.example/">)
    assert_match(%r{<meta property="og:image" content="https://primary\.example/assets/home-og-\h+\.png">}, response.body)
  ensure
    ENV["RAILS_HOST"] = previous
  end

  test "it has no forms: nothing to submit, sign up for or buy" do
    get "/"

    assert_not_includes response.body, "<form"
  end

  test "the storefront still browses products, with the demo banner and attribution" do
    get "/products"

    assert_response :success
    assert_includes response.body, "Read-only demo data"
    assert_includes response.body, "Brazilian E-Commerce Public Dataset by Olist"
    assert_match(%r{<link rel="stylesheet" href="/assets/storefront_demo-\h+\.css"}, response.body)
  end
end
