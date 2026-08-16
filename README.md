# Query Optimization Case Study: Order Reporting Query

**A before/after look at diagnosing and fixing a slow order-reporting query — 45% faster (1.8x speedup) on a 500K-order dataset, by fixing a non-sargable predicate and adding two targeted indexes.**

## The scenario

A common reporting request in order/warehouse systems: *"Show me all shipped orders in the first half of 2025, with customer name and order total, ranked highest value first."*

This kind of report gets run often — by finance, by ops, by customer service — and it's exactly the kind of query that quietly gets slower and slower as an orders table grows, until someone notices reports are timing out.

## Dataset used for this demo

To make the before/after comparison concrete and measurable, I built a realistic order-management schema and populated it at a meaningful scale:

| Table | Rows |
|---|---|
| Customers | 5,000 |
| Orders | 500,000 (spanning a 2-year date range) |
| OrderItems | ~1,250,000 (1–4 line items per order) |

Schema, seed logic, and both query versions are in [`warehouse_query_optimization.sql`](./warehouse_query_optimization.sql).

## The problem

The original query filtered orders by year and month using string/date functions wrapped around the `OrderDate` column:

```sql
WHERE LEFT(CONVERT(VARCHAR(10), o.OrderDate, 120), 4) = '2025'
  AND MONTH(o.OrderDate) BETWEEN 1 AND 6
  AND o.Status = 'Shipped'
```

This reads naturally and gives the correct result — but it's **non-sargable**: wrapping a column in a function means the query optimizer can't use an index to seek directly to the matching rows. It has to evaluate the function against *every row* in the table first, which forces a full scan regardless of what indexes exist.

**Execution plan:** Clustered Index Scan across the full Orders table (500,000 rows read to return 50).

**Measured runtime:** ~385 ms.

## The fix

Two changes, neither of which touched the business logic or the result set:

**1. Rewrote the predicate to be sargable** — a plain range comparison instead of a function wrapping the column:

```sql
WHERE o.OrderDate >= '2025-01-01' AND o.OrderDate < '2025-07-01'
  AND o.Status = 'Shipped'
```

**2. Added two targeted indexes**, chosen to match how this query actually filters and joins:

```sql
CREATE INDEX IX_Orders_Status_OrderDate
    ON Orders (Status, OrderDate)
    INCLUDE (CustomerID);

CREATE INDEX IX_OrderItems_OrderID
    ON OrderItems (OrderID)
    INCLUDE (Quantity, UnitPrice);
```

**Execution plan after the fix:** Index Seek on `IX_Orders_Status_OrderDate` (both the status filter and the date range are used directly in the seek), Index Seek on `IX_OrderItems_OrderID` for the join — no more full table scan.

**Measured runtime:** ~210 ms.

## Result

| | Before | After |
|---|---|---|
| Runtime | 385.5 ms | 210.5 ms |
| Plan | Full scan (Orders) | Index seek (both tables) |
| Rows scanned to return 50 | ~500,000 | Only matching rows |

**45% faster, a 1.8x speedup — same query, same result, no application changes.**

## Why this pattern matters beyond this one query

The gap between a scan and a seek doesn't stay this size — it *grows* with the table. On 500K rows the difference is already noticeable; on a multi-million-row orders table (which a busy order/shipment system reaches within a year or two of real traffic), the same non-sargable pattern is often the exact reason a report that used to run in under a second starts timing out — especially once several people are running it at the same time.

This is also one of the most common patterns I look for first when someone brings me a "our report got slow" problem: check the `WHERE` clause for functions wrapped around indexed columns before assuming the fix has to be structural or expensive.

---

*Schema and dataset built specifically for this case study to demonstrate the diagnostic process clearly, at a scale similar to what I work with day-to-day maintaining reporting queries for a production ERP system (Warehouse Management, Sales Orders, Shipment modules).*
