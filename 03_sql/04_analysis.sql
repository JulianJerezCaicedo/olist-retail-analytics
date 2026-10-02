-- ============================================================
--  OLIST RETAIL ANALYTICS — BUSINESS ANALYSIS QUERIES
--  Script:  04_analysis.sql  |  Version: SQL Server / T-SQL
--  Author:  Julian          |  Created: 2026
-- ============================================================
--  PURPOSE:
--  Six business questions, each answered with a self-contained
--  query built on the views from 03_views.sql. Every query uses
--  CTEs, and most use window functions — this is the centerpiece
--  of your portfolio for technical interviews.
--
--  BUSINESS QUESTIONS:
--    BQ1 → Which customer segments drive 80% of revenue? (RFM + Pareto)
--    BQ2 → Which categories have the worst review rates and how
--           does that relate to repurchase?
--    BQ3 → What's the real vs promised delivery time, and how
--           does it impact satisfaction?
--    BQ4 → Which sellers show cancellation/delay patterns that
--           hurt customer experience?
--    BQ5 → Monthly revenue trend and seasonality
--    BQ6 → Customer cohort retention by first purchase month
-- ============================================================

USE olist_retail;
GO


-- ============================================================
-- BQ1 — Customer Segmentation: RFM + Pareto Analysis
-- ============================================================
-- "Which customer segments generate 80% of revenue?"
--
-- Technique: NTILE(5) for quintile scoring, CASE for segment
-- labeling, running SUM with window function for Pareto cutoff.
-- ============================================================

WITH rfm_scored AS (
    SELECT
        customer_unique_id,
        customer_state,
        recency_days,
        frequency,
        monetary,

        -- NTILE splits customers into 5 equal-sized buckets.
        -- For recency, LOWER days = BETTER, so we order ASC
        -- but assign 5 to the best bucket by reversing with 6-x.
        6 - NTILE(5) OVER (ORDER BY recency_days ASC)   AS r_score,
        NTILE(5) OVER (ORDER BY frequency ASC)          AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC)           AS m_score

    FROM v_rfm_base
),

rfm_segmented AS (
    SELECT
        *,
        CONCAT(r_score, f_score, m_score) AS rfm_cell,

        -- Segment labels based on combined RFM scores
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal Customers'
            WHEN r_score >= 4 AND f_score <= 2                  THEN 'Recent Customers'
            WHEN r_score <= 2 AND f_score >= 3                  THEN 'At Risk'
            WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2 THEN 'Lost'
            WHEN r_score >= 3 AND f_score <= 2 AND m_score >= 3 THEN 'Potential Loyalists'
            ELSE 'Need Attention'
        END AS segment

    FROM rfm_scored
),

segment_summary AS (
    SELECT
        segment,
        COUNT(*)                          AS customer_count,
        ROUND(AVG(monetary), 2)           AS avg_revenue_per_customer,
        ROUND(SUM(monetary), 2)           AS total_revenue,
        ROUND(AVG(frequency), 2)          AS avg_orders,
        ROUND(AVG(CAST(recency_days AS FLOAT)), 0) AS avg_recency_days
    FROM rfm_segmented
    GROUP BY segment
),

-- Pareto analysis: cumulative % of revenue by segment, ranked
pareto_analysis AS (
    SELECT
        segment,
        customer_count,
        avg_revenue_per_customer,
        total_revenue,
        avg_orders,
        avg_recency_days,

        -- Running total of revenue, ordered from highest to lowest segment
        SUM(total_revenue) OVER (
            ORDER BY total_revenue DESC
            ROWS UNBOUNDED PRECEDING
        )                                                  AS cumulative_revenue,

        -- Total revenue across all segments for % calculation
        SUM(total_revenue) OVER ()                          AS grand_total_revenue

    FROM segment_summary
)

SELECT
    segment,
    customer_count,
    avg_revenue_per_customer,
    total_revenue,
    avg_orders,
    avg_recency_days,
    ROUND(100.0 * total_revenue       / grand_total_revenue, 1) AS pct_of_total_revenue,
    ROUND(100.0 * cumulative_revenue  / grand_total_revenue, 1) AS cumulative_pct_revenue
FROM pareto_analysis
ORDER BY total_revenue DESC;

-- INTERPRETATION GUIDE:
-- Look at cumulative_pct_revenue — find where it crosses 80%.
-- Those top segments are your "vital few" (Pareto principle).
-- This identifies which customer segments deserve retention
-- investment vs which are low priority.


-- ============================================================
-- BQ2 — Category Review Performance & Repurchase Signal
-- ============================================================
-- "Which product categories have the lowest review rates,
--  and how does that affect repurchase behavior?"
--
-- Technique: CTE chain, LEFT JOIN through order_items to
-- categories, correlated subquery for repurchase flag.
-- ============================================================

WITH order_category AS (
    -- One row per order-category combination
    -- (orders with multiple categories count once per category)
    SELECT DISTINCT
        oi.order_id,
        pc.category_english
    FROM order_items oi
    INNER JOIN v_product_catalog pc
            ON oi.product_id = pc.product_id
),

category_reviews AS (
    SELECT
        oc.category_english,
        rs.review_score,
        rs.customer_unique_id,
        rs.total_revenue
    FROM order_category oc
    INNER JOIN v_review_summary rs
            ON oc.order_id = rs.order_id
),

-- Repurchase flag: does this customer have more than 1 order overall?
customer_repurchase AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT order_id) AS total_orders,
        CASE WHEN COUNT(DISTINCT order_id) > 1 THEN 1 ELSE 0 END AS is_repeat_customer
    FROM v_customer_orders
    GROUP BY customer_unique_id
),

category_summary AS (
    SELECT
        cr.category_english,
        COUNT(*)                                            AS total_reviewed_orders,
        ROUND(AVG(CAST(cr.review_score AS FLOAT)), 2)        AS avg_review_score,
        SUM(CASE WHEN cr.review_score <= 2 THEN 1 ELSE 0 END) AS negative_reviews,
        ROUND(
            100.0 * SUM(CASE WHEN cr.review_score <= 2 THEN 1 ELSE 0 END)
                  / COUNT(*)
        , 1)                                                 AS pct_negative_reviews,
        ROUND(SUM(cr.total_revenue), 2)                      AS category_revenue,

        -- % of customers buying this category who are repeat customers
        ROUND(
            100.0 * SUM(CASE WHEN crp.is_repeat_customer = 1 THEN 1 ELSE 0 END)
                  / COUNT(DISTINCT cr.customer_unique_id)
        , 1)                                                 AS pct_repeat_customers

    FROM category_reviews cr
    INNER JOIN customer_repurchase crp
            ON cr.customer_unique_id = crp.customer_unique_id
    GROUP BY cr.category_english
)

SELECT
    category_english,
    total_reviewed_orders,
    avg_review_score,
    negative_reviews,
    pct_negative_reviews,
    category_revenue,
    pct_repeat_customers,

    -- Rank categories by negative review rate (worst first)
    RANK() OVER (ORDER BY pct_negative_reviews DESC) AS worst_satisfaction_rank

FROM category_summary
WHERE total_reviewed_orders >= 30   -- exclude tiny categories with unstable %
ORDER BY pct_negative_reviews DESC;

-- INTERPRETATION GUIDE:
-- High pct_negative_reviews + low pct_repeat_customers = category
-- actively damaging customer lifetime value. Prioritize quality
-- investigation for the top 5 ranked categories.


-- ============================================================
-- BQ3 — Delivery Performance vs Customer Satisfaction
-- ============================================================
-- "What's the real delivery time vs promised, and how does
--  it impact satisfaction?"
--
-- Technique: CTE for delay buckets (already in view), aggregation
-- with multiple grouping levels, LAG() for month-over-month trend.
-- ============================================================

WITH delivery_satisfaction AS (
    SELECT
        delay_bucket,
        review_score,
        delay_days,
        days_to_deliver
    FROM v_review_summary
),

bucket_summary AS (
    SELECT
        delay_bucket,
        COUNT(*)                                     AS order_count,
        ROUND(AVG(CAST(review_score AS FLOAT)), 2)    AS avg_review_score,
        ROUND(AVG(CAST(delay_days AS FLOAT)), 1)      AS avg_delay_days,
        ROUND(AVG(CAST(days_to_deliver AS FLOAT)), 1) AS avg_days_to_deliver,
        MIN(delay_days)                               AS min_delay,
        MAX(delay_days)                               AS max_delay
    FROM delivery_satisfaction
    GROUP BY delay_bucket
),

-- Monthly delivery trend with month-over-month comparison
monthly_delivery AS (
    SELECT
        FORMAT(order_purchase_timestamp, 'yyyy-MM') AS order_month,
        AVG(CAST(delay_days AS FLOAT))               AS avg_delay_days,
        AVG(CAST(is_late AS FLOAT)) * 100             AS late_pct
    FROM v_delivery_performance
    GROUP BY FORMAT(order_purchase_timestamp, 'yyyy-MM')
),

monthly_trend AS (
    SELECT
        order_month,
        ROUND(avg_delay_days, 1) AS avg_delay_days,
        ROUND(late_pct, 1)       AS late_pct,

        -- LAG window function: compare to previous month
        ROUND(
            avg_delay_days - LAG(avg_delay_days) OVER (ORDER BY order_month)
        , 1)                      AS delay_change_vs_prev_month

    FROM monthly_delivery
)

-- Result Set 1: satisfaction by delay bucket
SELECT 'By Delay Bucket' AS analysis_type,
       delay_bucket      AS dimension,
       order_count,
       avg_review_score,
       avg_delay_days,
       avg_days_to_deliver,
       min_delay,
       max_delay,
       NULL AS late_pct,
       NULL AS delay_change_vs_prev_month
FROM bucket_summary

UNION ALL

-- Result Set 2: monthly trend
SELECT 'By Month'        AS analysis_type,
       order_month       AS dimension,
       NULL AS order_count,
       NULL AS avg_review_score,
       avg_delay_days,
       NULL AS avg_days_to_deliver,
       NULL AS min_delay,
       NULL AS max_delay,
       late_pct,
       delay_change_vs_prev_month
FROM monthly_trend

ORDER BY analysis_type, dimension;

-- INTERPRETATION GUIDE:
-- Compare avg_review_score across delay buckets — quantify
-- exactly how many stars are lost per week of delay.
-- Use delay_change_vs_prev_month to spot operational degradation
-- before it shows up in aggregate satisfaction scores.


-- ============================================================
-- BQ4 — Seller Risk Profile: Delays & Low Satisfaction
-- ============================================================
-- "Which sellers show patterns of delay or low satisfaction
--  that hurt customer experience?"
--
-- Technique: CTE with seller metrics, PERCENT_RANK() to find
-- sellers in the worst percentile, composite risk scoring.
-- ============================================================

WITH seller_metrics AS (
    SELECT
        seller_id,
        seller_state,
        total_orders,
        total_revenue,
        avg_review_score,
        avg_delay_days,
        late_pct,
        low_score_count
    FROM v_seller_performance
    WHERE total_orders >= 10   -- exclude sellers with too few orders for stable metrics
),

seller_ranked AS (
    SELECT
        *,
        -- PERCENT_RANK: 0 = best, 1 = worst, relative position among all sellers
        ROUND(PERCENT_RANK() OVER (ORDER BY late_pct ASC), 3)         AS late_pct_percentile,
        ROUND(PERCENT_RANK() OVER (ORDER BY avg_review_score DESC), 3) AS satisfaction_percentile,

        -- Composite risk score: average of both percentile ranks
        -- Higher composite = worse seller on both dimensions
        ROUND(
            (PERCENT_RANK() OVER (ORDER BY late_pct ASC)
           + PERCENT_RANK() OVER (ORDER BY avg_review_score DESC)) / 2.0
        , 3) AS risk_score

    FROM seller_metrics
)

SELECT
    seller_id,
    seller_state,
    total_orders,
    total_revenue,
    avg_review_score,
    avg_delay_days,
    late_pct,
    low_score_count,
    late_pct_percentile,
    satisfaction_percentile,
    risk_score,

    CASE
        WHEN risk_score >= 0.85 THEN 'High Risk'
        WHEN risk_score >= 0.65 THEN 'Watch List'
        ELSE 'Healthy'
    END AS risk_category

FROM seller_ranked
ORDER BY risk_score DESC;

-- INTERPRETATION GUIDE:
-- "High Risk" sellers combine both late deliveries AND low reviews —
-- these are the ones generating the most customer complaints.
-- This view is what an Ops team would use to flag sellers for
-- performance review or marketplace removal.


-- ============================================================
-- BQ5 — Monthly Revenue Trend & Seasonality
-- ============================================================
-- "What does the revenue trend look like month over month,
--  and is there seasonality?"
--
-- Technique: CTE for monthly aggregation, LAG() for MoM growth,
-- AVG() OVER as moving average window function.
-- ============================================================

WITH monthly_revenue AS (
    SELECT
        FORMAT(order_purchase_timestamp, 'yyyy-MM') AS order_month,
        COUNT(DISTINCT order_id)                     AS total_orders,
        ROUND(SUM(total_revenue), 2)                 AS total_revenue,
        ROUND(AVG(total_revenue), 2)                 AS avg_order_value
    FROM v_customer_orders
    GROUP BY FORMAT(order_purchase_timestamp, 'yyyy-MM')
),

revenue_with_trend AS (
    SELECT
        order_month,
        total_orders,
        total_revenue,
        avg_order_value,

        -- Month-over-month % growth
        LAG(total_revenue) OVER (ORDER BY order_month)          AS prev_month_revenue,
        ROUND(
            100.0 * (total_revenue - LAG(total_revenue) OVER (ORDER BY order_month))
                  / NULLIF(LAG(total_revenue) OVER (ORDER BY order_month), 0)
        , 1)                                                     AS mom_growth_pct,

        -- 3-month moving average to smooth seasonality noise
        ROUND(
            AVG(total_revenue) OVER (
                ORDER BY order_month
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            )
        , 2)                                                     AS moving_avg_3mo

    FROM monthly_revenue
)

SELECT
    order_month,
    total_orders,
    total_revenue,
    avg_order_value,
    mom_growth_pct,
    moving_avg_3mo
FROM revenue_with_trend
ORDER BY order_month;

-- INTERPRETATION GUIDE:
-- Look for November spikes (Black Friday in Brazil) and compare
-- moving_avg_3mo to raw total_revenue to separate real trend
-- from monthly noise. Large mom_growth_pct swings flag anomalies
-- worth investigating (platform outages, promotions, etc).


-- ============================================================
-- BQ6 — Customer Cohort Retention Analysis
-- ============================================================
-- "Of customers who made their first purchase in month X,
--  what % returned to buy again in following months?"
--
-- Technique: CTE for cohort assignment, self-referencing logic
-- via window function MIN() to find first purchase, DATEDIFF
-- for cohort month offset.
-- ============================================================

WITH customer_first_purchase AS (
    SELECT
        customer_unique_id,
        order_id,
        order_purchase_timestamp,

        -- Window function: first purchase date per customer
        MIN(order_purchase_timestamp) OVER (
            PARTITION BY customer_unique_id
        ) AS cohort_date

    FROM v_customer_orders
),

cohort_assigned AS (
    SELECT
        customer_unique_id,
        order_id,
        FORMAT(cohort_date, 'yyyy-MM')               AS cohort_month,

        -- Months between cohort entry and this specific order
        DATEDIFF(
            MONTH,
            cohort_date,
            order_purchase_timestamp
        )                                              AS month_offset

    FROM customer_first_purchase
),

cohort_size AS (
    -- Number of customers who first purchased in each cohort month
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_unique_id) AS cohort_customers
    FROM cohort_assigned
    WHERE month_offset = 0
    GROUP BY cohort_month
),

retention_matrix AS (
    SELECT
        ca.cohort_month,
        ca.month_offset,
        COUNT(DISTINCT ca.customer_unique_id) AS active_customers
    FROM cohort_assigned ca
    GROUP BY ca.cohort_month, ca.month_offset
)

SELECT
    rm.cohort_month,
    cs.cohort_customers,
    rm.month_offset,
    rm.active_customers,
    ROUND(100.0 * rm.active_customers / cs.cohort_customers, 1) AS retention_pct
FROM retention_matrix rm
INNER JOIN cohort_size cs
        ON rm.cohort_month = cs.cohort_month
WHERE rm.month_offset BETWEEN 0 AND 6   -- first 6 months of each cohort's life
ORDER BY rm.cohort_month, rm.month_offset;

-- INTERPRETATION GUIDE:
-- Pivot this in Power BI: cohort_month as rows, month_offset as
-- columns, retention_pct as values. This produces the classic
-- "cohort retention triangle" — a staple chart in any retention-
-- focused analyst portfolio. Expect very low retention_pct in
-- this dataset (Olist customers rarely repurchase), which is
-- itself an important finding to report.

-- ============================================================
-- END OF ANALYSIS QUERIES
-- Next: build views/queries into Power BI data model (04_powerbi/)
-- ============================================================
