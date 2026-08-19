# Query Optimization Case Study: Order Reporting Query

**A reproducible before/after case study on diagnosing and fixing a slow order-reporting query — measured on SQL Server Express with SSMS: 52.7% faster (366 ms → 173 ms, a 2.1x speedup) and 96% fewer logical reads on the driving table, by fixing a non-sargable predicate and adding two targeted indexes.**

## The scenario

A common reporting request in order/warehouse systems: *"Show me all shipped orders in the first half of 2025, with customer name and order total, ranked highest value first."*

This kind of report gets run often — by finance, by ops, by customer service — and it's exactly the kind of query that quietly gets slower as an orders table grows, until someone notices reports are timing out.

## Reproducing this yourself

Everything needed to reproduce these results is in [`warehouse_query_optimization.sql`](./warehouse_query_optimization.sql) — schema, data generation, and both query versions, in order:

1. **Section 01** — creates the schema
2. **Section 02** — generates the dataset: 5,000 customers, 500,000 orders (2-year date range), ~1.25M order items
3. **Section 03** — runs the baseline (non-sargable) query with `SET STATISTICS IO/TIME ON`
4. **Section 04** — adds the two indexes and runs the optimized query, same statistics enabled
5. **Section 05** — a template for recording your own logical-reads / CPU-time / elapsed-time numbers from your run

Run the whole script top to bottom in SSMS or Azure Data Studio against a scratch database — no external dependencies.

## The problem

The original query filtered orders by year and month using string/date functions wrapped around the `OrderDate` column:

```sql
WHERE LEFT(CONVERT(VARCHAR(10), o.OrderDate, 120), 4) = '2025'
  AND MONTH(o.OrderDate) BETWEEN 1 AND 6
  AND o.Status = 'Shipped'
```

This reads naturally and gives the correct result — but it's **non-sargable**: wrapping a column in a function means the query optimizer can't use an index to seek directly to matching rows. The function-wrapped column prevents SQL Server from efficiently seeking to the required date range, making a scan much more likely for this access pattern.

**Actual plan (captured via SSMS, Ctrl+M):** Clustered Index Scan on Orders.

![Before: Clustered Index Scan](./images/before-execution-plan.png)

**Actual measured numbers** (`SET STATISTICS IO/TIME ON`, SQL Server Express, local instance):

| | Orders | OrderItems | Customers |
|---|---|---|---|
| Logical reads | 2,245 | 5,270 | 25 |

CPU time = 156 ms, elapsed time = 366 ms.

![Before: STATISTICS IO/TIME output](./images/before-statistics.png)

## The fix

Two changes, neither of which touched the business logic or the result set:

**1. Rewrote the predicate to be sargable** — a plain range comparison instead of a function wrapping the column:

```sql
WHERE o.OrderDate >= '2025-01-01' AND o.OrderDate < '2025-07-01'
  AND o.Status = 'Shipped'
```

**2. Added two targeted indexes**, chosen to match how this query filters and joins:

```sql
CREATE INDEX IX_Orders_Status_OrderDate
    ON Orders (Status, OrderDate)
    INCLUDE (CustomerID);

CREATE INDEX IX_OrderItems_OrderID
    ON OrderItems (OrderID)
    INCLUDE (Quantity, UnitPrice);
```

**Why this column order:** `Status` is an equality predicate, so it leads the composite index; `OrderDate` is a range predicate, so it comes second (range predicates should trail equality predicates in a composite index, otherwise the range breaks the seek early). `CustomerID` is included, not keyed, purely to avoid a separate key lookup when joining to `Customers`.

**Actual plan after the fix:** Index Seek on `IX_Orders_Status_OrderDate` — both the status filter and the date range are used directly in the seek. `OrderItems` shows an **Index Scan** (not a seek) on the nonclustered covering index `IX_OrderItems_OrderID` — this is expected, since the query joins to `OrderID` rather than filtering on it directly, so SQL Server scans the narrow covering index instead of the wide clustered table. That's still a large improvement over the original clustered-index scan, just not a seek, and it's worth understanding *why* rather than assuming every fix produces a seek everywhere.

![After: Index Seek](./images/after-execution-plan.png)

**Actual measured numbers:**

| | Orders | OrderItems | Customers |
|---|---|---|---|
| Logical reads | 85 | 4,197 | 25 |

CPU time = 94 ms, elapsed time = 173 ms.

![After: STATISTICS IO/TIME output](./images/after-statistics.png)

## Result

| | Before | After | Change |
|---|---|---|---|
| Elapsed time | 366 ms | 173 ms | **52.7% faster (2.1x speedup)** |
| CPU time | 156 ms | 94 ms | 39.7% faster |
| Orders logical reads | 2,245 | 85 | 96.2% fewer reads |
| Total logical reads (all tables) | 7,540 | 4,307 | 42.9% fewer reads |
| Orders plan | Clustered Index Scan | Index Seek | |

These are real numbers captured from a local SQL Server Express instance using `SET STATISTICS IO/TIME ON` and SSMS's actual execution plan — not estimates. Full reproduction steps are in [`warehouse_query_optimization.sql`](./warehouse_query_optimization.sql).

## Skills demonstrated

- T-SQL
- SQL Server query optimization
- SARGability / sargable predicate design
- Execution plan analysis (Index Seek vs. Index Scan)
- Composite index design and column ordering
- Covering indexes (`INCLUDE` columns)
- `SET STATISTICS IO / TIME` for query diagnostics
- JOIN and `GROUP BY` optimization
- Query performance benchmarking methodology

## Why this pattern matters beyond this one query

The gap between a scan and a seek doesn't stay this size — it grows with the table. On 500K rows the difference is already meaningful; on a multi-million-row orders table (which a busy order/shipment system reaches within a year or two of real traffic), this same non-sargable pattern is often the exact reason a report that used to run in under a second starts timing out — especially once several people run it concurrently.

This is one of the first things I check when someone brings me a "our report got slow" problem: look for functions wrapped around indexed columns in the `WHERE` clause before assuming the fix has to be structural or expensive.

---

*Schema and dataset built specifically for this case study to demonstrate the diagnostic process clearly, at a scale similar to what I work with day-to-day maintaining reporting queries for a production ERP system (Warehouse Management, Sales Orders, Shipment modules).*
