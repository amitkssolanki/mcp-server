# Olist → Spree importer

Loads the [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
— ~100k real orders from 2016–2018 — into this Spree store, so there is
something worth querying.

## Getting the CSVs

The CSVs are gitignored (65MB). Fetch them into this directory:

```bash
cd db/olist && for f in olist_orders_dataset olist_order_items_dataset olist_products_dataset olist_customers_dataset olist_sellers_dataset olist_order_payments_dataset olist_order_reviews_dataset product_category_name_translation; do curl -sSLO "https://raw.githubusercontent.com/spdrio/Brazilian-E-Commerce-Public-Dataset-by-Olist/HEAD/files/$f.csv"; done
```

Kaggle is the canonical source but requires an account and API token. The
mirror above needs neither. Note it is a slightly different cut: its reviews
file has 100,000 rows where Kaggle's has 99,224. It also omits the
geolocation table, which this importer does not use.

## Running it

```bash
bin/rails olist:import
```

**This truncates Spree's catalogue and order tables** (products, variants,
prices, orders, line items, payments, users, addresses, taxons) plus all
`olist_*` tables. It leaves stores, countries, states, shipping categories,
payment methods and stock locations alone. Takes ~4 minutes.

```bash
bin/rails olist:import LIMIT=2000   # subset — orders only; catalogue still loads in full
bin/rails olist:verify              # row counts, referential integrity, Spree validity
bin/rails olist:queries             # sample analytics, to prove the data is worth querying
```

## What ends up where

Anything Spree already models goes in Spree's own tables. Everything
Olist-specific hangs off those records 1:1 in `olist_*` tables, so Spree stays
stock and upgrades don't fight us.

| Olist | Spree | Companion |
|---|---|---|
| `products` (32,951) | `spree_products` + master `spree_variants` + `spree_prices` | — |
| `product_category_name_translation` | `spree_taxonomies` / `spree_taxons` | — |
| `customers` (99,441) | `spree_users` (96,096, deduped) + `spree_addresses` (99,441) | — |
| `orders` (99,441) | `spree_orders` | `olist_order_details` — delivery timeline, Olist status |
| `order_items` (112,650) | `spree_line_items` | `olist_line_item_details` — freight, seller |
| `order_payments` (103,886) | `spree_payments` | `olist_payment_details` — type, installments |
| `order_reviews` (100,000) | — | `olist_reviews` |
| `sellers` (3,095) | — | `olist_sellers` |

## Decisions worth knowing about

**It bypasses ActiveRecord.** Spree's `Order` runs a state machine, totals
recalculation, inventory unit generation and a stack of callbacks on every
save. Correct for one order placed by one human, unusable for 100k. Everything
goes in via `insert_all!` with explicitly assigned primary keys, and the
derived columns Spree would normally maintain are backfilled in SQL afterwards
(`Importer#backfill_derived_columns`). That is the difference between four
minutes and several hours.

**`insert_all!`, never `insert_all`.** The non-bang form compiles to
`ON CONFLICT DO NOTHING`, so a row that trips a unique index disappears with no
error and the import silently under-reports. This bit during development:
`payment_type` was being written to `spree_payments.response_code`, which is
covered by a unique index on `(order_id, payment_method_id, response_code)` —
Olist orders routinely carry several payments of the same type, and 33 rows
vanished without a word.

**Products have no names.** Olist ships `product_id`, a category, and
measurements — no title, no copy. Names are synthesised as
`"<Category> <first 6 of product_id>"` and the description states the actual
weight/dimensions/photo count rather than inventing marketing text.

**Prices come from order items, not products.** The same product sells at
different prices across orders, so the importer makes one pass over
`order_items` to take a representative price per product before writing
`spree_prices`.

**One line item per Olist order-item row, quantity 1.** Olist models "two of
the same product" as two rows with separate `order_item_id` and its own freight
on each. Collapsing to `quantity: 2` would discard per-row freight.

**Customers are deduplicated on `customer_unique_id`.** Olist's `customer_id`
is per-order; `customer_unique_id` is the person. Hence 96,096 users against
99,441 addresses. Emails are `<customer_unique_id>@olist.invalid` — `.invalid`
is reserved by RFC 2606 and can never route anywhere real.

**Addresses have no street.** The dataset is anonymised down to city, state and
a 5-digit zip prefix. `address1` is literally `"(not in dataset)"` rather than a
plausible-looking invention. City, state and zip are real. Change
`Importer::UNKNOWN_STREET` if you want something prettier.

**Timestamps are treated as UTC.** Olist's are Brazil-local with no offset
recorded. Inventing one would be worse than being consistent.

**Money is BRL.** The store's `default_currency` and `supported_currencies` are
set to `BRL` by the importer.

**Order status mapping** — `delivered`/`shipped`/`invoiced`/`processing`/
`approved` → Spree `complete`; `created` → `cart`; `canceled`/`unavailable` →
`canceled`. The original Olist status is preserved on
`olist_order_details.olist_status`, so nothing is lost.

**No `spree_shipments`.** Building them needs shipping rates and stock
transfers that the dataset has nothing to say about. The delivery timeline —
which is the interesting part — lives on `olist_order_details`, including
precomputed `delivery_days` and `days_late`.

## The data is actually interesting

From `bin/rails olist:queries`:

```
Review score vs delivery lateness
  on time or early        89331   4.28
  1-3 days late            2556   3.70
  4-7 days late            1831   2.27
  more than a week late    3295   1.72
```

Real skew, real seasonality (November 2017 is a Black Friday spike: 7,544
orders against 4,631 in October), and non-obvious findings — the five
worst-reviewed sellers all deliver *early*, so their problem is the product,
not the logistics. Faker data does not do that.
