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

  test "it links the case study page, build log, repository and commerce data; /mcp stays text" do
    get "/"
    page = response.body

    assert_includes page, %(<a class="btn primary" href="#proof">Watch the demo (88 s)</a>)
    assert_includes page, %(href="https://amitsolanki.com/work/mcp-server/">Read the case study</a>)
    assert_includes page, %(href="https://amitsolanki.com/writing/mcp-server-spree-commerce/">Build log</a>)
    assert_includes page, %(href="https://github.com/amitkssolanki/mcp-server">Repository</a>)
    assert_includes page, %(<h3>Browse the underlying commerce data <span>→</span></h3>)
    assert_includes page, %(<a href="/products">Explore the data →</a>)
    assert_includes page, %(<a href="/products">Browse the underlying commerce data</a>)
    assert_includes page, "https://mcp-demo.railsfanatics.com/mcp"
    assert_no_match(%r{href="[^"]*/mcp"}, page, "/mcp must not be a clickable link")
    assert_no_match(/\.pdf|mcp-store\.amitsolanki\.com|Open the store|Store data/, page)
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

  test "robots.txt lets LinkedIn's preview bot fetch only the homepage and its share image" do
    get "/"
    og_image = URI(response.body[/<meta property="og:image" content="([^"]+)"/, 1]).path

    assert robots_allowed?("LinkedInBot", "/")
    assert robots_allowed?("LinkedInBot", og_image)
    %w[/products /products/perfumery-1e9e8ef04d /t/categories /?q=x /mcp /oauth/authorize].each do |path|
      assert_not robots_allowed?("LinkedInBot", path), "LinkedInBot may fetch #{path}"
    end
    [ "/", "/products", og_image ].each { |path| assert_not robots_allowed?("Googlebot", path), "Googlebot may fetch #{path}" }
  end

  private

  # RFC 9309 matching: the group for the agent (else "*"), then the longest matching rule, Allow on a tie;
  # "*" matches any run of characters and a trailing "$" anchors the end.
  def robots_allowed?(agent, path)
    groups = Rails.root.join("public/robots.txt").read.split(/\n\s*\n/).map do |block|
      lines = block.lines.map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?).map { |l| l.split(":", 2).map(&:strip) }
      [ lines.select { |k, _| k.casecmp?("user-agent") }.map(&:last), lines.reject { |k, _| k.casecmp?("user-agent") } ]
    end
    _, rules = groups.find { |agents, _| agents.any? { |a| a.casecmp?(agent) } } || groups.find { |agents, _| agents.include?("*") }
    matches = rules.select do |_, pattern|
      regex = Regexp.escape(pattern.delete_suffix("$")).gsub('\*', ".*")
      path.match?(/\A#{regex}#{'\z' if pattern.end_with?("$")}/)
    end
    best = matches.max_by { |kind, pattern| [ pattern.length, kind.casecmp?("allow") ? 1 : 0 ] }
    best.nil? || best.first.casecmp?("allow")
  end
end
