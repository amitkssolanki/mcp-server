# Metric definitions

Every number an MCP tool reports, and every number the evaluation harness
checks, is one of the metrics below. The definitions are the contract: the
tools implement them in SQL over the Spree tables, and the oracle in
`eval/oracle/` implements them separately in Ruby over the raw Olist CSVs. If
the two disagree, one of them is wrong, or this document is ambiguous. The
harness does not decide which.

These were written after the harness showed that the tools had no shared
definitions. Two tools asked for "Health Beauty revenue" returned
R$1,258,681 and R$1,445,137, and both were computing what they meant to.
Resolving that meant deciding what each word means before touching any SQL.
The decisions and their reasons are recorded here so that they can be
disagreed with.

## Principles

1. **One population per row.** Every metric in a result row is computed over
   the same set of orders. A row never mixes revenue from completed orders
   with review scores from cancelled ones.
2. **Allocate at the grain the data has.** Olist records price and freight
   per order item, and every item has exactly one product, one category and
   one seller. Anything split by product, category or seller is summed from
   items and is never taken from a whole-order total.
3. **Say whether a breakdown adds up.** A grouping either partitions its
   population, so the buckets sum to the total, or it overlaps. Tools only
   print an "all rows" total for groupings that partition.

## Populations

| Name | Definition | Count |
|---|---|---:|
| **placed orders** | Every order in `olist_orders_dataset.csv`. | 99,441 |
| **completed orders** | Olist `order_status` is one of `delivered`, `shipped`, `invoiced`, `processing`, `approved`. Excluded: `canceled`, `unavailable` (never fulfilled) and `created` (never approved; Spree's `cart`). This is Spree's `complete` state. | 98,202 |
| **delivered orders** | Completed orders where `days_late` is defined (see below). This is the population for all delivery metrics. | 96,470 |

Revenue, order counts, units and review averages use **completed orders**
unless a tool's description says otherwise. `search_orders` searches **placed
orders**, because finding a cancelled order is a legitimate thing to want.

## Money (BRL)

| Metric | Definition | Grain |
|---|---|---|
| `item_revenue` | Sum of `order_items.price` over completed orders. Merchandise only. | item |
| `freight` | Sum of `order_items.freight_value` over completed orders. | item |
| `gross_revenue` | `item_revenue + freight`. For a single order, this is the order total. | item (sums to order) |
| `payment_value` | Sum of `order_payments.payment_value` over completed orders. It is not the same as gross revenue: vouchers, installment interest and rounding mean an order's payments can differ from its items plus freight. It is only used for the payment-method breakdown. | payment |
| `avg_order_value` | `gross_revenue / orders` for the bucket. For month and state, which partition orders, this is the usual AOV. For category and seller, it is the bucket's share of each order that touches the bucket. | derived |

Sums are exact decimal sums rounded to 2 dp at the end. Averages are exact
means rounded at the end: money and review scores to 2 dp, days to 1 dp,
percentages to 1 dp. Rounding is half away from zero.

## Counts

| Metric | Definition |
|---|---|
| `orders` | Distinct completed orders contributing to the bucket. An order with items in two categories counts once in each, so `orders` **does not** add up across category, seller or payment-method buckets. |
| `units_sold` | Number of order-item rows in completed orders. Olist models quantity 2 as two rows. |
| `products` | Products in the catalogue in that category, sold or not. |
| `total_matches` (search) | Distinct placed orders matching every filter. |

## Dimensions

| Dimension | Definition | Partitions |
|---|---|---|
| `month` | `YYYY-MM` of `order_purchase_timestamp`. | orders, items |
| `state` | The customer's `customer_state` for that order. | orders, items |
| `category` | The product's `product_category_name`, translated with `product_category_name_translation.csv`. The two categories with no translation keep their Portuguese name. A blank category is `Uncategorised`. Every product has exactly one category. | items only |
| `seller` | The item's `seller_id`. | items only |
| `payment_method` | `order_payments.payment_type`. | payments only |

Tools display category names title-cased ("Health Beauty"). Comparisons use
the underscore form (`health_beauty`), so display formatting is never
mistaken for a data error.

## Reviews

**One review score per order.** 555 orders carry more than one review (1,114
rows), and 209 of those have reviews with different scores. An order's score
is its **most recent review**: latest `review_creation_date`, then latest
`review_answer_timestamp`, then highest `review_id` (only to break the last
tie deterministically). Rationale: a later review is the customer's revised
opinion, and one score per order is what stops an order being counted twice.

| Metric | Definition |
|---|---|
| `avg_review` | Mean order score over the bucket's completed orders that have a review. Each order counts once per bucket, however many items or reviews it has. |

## Delivery

| Metric | Definition |
|---|---|
| `days_late` | `(order_delivered_customer_date - order_estimated_delivery_date)` in days, rounded to the nearest whole day. Negative means early. Defined only when both timestamps exist. |
| `delivery_days` | `(order_delivered_customer_date - order_purchase_timestamp)` in days, rounded. |
| lateness bucket | `on time or early` (≤ 0), `1-3 days late`, `4-7 days late`, `more than a week late` (> 7). |
| `late_orders` / `late_rate` | Delivered orders with `days_late > 0`, as a count and as a percentage of the bucket's delivered orders. |
| `avg_days_late`, `avg_delivery_days` | Means over the bucket's delivered orders. |

Six cancelled orders have both a delivery timestamp and an estimate. They have
a `days_late` (it is a fact about the timestamps), so `search_orders` can
filter on it. They are not delivered orders, so delivery metrics exclude them.

## Customers

A customer is a `customer_unique_id`. Olist's `customer_id` is per order. The
store's customer email is `<customer_unique_id>@olist.invalid`, and
`find_customer` matches it **exactly** (case-insensitive), never as a
substring.

| Metric | Definition |
|---|---|
| `orders` | Placed orders by the customer, any status. It is a history count. |
| `lifetime_value` | Gross revenue of the customer's completed orders. |
| `avg_review` | Mean order score over the customer's completed orders that have a review. |

## Dates

All timestamps are Olist's Brazil-local values, stored without an offset
(see `db/olist/README.md`). A `from`/`to` filter is inclusive by calendar
date on `order_purchase_timestamp`: `to: 2017-11-24` includes an order placed
at 23:59:59 that day.

## Where each tool stands

| Tool | Metrics |
|---|---|
| `revenue_report` | month/state: `orders`, `item_revenue`, `freight`, `gross_revenue` (reported as `revenue`), `avg_order_value`. Same fields for category/seller, allocated per item. payment_method: `orders`, `payment_value` (reported as `revenue`). |
| `list_categories` | `products`, `units_sold`, `item_revenue` (reported as `revenue`), `avg_review` |
| `seller_performance` | `orders`, `item_revenue` (reported as `revenue`), `avg_review`, `avg_days_late` |
| `delivery_performance` | `orders`, `late_orders`, `late_rate`, `avg_days_late`, `avg_delivery_days`, `avg_review` over delivered orders |
| `search_orders` | `total_matches` over placed orders; the review filter uses the order score |
| `find_customer` | `orders`, `lifetime_value`, `avg_review` |
| `get_product`, `search_products` | `units_sold` and `revenue` are the product's `units_sold` and `item_revenue`; `orders`, `avg_review` and `avg_days_late` are over completed orders |
