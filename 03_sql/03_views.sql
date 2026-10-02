-- ============================================================
--  OLIST RETAIL ANALYTICS — ANALYTICAL VIEWS
--  Script:  03_views.sql  |  Version: SQL Server / T-SQL
--  Author:  Julian        |  Created: 2026
-- ============================================================
--  PURPOSE:
--  Views encapsulate reusable business logic so that:
--    · Analytical queries (04_analysis.sql) stay clean and readable
--    · Power BI connects to views, not raw tables
--    · Cleaning decisions (nulls, aggregations, joins) are
--      applied once here and inherited everywhere
--
--  VIEW INVENTORY:
--    1. v_delivered_orders      → base filter: delivered orders only
--    2. v_order_financials      → revenue per order (multi-payment safe)
--    3. v_delivery_performance  → promised vs actual delivery dates
--    4. v_product_catalog       → products with English category names
--    5. v_customer_orders       → customer-level order history (uses unique_id)
--    6. v_rfm_base              → RFM inputs per customer (ready for scoring)
--    7. v_seller_performance    → seller-level metrics
--    8. v_review_summary        → review scores joined to orders
-- ============================================================

USE olist_retail;
GO


-- ============================================================
-- VIEW 1 — v_delivered_orders
-- ============================================================
-- Base filter used by almost every analytical query.
-- Only 'delivered' orders are meaningful for RFM, revenue,
-- and delivery analysis. Other statuses (canceled, unavailable,
-- processing) are excluded from customer behavior analysis.
--
-- Cleaning decision applied:
--   · order_status = 'delivered' filter
--   · order_delivered_customer_date IS NOT NULL (2,965 nulls excluded)
-- ============================================================

CREATE OR ALTER VIEW v_delivered_orders AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    c.customer_unique_id,   -- TRUE customer identifier for RFM
    c.customer_state,
    c.customer_city,
    c.customer_zip_code
FROM orders o
INNER JOIN customers c
        ON o.customer_id = c.customer_id
WHERE o.order_status                  = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;
GO


-- ============================================================
-- VIEW 2 — v_order_financials
-- ============================================================
-- Solves the multi-payment problem documented in Quality Report:
-- payments (103,886 rows) > orders (99,441 rows) because some
-- orders use multiple payment methods.
--
-- This view aggregates payment_value at order level BEFORE
-- any join, making it safe to use directly in revenue analysis.
-- Never join order_payments directly to orders without this view.
--
-- Metrics per order:
--   · total_revenue        → sum of all payment methods
--   · payment_installments → max installments used
--   · payment_types_used   → count of distinct payment methods
--   · primary_payment_type → payment type with highest value
-- ============================================================

CREATE OR ALTER VIEW v_order_financials AS

WITH payment_aggregated AS (
    SELECT
        order_id,
        SUM(payment_value)              AS total_revenue,
        MAX(payment_installments)       AS payment_installments,
        COUNT(DISTINCT payment_type)    AS payment_types_used
    FROM order_payments
    GROUP BY order_id
),

-- Identify the primary payment type (highest value per order)
payment_primary AS (
    SELECT
        order_id,
        payment_type                    AS primary_payment_type,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY payment_value DESC
        )                               AS rn
    FROM order_payments
)

SELECT
    pa.order_id,
    pa.total_revenue,
    pa.payment_installments,
    pa.payment_types_used,
    pp.primary_payment_type
FROM payment_aggregated pa
INNER JOIN payment_primary pp
        ON pa.order_id = pp.order_id
       AND pp.rn = 1;
GO


-- ============================================================
-- VIEW 3 — v_delivery_performance
-- ============================================================
-- Core view for Business Question 3 (delivery vs promise).
-- Calculates delivery delay in days for every delivered order.
--
-- Key calculated columns:
--   · days_to_deliver     → actual calendar days from purchase to delivery
--   · days_promised       → promised lead time in days
--   · delay_days          → positive = late, negative = early
--   · is_late             → binary flag for SLA compliance analysis
--   · delay_bucket        → bucketed delay for distribution analysis
-- ============================================================

CREATE OR ALTER VIEW v_delivery_performance AS
SELECT
    o.order_id,
    o.customer_unique_id,
    o.customer_state,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,

    -- Actual days from purchase to delivery
    DATEDIFF(DAY,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date)            AS days_to_deliver,

    -- Promised lead time in days
    DATEDIFF(DAY,
        o.order_purchase_timestamp,
        o.order_estimated_delivery_date)            AS days_promised,

    -- Delay: positive = arrived late, negative = arrived early
    DATEDIFF(DAY,
        o.order_estimated_delivery_date,
        o.order_delivered_customer_date)            AS delay_days,

    -- Binary SLA flag
    CASE
        WHEN o.order_delivered_customer_date
           > o.order_estimated_delivery_date THEN 1
        ELSE 0
    END                                             AS is_late,

    -- Delay bucket for distribution charts in Power BI
    CASE
        WHEN DATEDIFF(DAY,
                o.order_estimated_delivery_date,
                o.order_delivered_customer_date) <= -7  THEN 'Early 7+ days'
        WHEN DATEDIFF(DAY,
                o.order_estimated_delivery_date,
                o.order_delivered_customer_date) <= -1  THEN 'Early 1-6 days'
        WHEN DATEDIFF(DAY,
                o.order_estimated_delivery_date,
                o.order_delivered_customer_date) =  0   THEN 'On Time'
        WHEN DATEDIFF(DAY,
                o.order_estimated_delivery_date,
                o.order_delivered_customer_date) <= 7   THEN 'Late 1-7 days'
        WHEN DATEDIFF(DAY,
                o.order_estimated_delivery_date,
                o.order_delivered_customer_date) <= 14  THEN 'Late 8-14 days'
        ELSE                                             'Late 15+ days'
    END                                             AS delay_bucket

FROM v_delivered_orders o;
GO


-- ============================================================
-- VIEW 4 — v_product_catalog
-- ============================================================
-- Resolves the Portuguese → English category translation.
-- All downstream queries use this view instead of joining
-- products + translation manually every time.
--
-- Cleaning decision applied:
--   · LEFT JOIN to translation preserves products with null
--     category (they get NULL in category_name_english)
--   · COALESCE provides a display-safe fallback label
-- ============================================================

CREATE OR ALTER VIEW v_product_catalog AS
SELECT
    p.product_id,
    p.product_category_name                             AS category_portuguese,
    COALESCE(t.category_name_english, 'Uncategorized') AS category_english,
    p.product_name_length,
    p.product_description_length,
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM products p
LEFT JOIN product_category_translation t
       ON p.product_category_name = t.category_name_portuguese;
GO


-- ============================================================
-- VIEW 5a — v_order_review_agg  (supporting view)
-- ============================================================
-- CLEANING DECISION — second-layer review deduplication:
-- The earlier ROW_NUMBER() PARTITION BY review_id (applied during
-- data load) only removed rows sharing the same review_id.
-- It did NOT catch orders that legitimately received two distinct
-- review_id records for the same order_id (~268 orders in this
-- dataset — customer was re-surveyed, or submitted feedback twice).
--
-- Any LEFT JOIN straight to order_reviews at order-grain will
-- silently duplicate those ~268 orders. Exactly like payments,
-- reviews must be aggregated to ONE row per order_id before
-- joining into any order-level view.
--
-- Aggregation rule: keep the MOST RECENT review per order
-- (latest review_creation_date) — this reflects the customer's
-- final/updated sentiment rather than an arbitrary first record.
-- ============================================================

CREATE OR ALTER VIEW v_order_review_agg AS
WITH ranked_reviews AS (
    SELECT
        order_id,
        review_id,
        review_score,
        review_creation_date,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_creation_date DESC
        ) AS rn
    FROM order_reviews
)
SELECT
    order_id,
    review_id,
    review_score,
    review_creation_date
FROM ranked_reviews
WHERE rn = 1;
GO


-- ============================================================
-- VIEW 5 — v_customer_orders
-- ============================================================
-- Customer-level order history using customer_unique_id.
-- This is the foundation for RFM and cohort analysis.
--
-- ⚠️ Uses customer_unique_id (not customer_id) — critical
-- distinction documented in DDL and Quality Report.
-- customer_id changes per order; unique_id is the real person.
--
-- Joins: delivered orders + financials + deduplicated reviews
-- ============================================================

CREATE OR ALTER VIEW v_customer_orders AS
SELECT
    -- Customer identifiers
    do_.customer_unique_id,
    do_.customer_state,

    -- Order details
    do_.order_id,
    do_.order_purchase_timestamp,
    do_.order_delivered_customer_date,

    -- Financial metrics (from aggregated view — multi-payment safe)
    f.total_revenue,
    f.primary_payment_type,
    f.payment_installments,

    -- Satisfaction signal (LEFT JOIN — 217 orders have no review;
    -- source is now deduplicated to 1 row per order_id)
    r.review_score,
    r.review_creation_date,

    -- Delivery performance
    dp.delay_days,
    dp.is_late,
    dp.delay_bucket

FROM v_delivered_orders         do_
INNER JOIN v_order_financials   f   ON do_.order_id = f.order_id
LEFT  JOIN v_order_review_agg   r   ON do_.order_id = r.order_id
INNER JOIN v_delivery_performance dp ON do_.order_id = dp.order_id;
GO


-- ============================================================
-- VIEW 6 — v_rfm_base
-- ============================================================
-- Computes raw RFM inputs per customer, ready for scoring.
-- Scoring (NTILE quintiles) is done in 04_analysis.sql because
-- views cannot reference themselves and window scoring needs
-- the full dataset to compute percentiles correctly.
--
-- RFM definitions for this dataset:
--   · Recency    → days since last delivered order (lower = better)
--   · Frequency  → count of distinct delivered orders
--   · Monetary   → total revenue across all delivered orders
--
-- Reference date: MAX(order_purchase_timestamp) from the dataset.
-- We use the dataset's own max date — not GETDATE() — to avoid
-- RFM scores degrading as real time passes beyond the data window.
-- ============================================================

CREATE OR ALTER VIEW v_rfm_base AS

WITH reference_date AS (
    -- Anchor date: latest purchase in the dataset + 1 day
    SELECT DATEADD(DAY, 1, MAX(order_purchase_timestamp)) AS ref_date
    FROM orders
    WHERE order_status = 'delivered'
),

customer_metrics AS (
    SELECT
        co.customer_unique_id,
        co.customer_state,
        MAX(co.order_purchase_timestamp)    AS last_purchase_date,
        COUNT(DISTINCT co.order_id)         AS frequency,
        SUM(co.total_revenue)               AS monetary,
        AVG(co.review_score)                AS avg_review_score,
        SUM(co.is_late)                     AS late_deliveries_received
    FROM v_customer_orders co
    GROUP BY
        co.customer_unique_id,
        co.customer_state
)

SELECT
    cm.customer_unique_id,
    cm.customer_state,
    cm.last_purchase_date,
    cm.frequency,
    ROUND(cm.monetary, 2)                   AS monetary,
    ROUND(cm.avg_review_score, 2)           AS avg_review_score,
    cm.late_deliveries_received,

    -- Recency in days (lower = more recent = better customer)
    DATEDIFF(DAY, cm.last_purchase_date, rd.ref_date) AS recency_days

FROM customer_metrics cm
CROSS JOIN reference_date rd;
GO


-- ============================================================
-- VIEW 7 — v_seller_performance
-- ============================================================
-- Seller-level aggregated metrics for marketplace analysis.
-- Answers: which sellers drive volume vs satisfaction vs delays?
-- ============================================================

CREATE OR ALTER VIEW v_seller_performance AS
SELECT
    oi.seller_id,
    s.seller_state,
    s.seller_city,

    -- Volume metrics
    COUNT(DISTINCT oi.order_id)             AS total_orders,
    COUNT(oi.order_item_id)                 AS total_items_sold,

    -- Revenue metrics
    ROUND(SUM(oi.price), 2)                 AS total_revenue,
    ROUND(AVG(oi.price), 2)                 AS avg_item_price,
    ROUND(SUM(oi.freight_value), 2)         AS total_freight_charged,

    -- Satisfaction metrics (LEFT JOIN — not all orders have reviews)
    ROUND(AVG(CAST(r.review_score AS FLOAT)), 2) AS avg_review_score,
    SUM(CASE WHEN r.review_score <= 2
             THEN 1 ELSE 0 END)             AS low_score_count,  -- scores 1-2

    -- Delivery metrics
    ROUND(AVG(CAST(dp.delay_days AS FLOAT)), 1)  AS avg_delay_days,
    SUM(dp.is_late)                         AS late_orders,
    ROUND(
        100.0 * SUM(dp.is_late)
              / NULLIF(COUNT(DISTINCT oi.order_id), 0)
    , 1)                                    AS late_pct

FROM order_items             oi
INNER JOIN sellers           s   ON oi.seller_id   = s.seller_id
INNER JOIN v_delivered_orders do_ ON oi.order_id   = do_.order_id
LEFT  JOIN order_reviews     r   ON oi.order_id    = r.order_id
INNER JOIN v_delivery_performance dp ON oi.order_id = dp.order_id
GROUP BY
    oi.seller_id,
    s.seller_state,
    s.seller_city;
GO


-- ============================================================
-- VIEW 8 — v_review_summary
-- ============================================================
-- Review scores joined to order and delivery context.
-- Used for correlation analysis: does late delivery → low score?
-- ============================================================

CREATE OR ALTER VIEW v_review_summary AS
SELECT
    r.review_id,
    r.order_id,
    r.review_score,
    r.review_creation_date,

    -- Delivery context for correlation
    dp.delay_days,
    dp.is_late,
    dp.delay_bucket,
    dp.days_to_deliver,

    -- Customer and financial context
    do_.customer_unique_id,
    do_.customer_state,
    f.total_revenue,
    f.primary_payment_type

FROM v_order_review_agg         r   -- deduplicated: 1 row per order_id
INNER JOIN v_delivered_orders   do_ ON r.order_id = do_.order_id
INNER JOIN v_delivery_performance dp  ON r.order_id = dp.order_id
INNER JOIN v_order_financials   f   ON r.order_id = f.order_id;
GO


-- ============================================================
-- VALIDATION — verify all views return data
-- ============================================================

SELECT 'v_delivered_orders'    AS view_name, COUNT(*) AS row_count FROM v_delivered_orders
UNION ALL
SELECT 'v_order_financials',                 COUNT(*) FROM v_order_financials
UNION ALL
SELECT 'v_delivery_performance',             COUNT(*) FROM v_delivery_performance
UNION ALL
SELECT 'v_product_catalog',                  COUNT(*) FROM v_product_catalog
UNION ALL
SELECT 'v_order_review_agg',                 COUNT(*) FROM v_order_review_agg
UNION ALL
SELECT 'v_customer_orders',                  COUNT(*) FROM v_customer_orders
UNION ALL
SELECT 'v_rfm_base',                         COUNT(*) FROM v_rfm_base
UNION ALL
SELECT 'v_seller_performance',               COUNT(*) FROM v_seller_performance
UNION ALL
SELECT 'v_review_summary',                   COUNT(*) FROM v_review_summary;

-- Expected approximate counts:
-- v_delivered_orders      → 96,470
-- v_order_financials      → 99,440  (1 order has no payment record)
-- v_delivery_performance  → 96,470
-- v_product_catalog       → 32,951
-- v_order_review_agg      → ~98,150 (deduplicated: 1 row per order_id)
-- v_customer_orders       → 96,470  (now matches v_delivered_orders exactly)
-- v_rfm_base              → unique customers (1 row per customer_unique_id)
-- v_seller_performance    → ~2,970  (sellers with at least 1 delivered order)
-- v_review_summary        → matches delivered orders with a review

-- ============================================================
-- END OF VIEWS
-- Next script: 04_analysis.sql → CTE-based business queries
-- ============================================================
