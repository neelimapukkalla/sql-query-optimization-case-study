/* ============================================================
   Query Optimization Case Study — Order Reporting Query
   T-SQL / SQL Server
   Fully reproducible: run this script top to bottom.
   ============================================================ */

-- ============================================================
-- 01. SCHEMA
-- ============================================================

CREATE TABLE Customers (
    CustomerID   INT IDENTITY(1,1) PRIMARY KEY,
    CustomerName VARCHAR(100) NOT NULL,
    Region       VARCHAR(20)  NOT NULL
);

CREATE TABLE Orders (
    OrderID      INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID   INT NOT NULL REFERENCES Customers(CustomerID),
    OrderDate    DATE NOT NULL,
    Status       VARCHAR(20) NOT NULL,
    WarehouseID  INT NOT NULL
);

CREATE TABLE OrderItems (
    OrderItemID  INT IDENTITY(1,1) PRIMARY KEY,
    OrderID      INT NOT NULL REFERENCES Orders(OrderID),
    ProductID    INT NOT NULL,
    Quantity     INT NOT NULL,
    UnitPrice    DECIMAL(10,2) NOT NULL
);


-- ============================================================
-- 02. SEED DATA
--     Reproduces the dataset used for the before/after numbers:
--     5,000 customers / 500,000 orders / ~1.25M order items
-- ============================================================

-- ---- 5,000 customers ----
;WITH Nums AS (
    SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Customers (CustomerName, Region)
SELECT
    'Customer_' + CAST(n AS VARCHAR(10)),
    CASE n % 4 WHEN 0 THEN 'North' WHEN 1 THEN 'South' WHEN 2 THEN 'East' ELSE 'West' END
FROM Nums;

-- ---- 500,000 orders, spread across a 2-year date range ----
;WITH Nums AS (
    SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c
)
INSERT INTO Orders (CustomerID, OrderDate, Status, WarehouseID)
SELECT
    1 + ABS(CHECKSUM(NEWID())) % 5000,
    DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 730, '2024-01-01'),
    CASE ABS(CHECKSUM(NEWID())) % 4
        WHEN 0 THEN 'Pending' WHEN 1 THEN 'Shipped'
        WHEN 2 THEN 'Delivered' ELSE 'Cancelled' END,
    1 + ABS(CHECKSUM(NEWID())) % 10
FROM Nums;

-- ---- ~1.25M order items (1-4 line items per order) ----
;WITH Nums AS (
    SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c
),
LineCounts AS (
    SELECT n, 1 + ABS(CHECKSUM(NEWID())) % 4 AS ItemCount
    FROM Nums
)
INSERT INTO OrderItems (OrderID, ProductID, Quantity, UnitPrice)
SELECT
    lc.n,
    1 + ABS(CHECKSUM(NEWID())) % 2000,
    1 + ABS(CHECKSUM(NEWID())) % 10,
    CAST(5 + (ABS(CHECKSUM(NEWID())) % 49500) / 100.0 AS DECIMAL(10,2))
FROM LineCounts lc
CROSS APPLY (SELECT TOP (lc.ItemCount) 1 AS x FROM sys.all_objects) AS expand;

-- Sanity check row counts
SELECT 'Customers' AS TableName, COUNT(*) AS RowCount FROM Customers
UNION ALL SELECT 'Orders', COUNT(*) FROM Orders
UNION ALL SELECT 'OrderItems', COUNT(*) FROM OrderItems;


-- ============================================================
-- 03. BASELINE QUERY (BEFORE) — non-sargable predicate
-- ============================================================
-- Business need: "Show me all shipped orders in H1 2025, with
-- customer name and order total, highest value first."
--
-- This version pulls the date apart with functions to filter by
-- year/month. It reads naturally, but wrapping OrderDate in a
-- function means SQL Server can't seek an index on OrderDate —
-- it has to evaluate the function against every row, forcing a scan.

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    c.CustomerName,
    o.OrderID,
    o.OrderDate,
    o.Status,
    SUM(oi.Quantity * oi.UnitPrice) AS OrderTotal
FROM Orders o
JOIN Customers c   ON c.CustomerID = o.CustomerID
JOIN OrderItems oi ON oi.OrderID = o.OrderID
WHERE LEFT(CONVERT(VARCHAR(10), o.OrderDate, 120), 4) = '2025'
  AND MONTH(o.OrderDate) BETWEEN 1 AND 6
  AND o.Status = 'Shipped'
GROUP BY c.CustomerName, o.OrderID, o.OrderDate, o.Status
ORDER BY OrderTotal DESC;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

-- To capture the execution plan for this query: enable
-- "Include Actual Execution Plan" in SSMS (Ctrl+M) before running,
-- then save/screenshot the resulting plan (expect: Clustered Index
-- Scan on Orders).


-- ============================================================
-- 04. INDEXES + OPTIMIZED QUERY (AFTER)
-- ============================================================

CREATE INDEX IX_Orders_Status_OrderDate
    ON Orders (Status, OrderDate)   -- Status: equality predicate (leading column)
                                     -- OrderDate: range predicate (second column,
                                     --   since range predicates should trail equality
                                     --   predicates in a composite index)
    INCLUDE (CustomerID);           -- included so the join to Customers doesn't
                                     -- require a separate key lookup

CREATE INDEX IX_OrderItems_OrderID
    ON OrderItems (OrderID)
    INCLUDE (Quantity, UnitPrice);  -- included so the join + aggregation can be
                                     -- satisfied entirely from the index

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Sargable rewrite: plain range comparison, no function wrapping OrderDate
SELECT
    c.CustomerName,
    o.OrderID,
    o.OrderDate,
    o.Status,
    SUM(oi.Quantity * oi.UnitPrice) AS OrderTotal
FROM Orders o
JOIN Customers c   ON c.CustomerID = o.CustomerID
JOIN OrderItems oi ON oi.OrderID = o.OrderID
WHERE o.OrderDate >= '2025-01-01' AND o.OrderDate < '2025-07-01'
  AND o.Status = 'Shipped'
GROUP BY c.CustomerName, o.OrderID, o.OrderDate, o.Status
ORDER BY OrderTotal DESC;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

-- Expected plan after this change: Index Seek on
-- IX_Orders_Status_OrderDate (both Status and the OrderDate range
-- used directly in the seek predicate), Index Seek on
-- IX_OrderItems_OrderID for the join — no full table scan.


-- ============================================================
-- 05. RESULTS FROM THIS RUN
--     Captured on: SQL Server Express (local instance), via SSMS
-- ============================================================
--
-- BEFORE (non-sargable):
--   Table 'Orders'.     Scan count 1, Logical reads: 2,245  (Clustered Index Scan)
--   Table 'OrderItems'. Scan count 1, Logical reads: 5,270  (Clustered Index Scan)
--   Table 'Customers'.  Scan count 1, Logical reads: 25
--   CPU time = 156 ms.  Elapsed time = 366 ms.
--
-- AFTER (sargable + indexed):
--   Table 'Orders'.     Scan count 1, Logical reads: 85     (Index Seek)
--   Table 'OrderItems'. Scan count 1, Logical reads: 4,197  (Index Scan, covering nonclustered index)
--   Table 'Customers'.  Scan count 1, Logical reads: 25
--   CPU time = 94 ms.  Elapsed time = 173 ms.
--
-- RESULT: 52.7% faster elapsed time (2.1x speedup), 39.7% less CPU time,
--         96.2% fewer logical reads on Orders (2,245 -> 85).
--
-- Note: OrderItems shows an Index Scan rather than a Seek after the fix —
-- expected, since the query joins to OrderID rather than filtering on it
-- directly, so SQL Server scans the narrow covering index instead of the
-- wide clustered table. Still a meaningful improvement over the original
-- clustered-index scan, just not a seek.
