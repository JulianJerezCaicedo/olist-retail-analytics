-- ============================================================
--  OLIST RETAIL ANALYTICS — DATA LOAD (SQL Server / T-SQL)
--  Script: 02_data_load_sqlserver.sql
--  Author: Julian | Created: 2026
--  Delimiter: comma (,) | Encoding: UTF-8
--  Raw data path: D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\
-- ============================================================
--  SQL Server uses BULK INSERT instead of LOAD DATA INFILE.
--  Each table gets:
--    1. BULK INSERT with format options
--    2. Post-load validation query
--    3. Cleaning steps where needed (UPDATE after load)
-- ============================================================
--  LOAD ORDER (respects FK dependencies):
--  1. product_category_translation
--  2. geolocation
--  3. sellers
--  4. products
--  5. customers
--  6. orders
--  7. order_items
--  8. order_payments
--  9. order_reviews
-- ============================================================

USE olist_retail;
GO


-- ============================================================
-- 1. product_category_translation
-- ============================================================
-- Rows expected: 71

BULK INSERT product_category_translation
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\product_category_name_translation.csv'
WITH (
    FORMAT            = 'CSV',
    FIRSTROW          = 2,           -- skip header row
    FIELDTERMINATOR   = ',',
    ROWTERMINATOR     = '\n',
    CODEPAGE          = '65001',     -- UTF-8
    TABLOCK                          -- improves bulk load performance
);
GO

-- Validation
SELECT 'product_category_translation' AS table_name, COUNT(*) AS rows_loaded
FROM product_category_translation;
GO


-- ============================================================
-- 2. geolocation
-- ============================================================
-- Rows expected: ~1,000,163
-- Note: largest file — may take 60-90 seconds in SQL Server

BULK INSERT geolocation
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_geolocation_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

SELECT 'geolocation' AS table_name, COUNT(*) AS rows_loaded FROM geolocation;
GO


-- ============================================================
-- 3. sellers
-- ============================================================
-- Rows expected: 3,095

BULK INSERT sellers
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_sellers_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

SELECT 'sellers' AS table_name, COUNT(*) AS rows_loaded FROM sellers;
GO


-- ============================================================
-- 4. products
-- ============================================================
-- Rows expected: 32,951
-- CLEANING NOTE: product_category_name loaded as-is (Portuguese).
-- Empty strings converted to NULL in the UPDATE step below.
-- This prevents FK violations for products with unknown category.

BULK INSERT products
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_products_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

-- Post-load cleaning: convert empty strings to NULL
-- SQL Server BULK INSERT does not support inline SET transformations
-- like MySQL, so we clean in a separate UPDATE pass.
UPDATE products
SET product_category_name = NULL
WHERE LTRIM(RTRIM(product_category_name)) = '';
GO

SELECT 'products' AS table_name, COUNT(*) AS rows_loaded FROM products;

-- Check null categories (expect ~610)
SELECT 'products with null category' AS check_name, COUNT(*) AS count
FROM products
WHERE product_category_name IS NULL;
GO


-- ============================================================
-- 5. customers
-- ============================================================
-- Rows expected: 99,441

BULK INSERT customers
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_customers_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

SELECT 'customers' AS table_name, COUNT(*) AS rows_loaded FROM customers;
GO


-- ============================================================
-- 6. orders
-- ============================================================
-- Rows expected: 99,441
-- CLEANING NOTE: date columns with empty strings cause BULK INSERT
-- to fail in SQL Server. Strategy:
--   Step 1 → Load into a staging table with all columns as NVARCHAR
--   Step 2 → INSERT INTO orders with NULLIF + CAST for date columns
-- This is the correct production pattern for unreliable date data.

-- Step 1: create staging table
IF OBJECT_ID('stg_orders', 'U') IS NOT NULL DROP TABLE stg_orders;

CREATE TABLE stg_orders (
    order_id                      NVARCHAR(50),
    customer_id                   NVARCHAR(50),
    order_status                  NVARCHAR(20),
    order_purchase_timestamp      NVARCHAR(30),
    order_approved_at             NVARCHAR(30),
    order_delivered_carrier_date  NVARCHAR(30),
    order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30)
);
GO

BULK INSERT stg_orders
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_orders_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

-- Step 2: insert into final table with type casting and null handling
INSERT INTO orders (
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date
)
SELECT
    order_id,
    customer_id,
    order_status,
    -- NULLIF converts empty string → NULL, then CAST to DATETIME
    CAST(NULLIF(LTRIM(RTRIM(order_purchase_timestamp)),      '') AS DATETIME),
    CAST(NULLIF(LTRIM(RTRIM(order_approved_at)),             '') AS DATETIME),  -- 160 nulls
    CAST(NULLIF(LTRIM(RTRIM(order_delivered_carrier_date)),  '') AS DATETIME),  -- 1,783 nulls
    CAST(NULLIF(LTRIM(RTRIM(order_delivered_customer_date)), '') AS DATETIME),  -- 2,965 nulls
    CAST(NULLIF(LTRIM(RTRIM(order_estimated_delivery_date)), '') AS DATETIME)
FROM stg_orders;
GO

-- Clean up staging table
DROP TABLE stg_orders;
GO

SELECT 'orders' AS table_name, COUNT(*) AS rows_loaded FROM orders;

-- Validate null counts match Quality Report
SELECT
    SUM(CASE WHEN order_approved_at             IS NULL THEN 1 ELSE 0 END) AS nulls_approved,
    SUM(CASE WHEN order_delivered_carrier_date  IS NULL THEN 1 ELSE 0 END) AS nulls_carrier,
    SUM(CASE WHEN order_delivered_customer_date IS NULL THEN 1 ELSE 0 END) AS nulls_delivered
FROM orders;
-- Expected: 160 | 1,783 | 2,965
GO


-- ============================================================
-- 7. order_items
-- ============================================================
-- Rows expected: 112,650

BULK INSERT order_items
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_order_items_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

SELECT 'order_items' AS table_name, COUNT(*) AS rows_loaded FROM order_items;
GO


-- ============================================================
-- 8. order_payments
-- ============================================================
-- Rows expected: 103,886

BULK INSERT order_payments
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_order_payments_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

SELECT 'order_payments' AS table_name, COUNT(*) AS rows_loaded FROM order_payments;
GO


-- ============================================================
-- 9. order_reviews
-- ============================================================
-- Rows expected: 99,224
-- CLEANING NOTE: free-text comment fields may contain embedded
-- commas and line breaks — this can break BULK INSERT parsing.
-- Same staging strategy as orders: load all as NVARCHAR, then
-- INSERT with NULLIF for empty string → NULL conversion.

IF OBJECT_ID('stg_reviews', 'U') IS NOT NULL DROP TABLE stg_reviews;

CREATE TABLE stg_reviews (
    review_id               NVARCHAR(50),
    order_id                NVARCHAR(50),
    review_score            NVARCHAR(5),
    review_comment_title    NVARCHAR(200),
    review_comment_message  NVARCHAR(MAX),
    review_creation_date    NVARCHAR(30),
    review_answer_timestamp NVARCHAR(30)
);
GO

BULK INSERT stg_reviews
FROM 'D:\Porjects SQL + PBI\Olist_Retail_Analytics\01_raw_data\olist_order_reviews_dataset.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '\n',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

INSERT INTO order_reviews (
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
)
SELECT
    review_id,
    order_id,
    CAST(review_score AS TINYINT),
    NULLIF(LTRIM(RTRIM(review_comment_title)),   ''),
    NULLIF(LTRIM(RTRIM(review_comment_message)), ''),
    CAST(NULLIF(LTRIM(RTRIM(review_creation_date)),    '') AS DATETIME),
    CAST(NULLIF(LTRIM(RTRIM(review_answer_timestamp)), '') AS DATETIME)
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY review_id        -- agrupa por review_id duplicado
            ORDER BY review_creation_date -- conserva el registro más antiguo
        ) AS rn
    FROM stg_reviews
) ranked
WHERE rn = 1;  -- solo la primera ocurrencia de cada review_id
GO

DROP TABLE stg_reviews;
GO

SELECT 'order_reviews' AS table_name, COUNT(*) AS rows_loaded FROM order_reviews;
GO


-- ============================================================
-- FINAL VALIDATION — all tables at a glance
-- Run after all loads. Compare against Quality Report.
-- ============================================================

SELECT 'product_category_translation' AS table_name, COUNT(*) AS rows FROM product_category_translation
UNION ALL SELECT 'geolocation',    COUNT(*) FROM geolocation
UNION ALL SELECT 'sellers',        COUNT(*) FROM sellers
UNION ALL SELECT 'products',       COUNT(*) FROM products
UNION ALL SELECT 'customers',      COUNT(*) FROM customers
UNION ALL SELECT 'orders',         COUNT(*) FROM orders
UNION ALL SELECT 'order_items',    COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*) FROM order_reviews;
GO

-- Expected results:
-- product_category_translation →      71
-- geolocation                  → ~1,000,163
-- sellers                      →   3,095
-- products                     →  32,951
-- customers                    →  99,441
-- orders                       →  99,441
-- order_items                  → 112,650
-- order_payments               → 103,886
-- order_reviews                →  99,224

-- ============================================================
-- END OF DATA LOAD — SQL Server version
-- Next: 03_views.sql → Reusable analytical views
-- ============================================================