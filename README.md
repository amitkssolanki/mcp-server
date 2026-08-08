# Spree + MCP

A [Spree Commerce](https://spreecommerce.org) store seeded with the [Olist Brazilian
e-commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — 100,000
real orders from 2016–2018 — with an [MCP](https://modelcontextprotocol.io) server on top
that lets an AI assistant query and (carefully) manage it. Built to learn MCP by building
one against something real, not a toy API. See [db/olist/README.md](db/olist/README.md)
for why real data instead of generated seeds, and every mapping decision the importer makes.

**This isn't a production template.** Real data, real OAuth, real bugs found and fixed —
but the deployment story (a hand-created admin account, a dev tunnel, no rate limiting) is
learning-project shaped, not launch shaped. See [Known limitations](#known-limitations).

## What's here

- **The store**: standard Spree 5.6 (storefront, admin, API), backed by Postgres, seeded
  from real Olist data via a bulk importer that bypasses ActiveRecord's callback chain —
  100k orders in about four minutes.
- **The MCP server** (`app/mcp/store_mcp/`): 9 read tools and 2 write tools over the store —
  revenue and delivery-performance reports, seller rankings, order/customer lookup, and
  price/order-status updates that preview before they write. Both transports: local stdio
  (`bin/mcp-stdio`) and remote streamable HTTP (`McpController`, mounted at `/mcp`).
- **OAuth 2.1** (`config/initializers/doorkeeper.rb` + a few small controllers): the remote
  endpoint is protected by [Doorkeeper](https://github.com/doorkeeper-gem/doorkeeper) with
  PKCE required, plus hand-written RFC 9728 (protected resource metadata), RFC 8414
  (authorization server metadata), and RFC 7591 (dynamic client registration) — enough for
  a client like claude.ai to discover the server, self-register, and get a scoped token with
  no manual setup on your end beyond approving the consent screen.

## Setup

Ruby 3.4.7, Postgres running locally.

```bash
bundle install
bin/rails db:create db:migrate db:seed
```

`db:seed` sets up Spree's reference data (countries, states, a default store, shipping
categories, a payment method) — not the Olist data yet.

### Load the Olist data

```bash
cd db/olist && for f in olist_orders_dataset olist_order_items_dataset olist_products_dataset \
  olist_customers_dataset olist_sellers_dataset olist_order_payments_dataset \
  olist_order_reviews_dataset product_category_name_translation; do
  curl -sSLO "https://raw.githubusercontent.com/spdrio/Brazilian-E-Commerce-Public-Dataset-by-Olist/HEAD/files/$f.csv"
done
cd ../..
bin/rails olist:import      # ~4 min for the full 100k orders; LIMIT=2000 for a quick subset
bin/rails olist:verify      # row counts, referential integrity, Spree validity
bin/rails olist:queries     # sample analytics — proves the data is worth querying
```

`olist:import` **truncates** Spree's product/order/user/address/taxon tables first — it
owns those tables, not anything else you might add later. See
[db/olist/README.md](db/olist/README.md) if you're planning to reuse this store for
something else too.

### Set up Devise and an admin login

The generator that scaffolds Spree skips authentication by default. This needs real Devise
(not the bcrypt placeholder Spree falls back to) for both the admin panel and Doorkeeper's
consent screen to work:

```bash
bin/rails g spree:admin:devise
bin/rails g spree:storefront:devise   # only if you also want customer-facing login/signup
EMAIL=admin@example.com PASSWORD=yourpassword bin/rails spree:cli:create_admin
```

### Run it

```bash
bin/rails server
```

- Storefront: `http://localhost:3000/`
- Admin: `http://localhost:3000/admin`

## Using the MCP server

### Locally (stdio)

```jsonc
// Claude Desktop config, or any stdio-based MCP client
{
  "mcpServers": {
    "spree-store": {
      "command": "/absolute/path/to/this/checkout/bin/mcp-stdio"
    }
  }
}
```

No auth — the OS process boundary is the trust boundary for a locally-spawned server. Set
`MCP_READ_ONLY=true` in the client's env config to expose only the 9 read tools.

### Remote (streamable HTTP + OAuth)

The `/mcp` endpoint requires a Doorkeeper-issued Bearer token with at least the `mcp:read`
scope; `mcp:write` additionally exposes the two write tools. A client that supports RFC 7591
(claude.ai's custom connectors included) can self-register and walk the full OAuth flow
without you creating anything by hand — point it at:

```
https://your-host/mcp
```

It'll hit the 401, discover `/.well-known/oauth-protected-resource`, find the authorization
server, register itself at `/register`, and send you (the Spree admin) to the consent screen.
Approving the consent grant is an admin-equivalent access decision — every tool here reads or
writes store-operator data, not customer-scoped data — so `resource_owner_authenticator` in
the Doorkeeper initializer is wired to the admin login, not the storefront one.

For local testing before you have a real domain, a tunnel (ngrok or similar) works, with two
things worth knowing:

- Rails' own `Host` header check (`config.hosts` in `config/environments/development.rb`)
  needs the tunnel's hostname allowed, or every request 403s before reaching any controller.
- The MCP Ruby SDK has its *own*, separate DNS-rebinding protection defaulting to loopback
  hosts only — set `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` when launching the server, or
  it'll reject the tunnel's hostname independently of the Rails-level check above.

### The tools

| Tool | Scope | What it does |
|---|---|---|
| `search_products`, `get_product` | read | Catalogue lookup |
| `list_categories` | read | Revenue/units/reviews per category |
| `search_orders`, `get_order` | read | Order lookup, including delivery timeline and review |
| `revenue_report` | read | Revenue grouped by month/category/state/payment method/seller |
| `delivery_performance` | read | Lateness vs. review score, by bucket/category/state/seller |
| `seller_performance` | read | Seller ranking by revenue, review score, or lateness |
| `find_customer` | read | Customer order history |
| `update_product_price` | write | Previews the change; only writes with `confirm: true` |
| `update_order_status` | write | Same preview-then-confirm pattern |

## Known limitations

- Single hand-created admin account, no per-scope granularity beyond read/write, no rate
  limiting, no audit trail of who approved which OAuth grant.
- RFC 7591 client registration is intentionally wide open (registering a client grants it
  nothing by itself — every token still needs an admin's explicit consent), but that's a
  design choice worth a second opinion from someone who's actually shipped this before.
- Products have no real names or photos — the Olist dataset doesn't include them, so the
  importer synthesizes names from category + a product-ID fragment.
- The tunnel-based remote setup above is dev-only. A real deployment needs `config.hosts`
  and `MCP_ALLOWED_HOSTS`/`MCP_ALLOWED_ORIGINS` pointed at the actual domain, not a
  wildcard tunnel pattern.
