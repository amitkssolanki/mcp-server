# The MCP truth harness

How do you know an AI interface over business data is telling the truth?
You work the answer out a second way, from the source, without using any of
the code that produced the first answer. Then you compare them, and you keep
comparing them on every change.

```bash
bin/rails eval:run            # questions, invariants, reconciliation, regressions
bin/rails test                # oracle self-tests and the HTTP/MCP boundary tests
```

`eval:run` exits non-zero if any check fails or any known bug goes uncaught.
It prints a report and writes JSON to `tmp/eval/latest.json` (`OUT=` to
change it). Snapshots kept as evidence live in `eval/reports/`.

## What runs

```
             raw Olist CSVs
                   |
          +--------+--------+
          |                 |
   eval/oracle/       lib/olist/importer.rb
   (plain Ruby)             |
          |             PostgreSQL
          |                 |
          |         StoreMcp server  <-- JSON-RPC tools/call, as a client sends it
          |                 |
       expected          actual
          +--------+--------+
                   |
              comparator  ->  pass / fail  ->  triage in eval/findings.yml
```

| Part | What it proves |
|---|---|
| **Questions** (`eval/questions/*.yml`, 35) | A tool's structured answer to a canonical question equals the oracle's, field by field, to the cent. Each question names the risk it exists to catch. |
| **Invariants** (`eval/invariants/invariants.rb`, 9) | Properties the tools must satisfy among themselves, with no oracle: partitions add up, one named metric has one value across tools, overlapping buckets never present an additive order total, narrowing a filter never counts more, adjacent date windows add up, a one-page listing has exactly `total_matches` distinct rows, and a customer lookup resolves an exact email or nobody. About 150 seeded random cases. |
| **Differential** (`eval/invariants/differential.rb`, 6 checks, 200 cases) | Seeded random arguments to six tools (filters, date windows, customers, products, seller states), each answer compared with the oracle. The question bank asks what somebody thought of; this asks what nobody did. |
| **Reconciliation** (`eval/reconciliation.rb`) | The import landed every source row and every real: row counts and value sums, CSV against Postgres. |
| **Regressions** (`eval/regressions/`, 12) | Known-bad implementations are swapped in and must be caught by a named check: 3 reconstructed historical bugs and 9 pre-fix versions of the tools this harness fixed. This is the evidence that the harness can see the bugs it claims to. |
| **Boundary tests** (`test/integration/mcp_boundary_test.rb`, 16) | The remote endpoint's trust boundary through the real stack: 401 plus `resource_metadata`, read vs write scope, the write-disabled deployment, discovery, dynamic registration, host checks and store scoping. |

## Independence

The oracle (`eval/oracle/`) reads the CSVs with Ruby's CSV library and
computes every metric as a fold over per-order fact records. It never uses:

- the importer (`lib/olist/importer.rb`), its ID mapping or its timestamp parser
- Spree models, ActiveRecord or any SQL (a test asserts that it issues no queries)
- the tools' SQL or anything in `app/mcp/`

It is not a Ruby translation of the SQL. The tools aggregate joined rows in
Postgres. The oracle resolves each order once (status, customer state, score
by the review policy, lateness, items) and then folds over those records.
Fan-out bugs happen when joins multiply rows; the oracle has no joins to
multiply.

**Shared assumptions**, which can't be avoided and are stated so they can be
questioned:

1. **The input files.** Both paths read the same CSVs. A defect in the source
   data is invisible to the harness.
2. **The definitions** in `docs/METRICS.md`. The two sides must agree on what
   "revenue" means before they can be compared. The harness tests that the
   tools implement the definitions, not that the definitions are the right
   business choices.
3. **Identity conventions**, used only to address the same thing on both sides
   and never to compute a value: customer emails are
   `<customer_unique_id>@olist.invalid`; category names are compared as
   underscore slugs ("Health Beauty" = `health_beauty`).
4. **The Olist timestamps are taken as-is** (Brazil local, no offset) on both
   sides.

The oracle is tested against a hand-built five-order dataset
(`test/fixtures/olist_mini`) whose expected values are worked out by hand.
That tests the tester.

## Reading a failure

Every failing check is looked up in `eval/findings.yml`, which records what
was wrong (`tool_bug`, `definition_gap`, `import_bug`, `oracle_bug`,
`security`) and what was decided (`fix`, `definition`, `separate`,
`out_of_scope`). A failure that no finding explains is reported as
**UNTRIAGED**: a new problem nobody has looked at yet.

## Determinism

The tool-level harness is deterministic. The fingerprint at the end of the
report hashes every check's id, status and diffs, and every regression
verdict, leaving out timings. Two runs on the same data, code and seed print
the same fingerprint. `SEED=` changes the random inputs; the seed is in every
report.

## Regressions: provenance

The original buggy code for the historical bugs is not in git; it predates
the first commit. They are **reconstructed**, and each says how faithfully:

| Regression | Provenance |
|---|---|
| H1 category revenue fan-out (42x) | Rebuilt from the article's description. On the pre-fix product counters it reproduces the article's R$52,545,084 exactly. |
| H2 seller average fan-out | Rebuilt from the article. Reproduces its seller at 3.81 reported as 2.57 exactly. |
| H3 33 payments silently dropped | **Simulated effect.** The original index/column combination is not recoverable; the obvious reconstruction drops 2,200 rows, not 33. The harness deletes 33 repeat payments inside a rolled-back transaction. |

The pre-fix regressions (P1-P9, `eval/regressions/pre_fix/`) are different:
they are the tools, and the importer's product-counter SQL, **verbatim from
git at 9fa9b02**, the code the full baseline ran against. They keep each
fix from quietly coming undone.

A regression counts as caught only when one of its named checks fails
*differently* from how it fails on the unmodified system. So the harness
could prove it caught the historical bugs even before any fix landed, when
those checks were already failing.

## Evidence

| Report | State |
|---|---|
| `eval/reports/01-before-fixes.txt` | Day 1 harness (13 questions) against the unfixed tools |
| `eval/reports/01b-before-fixes-full.txt` | Full harness against the unfixed tools: the like-for-like baseline |
| `eval/reports/02-after-fixes.txt` | Full harness after the fixes |

Each has a JSON twin with every check's arguments, expected and actual
values, and diffs.

## Running it

It needs Postgres, the eight Olist CSVs in `db/olist/` (`bin/olist-fetch`,
checksum-verified) and a test database with the import:

```bash
bin/olist-fetch
RAILS_ENV=test bin/rails db:create db:schema:load db:seed olist:import
RAILS_ENV=test bin/rails test
RAILS_ENV=test bin/rails eval:run
```

`SEED=`, `CASES=` (seeded cases per invariant, default 25) and
`REGRESSIONS=0` are optional. CI (`.github/workflows/verify.yml`) runs exactly
these steps on every push and fails on any failing check, uncaught
regression or failing test. That was checked by putting the pre-fix
`find_customer` back and running the CI pipeline command: it exits 1 and
attributes every failure to F1, F2 or F9.

**CI runtime is about 8 minutes**, measured on the first run: 3m20s to import
99,441 orders, 3m16s for the harness, 7s for the tests, and the rest setting
up Ruby and Postgres. That is over the 5-minute target, and deliberately
not optimised. The import is part of what is verified (the reconciliation
audits it), so caching an imported database would stop testing the importer.
Cutting cases or data would weaken the claim the run exists to support. CI
printed the same fingerprint as local runs (`f4841a48894b268d`) on a
different machine and a fresh database.
