# Metric definitions

Every number an MCP tool reports, and every number the evaluation harness
checks, is one of the metrics below. The definitions are the contract. The
tools implement them in SQL over the Spree tables, and the oracle in
`eval/oracle/` implements them separately in Ruby over the raw Olist CSVs. If
the two disagree, one of them is wrong or this document is ambiguous. The
harness does not decide which.

**These are project-level business definitions, chosen for this store.**
They are not facts about the Olist dataset, and other definitions are
defensible. Where a reasonable alternative exists, it is named below with
the reason it was not chosen. The five decisions marked **(approved)** were
reviewed and approved by the project owner on 28 Sep 2026. The rest follow
from them or from the data's own grain.

These were written after the harness showed that the tools had no shared
definitions. Two tools asked for "Health Beauty revenue" returned
R$1,258,681 and R$1,445,137, and each was computing what it meant to.

## Principles

1. **One population per row.** Every metric in a result row is computed over
   the same set of orders. A row never mixes revenue from completed orders
   with review scores from cancelled ones.
2. **Allocate at the grain the data has.** Olist records price and freight
   per order item, and every item has exactly one product, one category and
   one seller. Anything split by product, category or seller is summed from
   items and is never taken from a whole-order total.
3. **Say whether a breakdown adds up.** A grouping either partitions its
   population, so the buckets sum to the total, or it overlaps. Tools give an
   order total only for groupings that partition orders, and say so
   (`orders_additive` in `revenue_report`'s structured output).

## Populations

| Name | Definition | Count |
|---|---|---:|
| **placed orders** | Every order in `olist_orders_dataset.csv`, any status. | 99,441 |
| **completed orders** | Olist `order_status` is `delivered`, `shipped`, `invoiced`, `processing` or `approved` (Spree's `complete`). | 98,202 |
| **delivered orders** | Completed orders with a customer delivery timestamp and a delivery estimate, so `days_late` is defined. | 96,470 |

Not completed: `canceled` (625), `unavailable` (609, never fulfilled) and
`created` (5, never approved; Spree's `cart`).

**Revenue counts completed orders only (approved).** An order is revenue once
the seller has accepted it, whether or not it has arrived yet.
*Alternative:* delivered orders only ("realised" revenue). Rejected because
it would drop about 1,700 shipped, invoiced or processing orders that are
real sales, and put a lag into the most recent months.

## Metrics

| Metric | Meaning | Order states | Freight | Several sellers in one order | Several reviews | Grain | Adds up across |
|---|---|---|---|---|---|---|---|
| `item_revenue` | Sum of `order_items.price` | completed | excluded | each seller gets its own items | n/a | item | month, state, category, seller |
| `freight` | Sum of `order_items.freight_value` | completed | is the metric | each item's own freight | n/a | item | month, state, category, seller |
| `gross_revenue` (tools: `revenue`) | `item_revenue + freight`; for one order, the order total | completed | included | each seller gets its own items and their freight | n/a | item, summing to order | month, state, category, seller |
| `payment_value` (tools: `revenue` under `payment_method`) | Sum of `order_payments.payment_value` | completed | included (it is what was paid) | n/a | n/a | payment | payment methods |
| `avg_order_value` | bucket `gross_revenue` / bucket `orders` | completed | included | bucket's own share | n/a | derived | no (an average) |
| `orders` | Distinct completed orders contributing to the bucket | completed | n/a | the order is in every seller's bucket | n/a | order | month and state only; **not** category, seller or payment method |
| `units_sold` | Order-item rows | completed | n/a | n/a | n/a | item | category |
| `products` | Catalogue products in the category, sold or not | n/a | n/a | n/a | n/a | product | categories |
| `avg_review` | Mean order score over the bucket's orders that have a review, each order once | completed | n/a | the order counts once for each seller | most recent review only | order | no (an average) |
| `days_late`, `delivery_days` | See Delivery | fact of the timestamps | n/a | n/a | n/a | order | no |
| `late_orders`, `late_rate`, `avg_days_late`, `avg_delivery_days` | See Delivery | delivered | n/a | the order counts once for each seller | n/a | order | `late_orders` across lateness bands and states |
| `total_matches` (search) | Distinct placed orders matching every filter | **placed** (any) | n/a | n/a | the filter uses the order's one score | order | status partitions it |
| customer `orders` | Orders the customer placed | **placed** (any) (approved) | n/a | n/a | n/a | order | n/a |
| customer `lifetime_value` | `gross_revenue` of the customer's orders | completed (approved) | included | n/a | n/a | order | n/a |

`payment_value` and `gross_revenue` are **different metrics on purpose**.
Over completed orders, gross revenue is R$15,735,527.03 and payments collected
are R$15,738,448.91. In 304 orders the payments differ from items plus freight
by more than a cent (installment interest, vouchers). A payment-method
breakdown can only split what was paid, so it reports what was paid.

Sums are exact decimal sums, rounded to 2 dp at the end. Averages are exact
means rounded at the end: money and review scores to 2 dp, days to 1 dp,
percentages to 1 dp. Rounding is half away from zero.

## Dimensions

| Dimension | Definition | Partitions |
|---|---|---|
| `month` | `YYYY-MM` of `order_purchase_timestamp`. | orders and items |
| `state` | The customer's `customer_state` for that order. | orders and items |
| `category` | The product's `product_category_name`, translated with `product_category_name_translation.csv`. The two categories with no translation keep their Portuguese name. A blank category is `Uncategorised`. Every product has exactly one category. | items only |
| `seller` | The item's `seller_id`. | items only |
| `payment_method` | `order_payments.payment_type`. | payments only |

**Categories overlap at order level and partition at item level.** An order
with a Health Beauty item and a Watches Gifts item is in both categories'
`orders`, so category order counts sum to more than the number of orders.
Every item is in exactly one category, so category `item_revenue`, `freight`
and `gross_revenue` add up to the store totals. Sellers behave the same way.

**Seller attribution: item-level, never whole-order.** A seller is credited
with its own items and their freight. *Alternative:* crediting the whole
order to every seller in it. Rejected because in the 1,278 multi-seller
orders it credits each seller with the others' sales. That is what
`revenue_report(seller)` used to do (F4).

Tools display category names title-cased ("Health Beauty"). Comparisons use
the underscore form (`health_beauty`), so display formatting is never
mistaken for a data error.

## Reviews

**An order's score is its most recent review (approved).** 555 orders carry
more than one review (1,114 rows), and 209 of those have reviews with
different scores. Order: latest `review_creation_date`, then latest
`review_answer_timestamp`, then highest `review_id`. The last tiebreak exists
only so the answer is deterministic; it has no business meaning.
*Alternative:* the mean of the order's reviews. Rejected because a later
review is the customer's revised opinion, and averaging a complaint with its
own retraction describes neither.

**Review averages exclude cancelled orders (approved).** The rule is applied
to all three non-completed statuses: cancelled, unavailable and created. An
unavailable order was never fulfilled either, so its review is not about a
delivered product. That keeps review averages on the same population as
revenue (principle 1). *Alternative:* average every reviewed order. That is
reasonable for measuring customer sentiment, but it mixes populations within
a row. `search_orders` can still find the reviews of cancelled orders.

## Delivery

| Metric | Definition |
|---|---|
| `days_late` | `(order_delivered_customer_date - order_estimated_delivery_date)` in days, rounded to the nearest whole day. Negative means early. Defined whenever both timestamps exist, whatever the status. |
| `delivery_days` | `(order_delivered_customer_date - order_purchase_timestamp)` in days, rounded. |
| lateness bucket | `on time or early` (≤ 0), `1-3 days late`, `4-7 days late`, `more than a week late` (> 7). |
| `late_orders` / `late_rate` | Delivered orders with `days_late > 0`, as a count and as a percentage of the bucket's delivered orders. |
| `avg_days_late`, `avg_delivery_days` | Means over the bucket's delivered orders. |

Six cancelled orders have both a delivery timestamp and an estimate, so they
have a `days_late`, and `search_orders` can filter on it. They are not
delivered orders, so delivery metrics exclude them (F8).

## Customers

A customer is a `customer_unique_id`. Olist's `customer_id` is per order. The
store's customer email is `<customer_unique_id>@olist.invalid`, and
`find_customer` matches it **exactly**, case-insensitively, never as a
substring (F9).

**Customer order count covers every status (approved).** It is a history
count: "this customer has placed 17 orders". **Lifetime value covers
completed orders only (approved)**, because it is revenue. So a customer can
show 2 orders and the lifetime value of 1, and that is correct.

## Dates

All timestamps are Olist's Brazil-local values, stored without an offset
(see `db/olist/README.md`). A `from`/`to` filter is inclusive by calendar
date on `order_purchase_timestamp`: `to: 2017-11-24` includes an order placed
at 23:59:59 that day.

## When two tools answer the same question

Where two tools could be asked the same thing, the difference is one of
three kinds, and each one is recorded.

| Question | Tools | Kind | Resolution |
|---|---|---|---|
| Category revenue | `list_categories` `revenue` vs `revenue_report(category)` | **Implementation bug + ambiguous definition** (F3) | Both now expose `item_revenue`, which must agree (invariant `same-metric-same-number`). `revenue_report`'s `revenue` is `gross_revenue`, a different named metric. |
| Seller revenue | `seller_performance` `revenue` vs `revenue_report(seller)` | **Implementation bug** (F4) | Same as categories: `item_revenue` agrees; `revenue` differs by exactly the seller's freight. |
| Product revenue and units | `search_products` vs `get_product` vs `list_categories` | **Implementation bug** (F5): counters included cancelled orders | All read the same counters, now over completed orders; checked by invariant. |
| Orders in a period | `search_orders` `total_matches` vs `revenue_report` `orders` | **Different metric on purpose** | Placed orders vs completed orders. Filter `search_orders` by status to compare. |
| Seller review score | `seller_performance` vs `delivery_performance(seller)` | **Different metric on purpose** | Completed orders vs delivered orders. The populations differ by orders not yet delivered. |
| Revenue by payment method | `revenue_report(payment_method)` vs any other breakdown | **Different metric on purpose** | `payment_value`, not `gross_revenue`; see above. |
| Customer orders vs value | `find_customer` `orders` vs `lifetime_value` | **Different populations on purpose (approved)** | Placed vs completed. |

## Where each tool stands

| Tool | Metrics |
|---|---|
| `revenue_report` | month/state: `orders`, `item_revenue`, `freight`, `gross_revenue` (as `revenue`), `avg_order_value`; order totals given. category/seller: same fields, allocated per item; no order total. payment_method: `orders`, `payment_value` (as `revenue`); no order total. |
| `list_categories` | `products`, `units_sold`, `item_revenue` (as `revenue`), `avg_review` |
| `seller_performance` | `orders`, `item_revenue` (as `revenue`), `avg_review`, `avg_days_late` |
| `delivery_performance` | `orders`, `late_orders`, `late_rate`, `avg_days_late`, `avg_delivery_days`, `avg_review` over delivered orders |
| `search_orders` | `total_matches` over placed orders; the review filter uses the order's score |
| `find_customer` | `orders` (placed), `lifetime_value` (completed), `avg_review` (completed) |
| `get_order` | the order as placed: `item_total`, `shipment_total` (freight), `total`, and its review by the policy |
| `get_product`, `search_products` | `units_sold`, `revenue` (item revenue), and `orders`, `avg_review`, `avg_days_late`, all over completed orders |
