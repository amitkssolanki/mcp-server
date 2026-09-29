# MCP-Server

[![Verify](https://github.com/amitkssolanki/mcp-server/actions/workflows/verify.yml/badge.svg)](https://github.com/amitkssolanki/mcp-server/actions/workflows/verify.yml)

An MCP server that lets an AI assistant answer questions about a store's business, built over
99,441 real, anonymised Olist orders, and an independent evaluation harness that checks whether
those answers are true. The harness found nine correctness defects in tools that had already
been demonstrated working. They are fixed, and each one is kept as a regression that CI must
keep catching. The server runs as a live, read-only demo deployment behind OAuth.

## The question

**How do you know an AI interface over business data is telling the truth?**

A tool that returns a plausible number is easy to build. A model will repeat it with
confidence, and nobody notices when it is wrong. This project answers the question by working
every answer out a second time, from the source, without any of the code that produced the
first answer:

```
                 raw Olist CSVs
                       |
            +----------+----------+
            |                     |
     independent oracle     importer (Rails)
       (plain Ruby)               |
            |                 PostgreSQL
            |                     |
            |             MCP server (9 tools)  <-- JSON-RPC, as a client sends it
            |                     |
         expected              actual
            +----------+----------+
                       |
               field-by-field comparator
```

## Verification results

The same harness, same seed, run against the tools before and after the fixes:

| Check | Before fixes | After fixes |
|---|---:|---:|
| Canonical questions, answered to the cent | 5 / 35 | **35 / 35** |
| Invariants (150 seeded random cases) | 4 / 9 | **9 / 9** |
| Differential checks vs the oracle (200 seeded random cases) | 0 / 6 | **6 / 6** |
| CSV-to-database reconciliation | 2 / 2 | **2 / 2** |
| Known bugs re-introduced and caught | 3 / 3 | **12 / 12** |

- **Agent evaluation:** Claude, given only these tools, answered **45 of 45** runs correctly
  (15 questions x 3 runs), against answers the oracle computed and committed before any run.
- **Tests:** 52 (20 oracle self-tests, 21 HTTP/MCP boundary tests, 11 grader tests).
- **Reproducibility:** CI rebuilds the database from a pinned, checksum-verified copy of the
  dataset and reproduces the result fingerprint `f4841a48894b268d`.

The 12 known bugs are 3 reconstructed historical bugs plus 9 pre-fix versions of the tools;
before the fixes, only the 3 historical ones existed to re-introduce.

These are engineering evaluations of this system, not a statistical benchmark of any model.
Reconciliation passing before the fixes matters: the import was sound, and every defect was in
the tools.

Reports: [before](eval/reports/01b-before-fixes-full.txt),
[after](eval/reports/02-after-fixes.txt), [agent](eval/reports/03-agent-baseline.md).

## Live demo

```
https://mcp-demo.railsfanatics.com/mcp
```

- **OAuth with PKCE required.** A client discovers the server (RFC 9728 and RFC 8414),
  registers itself (RFC 7591) and sends the store admin to a consent screen. Access is granted
  by the owner; there is no guest access.
- **Read-only.** Only the `mcp:read` scope is issued, and the endpoint exposes the 9 read
  tools. The 2 write tools in the code are not reachable here.
- **Verified with a current client.** Claude Code 2.1.284 connected over OAuth, saw exactly
  the 9 read tools, and answered live questions with the oracle's figures (for example,
  November 2017 revenue of R$1,172,191.68).

Without credentials you can still inspect what a client sees first:

```bash
curl https://mcp-demo.railsfanatics.com/.well-known/oauth-protected-resource
curl https://mcp-demo.railsfanatics.com/.well-known/oauth-authorization-server
curl -i -X POST https://mcp-demo.railsfanatics.com/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'     # 401, with a resource_metadata pointer
```

## What was wrong

Nine defects, in five classes. The full register, with before/after figures and the fixing
commit for each, is [eval/findings.yml](eval/findings.yml).

- **Join fan-out.** 555 orders carry more than one review. Every query joining reviews at
  order level counted those orders twice: a search reported 100,000 matches for 99,441 orders,
  and one customer's lifetime value doubled.
- **Population mistakes.** Cancelled and unavailable orders were counted as sales in product,
  category and seller figures, and in delivery metrics.
- **Undefined metrics.** Two tools asked for "Health Beauty revenue" returned R$1,258,681 and
  R$1,445,137, and both did what they were written to do. The fix was a definition first
  ([docs/METRICS.md](docs/METRICS.md)): under it, the category's item revenue is
  R$1,255,695.13.
- **Revenue aggregation.** Whole-order totals were credited to every seller and every payment
  method an order touched: credit card revenue came out R$185,429 too high.
- **Customer lookup.** Email was matched as a substring, so `%` returned an arbitrary
  customer's history.

## Why the oracle is independent

The oracle (`eval/oracle/`) reads the raw CSVs with Ruby's CSV library and computes each metric
as a fold over one fact record per order. It shares no code with the importer, the Spree
models, the SQL or the tools, and a test asserts it issues no database queries. It is not a
translation of the SQL: fan-out bugs come from joins multiplying rows, and the oracle has no
joins. Answers are compared field by field, to the cent.

The two sides do share the input files and the written metric definitions, and
[eval/README.md](eval/README.md) lists those shared assumptions. The oracle itself is tested
against a hand-built five-order dataset whose expected values are worked out by hand.

Regressions are proven, not assumed. Each known-bad implementation (three reconstructed
historical bugs and nine pre-fix versions copied verbatim from git) is swapped in, and a named
check must fail differently from how it fails on the unmodified system.

## Agent evaluation

The layers above test the tools. The agent evaluation tests whether a model using them gets
the right answer.

- 15 natural-language questions, each testing a distinction such as placed vs completed
  orders, gross vs item revenue, or seller vs delivery population.
- Expected answers computed by the oracle and committed before any run.
- Run through Claude Code in headless mode with `claude-sonnet-5`, with only the store's tools
  available: no repository, files or other servers.
- Graded deterministically from a structured final answer. No model judges another.

**Result: 45/45** answers, tool choices and arguments correct, and 15 of 15 questions correct
on every run.

**Limits:** one model, one client version, 3 runs per question. It shows these tools can be
used correctly, not how any model performs in general. The planned tool-description
experiment was not run, because the baseline showed no description weakness to target.
Details: [eval/reports/03-agent-baseline.md](eval/reports/03-agent-baseline.md).

## MCP interoperability findings

Two failures surfaced only when a real, current client talked to the server. No unit test
could have found either.

- **F12, protocol revision.** Claude Code negotiated MCP revision 2026-07-28, which the Ruby
  SDK in use (mcp 1.1.0) advertised but did not implement. The server connected cleanly and
  exposed zero tools. With no tools, Claude wrote tool calls as prose, and in one probe
  invented an answer (6 cancelled 2018 orders; the oracle says 334). The server now pins
  the negotiated revision to 2025-11-25, the newest one the SDK implements. Over the live
  endpoint the same question returns 334.
- **F14, OAuth callback.** The deployed OAuth server rejected Claude Code's
  `http://localhost` callback, so only web clients could connect. Plain HTTP is now allowed
  for loopback callbacks only (`localhost`, `127.0.0.1`, `[::1]`). Every other callback still
  requires HTTPS, and PKCE and admin consent are unchanged.

A related finding, F13, is recorded as a defence-in-depth consideration: customer-written
review text reaches the model in structured results without a "treat as data" label. In 6 of
6 local probes the model declined instruction-shaped review text. See
[eval/reports/05-f13-untrusted-text.md](eval/reports/05-f13-untrusted-text.md).

## Architecture

- **Store:** Rails 8.1 and Spree 5.6 on PostgreSQL, loaded from the Olist CSVs by a bulk
  importer (`lib/olist/importer.rb`) that bypasses ActiveRecord callbacks (about 3 minutes
  for the full dataset).
- **MCP server** (`app/mcp/store_mcp/`): 9 read tools and 2 write tools, built on the MCP Ruby
  SDK. Two transports: stdio (`bin/mcp-stdio`) for local clients, and streamable HTTP
  (`McpController`, at `/mcp`) behind OAuth.
- **OAuth:** Doorkeeper for tokens and PKCE, with hand-written discovery (RFC 9728, RFC 8414)
  and dynamic client registration (RFC 7591) controllers. The consent screen is wired to the
  store admin login.
- **Evaluation harness** (`eval/`): oracle, canonical questions, invariants, differential
  checks, reconciliation, regressions and the agent evaluation.
- **Deployment:** Kamal 2 on a shared VPS, TLS through kamal-proxy, its own PostgreSQL
  accessory.

## Reproduce it

Ruby 3.4.7 and PostgreSQL.

```bash
bundle install
bin/olist-fetch                     # the 8 Olist CSVs, pinned mirror, SHA-256 verified
RAILS_ENV=test bin/rails db:create db:schema:load db:seed olist:import
RAILS_ENV=test bin/rails test       # 52 tests
RAILS_ENV=test bin/rails eval:run   # harness: prints a report and the fingerprint
```

The import takes a few minutes and the harness about two to three. CI
([`.github/workflows/verify.yml`](.github/workflows/verify.yml)) runs exactly these steps on
every push, in about 6 to 8 minutes, and fails on any failing check, uncaught regression or
failing test. The agent evaluation (`bin/rails eval:agent`) is not part of CI, because it
needs a logged-in Claude account; see [eval/README.md](eval/README.md).

## Evidence

| What | Where |
|---|---|
| Metric definitions and the decisions behind them | [docs/METRICS.md](docs/METRICS.md) |
| Harness method, independence, provenance | [eval/README.md](eval/README.md) |
| Findings register, F1 to F14 | [eval/findings.yml](eval/findings.yml) |
| Before and after | [01b-before-fixes-full](eval/reports/01b-before-fixes-full.txt), [02-after-fixes](eval/reports/02-after-fixes.txt) |
| First harness run (13 questions) | [01-before-fixes](eval/reports/01-before-fixes.txt) |
| Agent evaluation | [03-agent-baseline](eval/reports/03-agent-baseline.md) |
| Customer text in structured results (F13) | [05-f13-untrusted-text](eval/reports/05-f13-untrusted-text.md) |
| Regression corpus | [eval/regressions/](eval/regressions/) |
| Canonical questions | [eval/questions/](eval/questions/), [eval/agent/questions.yml](eval/agent/questions.yml) |

## Dataset and scope

- **Data:** the [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce),
  CC BY-NC-SA 4.0: 99,441 anonymised orders from 2016 to 2018. It is downloaded at run time
  and never committed; see [db/olist/README.md](db/olist/README.md).
- **Products:** Olist ships no product names, so the importer synthesizes them from the
  category and a product-id prefix.
- **Scope:** one store, one admin account, no rate limiting. This is a demonstration
  deployment, not a store anyone buys from.

## Running your own

**Admin login.** The Spree generator skips authentication by default. The admin panel and the
OAuth consent screen both need real Devise:

```bash
bin/rails g spree:admin:devise
EMAIL=admin@example.com PASSWORD=yourpassword bin/rails spree:cli:create_admin
bin/rails server                    # storefront at /, admin at /admin
```

**Local MCP (stdio):** no auth, since the OS process boundary is the trust boundary. Set
`MCP_READ_ONLY=true` to expose only the read tools.

```jsonc
{ "mcpServers": { "store": { "command": "/absolute/path/to/checkout/bin/mcp-stdio" } } }
```

**Remote MCP:** point a client that supports dynamic registration at `https://your-host/mcp`.
Behind a tunnel or a new domain, two independent host checks must both allow the hostname:
Rails' `config.hosts` and the MCP SDK's `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS`.

**Deploy:** `config/deploy.yml` records the reasoning. It covers read-only mode
(`MCP_ALLOW_WRITE_SCOPE=false`, enforced both when a token is issued and when it is used),
both host checks, `DEMO_NOINDEX`, and the hostname alias kept during a move
(`RAILS_ALIAS_HOSTS`). After deploying new importer code to an existing database, run
`bin/rails olist:recount_products`.

### The tools

| Tool | Scope | What it does |
|---|---|---|
| `search_products`, `get_product` | read | Catalogue lookup |
| `list_categories` | read | Products, units, item revenue and review score per category |
| `search_orders`, `get_order` | read | Order lookup, including delivery timeline and review |
| `revenue_report` | read | Revenue by month, category, state, payment method or seller |
| `delivery_performance` | read | Lateness vs review score, by band, category, state or seller |
| `seller_performance` | read | Seller ranking by revenue, review score or lateness |
| `find_customer` | read | A customer's order history, by exact email |
| `update_product_price` | write | Preview first; writes only with `confirm: true`. Not exposed by the deployment |
| `update_order_status` | write | Same pattern. Not exposed by the deployment |

## Limitations

- **Read-only deployment.** The write tools are exercised locally only, and their
  preview-then-confirm step is enforced by the tool description, not by server state (F10).
  That would need fixing before writes were ever enabled.
- **Customer text:** F13 above, a defence-in-depth consideration rather than a demonstrated
  issue.
- **One tenant.** Customer lookup is not scoped to a store (F11). With one store it cannot
  leak anything.
- **Operations:** one admin account, no rate limiting on `/admin` or `/oauth`, and no audit
  trail of who approved which OAuth grant.
- **SDK:** the protocol pin (F12) stays until the MCP Ruby SDK is upgraded to a version that
  implements 2026-07-28.
