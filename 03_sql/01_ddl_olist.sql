-- ============================================================
--  OLIST RETAIL ANALYTICS — DATA DEFINITION LANGUAGE (DDL)
--  Version: SQL Server / T-SQL
--  Project: Customer Behavior & Retention Intelligence
--  Author:  Julian
--  Created: 2026
--  Source:  Brazilian E-Commerce Public Dataset (Olist / Kaggle)
-- ============================================================
--  QUALITY REPORT SUMMARY (from Excel profiling phase):
--    · orders             → 99,441 rows  | 8 cols  | 3 cols with nulls
--    · order_items        → 112,650 rows | 7 cols  | 0 nulls
--    · payments           → 103,886 rows | 5 cols  | multi-payment orders detected
--    · reviews            → 99,224 rows  | 7 cols  | 217 orders without review
--    · customers          → 99,441 rows  | 5 cols  | 0 nulls
--    · products           → 32,951 rows  | 9 cols  | categories in Portuguese
--    · sellers            → 3,095 rows   | 4 cols  | 0 nulls
--    · geolocation        → 1,000,163 rows| 5 cols | reference table
--    · category_transl.   → 71 rows      | 2 cols  | lookup table
-- ============================================================


-- ------------------------------------------------------------
--  STEP 0 — CREATE AND SELECT DATABASE
--  T-SQL difference: USE cannot run in the same batch as CREATE.
--  Run the CREATE block first, then the USE + rest of the script.
-- ------------------------------------------------------------

-- BLOCK A: Run this first (select it and press F5)
IF NOT EXISTS (
    SELECT name FROM sys.databases WHERE name = 'olist_retail'
)
BEGIN
    CREATE DATABASE olist_retail;
END
GO

-- BLOCK B: Run from here to the end (select all below and press F5)
USE olist_retail;
GO


-- ------------------------------------------------------------
--  STEP 1 — DROP TABLES (safe re-run order: children first)
--  T-SQL difference: uses OBJECT_ID() check instead of
--  DROP TABLE IF EXISTS (which only works in SQL Server 2016+).
--  This version is compatible with all SQL Server editions.
-- ------------------------------------------------------------

IF OBJECT_ID('order_reviews',              'U') IS NOT NULL DROP TABLE order_reviews;
IF OBJECT_ID('order_payments',             'U') IS NOT NULL DROP TABLE order_payments;
IF OBJECT_ID('order_items',                'U') IS NOT NULL DROP TABLE order_items;
IF OBJECT_ID('orders',                     'U') IS NOT NULL DROP TABLE orders;
IF OBJECT_ID('customers',                  'U') IS NOT NULL DROP TABLE customers;
IF OBJECT_ID('products',                   'U') IS NOT NULL DROP TABLE products;
IF OBJECT_ID('sellers',                    'U') IS NOT NULL DROP TABLE sellers;
IF OBJECT_ID('geolocation',                'U') IS NOT NULL DROP TABLE geolocation;
IF OBJECT_ID('product_category_translation','U') IS NOT NULL DROP TABLE product_category_translation;
GO


-- ============================================================
--  DIMENSION & LOOKUP TABLES
-- ============================================================

-- ------------------------------------------------------------
--  TABLE: product_category_translation
--  Source file: product_category_name_translation.csv
--  Role: lookup — translates Portuguese category names to English
--  Quality notes: 71 rows, 0 nulls, no cleaning needed
-- ------------------------------------------------------------

CREATE TABLE product_category_translation (
    category_name_portuguese NVARCHAR(100) NOT NULL,
    category_name_english    NVARCHAR(100) NOT NULL,
    CONSTRAINT pk_category_translation
        PRIMARY KEY (category_name_portuguese)
);
GO


-- ------------------------------------------------------------
--  TABLE: geolocation
--  Source file: olist_geolocation_dataset.csv
--  Role: geographic reference (zip code → lat/lng/city/state)
--  Quality notes: 1,000,163 rows — largest table, used only
--  for map visualizations in Power BI. Not joined in SQL
--  analytical queries due to performance (no unique PK —
--  multiple lat/lng per zip code exist by design).
--  T-SQL difference: DECIMAL precision syntax is the same,
--  but CHAR(2) becomes NCHAR(2) for Unicode safety.
-- ------------------------------------------------------------

CREATE TABLE geolocation (
    geolocation_zip_code_prefix NVARCHAR(10)   NOT NULL,
    geolocation_lat             DECIMAL(18, 8) NOT NULL,
    geolocation_lng             DECIMAL(18, 8) NOT NULL,
    geolocation_city            NVARCHAR(100)  NOT NULL,
    geolocation_state           NCHAR(2)       NOT NULL
    -- No PRIMARY KEY: multiple coordinates exist per zip code.
    -- Index added below for query performance.
);
GO

CREATE INDEX idx_geo_zip ON geolocation (geolocation_zip_code_prefix);
GO


-- ------------------------------------------------------------
--  TABLE: sellers
--  Source file: olist_sellers_dataset.csv
--  Role: dimension — seller attributes
--  Quality notes: 3,095 rows, 0 nulls, no cleaning needed
-- ------------------------------------------------------------

CREATE TABLE sellers (
    seller_id       NVARCHAR(50)  NOT NULL,
    seller_zip_code NVARCHAR(10)  NULL,
    seller_city     NVARCHAR(100) NULL,
    seller_state    NCHAR(2)      NULL,
    CONSTRAINT pk_sellers PRIMARY KEY (seller_id)
);
GO


-- ------------------------------------------------------------
--  TABLE: products
--  Source file: olist_products_dataset.csv
--  Role: dimension — product catalog
--  Quality notes: 32,951 rows.
--
--  CLEANING DECISION: product_category_name is in Portuguese.
--  We store the raw Portuguese value here and resolve to English
--  via JOIN with product_category_translation in analytical
--  queries and views. This preserves raw data integrity.
--  Null categories (~1.85%) → kept as NULL, excluded from
--  category-level aggregations with WHERE IS NOT NULL.
--
--  T-SQL difference: ON UPDATE CASCADE on a FK that references
--  a column involved in another CASCADE path can cause errors
--  in SQL Server. Simplified to NO ACTION where safe.
-- ------------------------------------------------------------

CREATE TABLE products (
    product_id                 NVARCHAR(50)  NOT NULL,
    product_category_name      NVARCHAR(100) NULL,     -- Portuguese; join to translation table
    product_name_length        INT           NULL,
    product_description_length INT           NULL,
    product_photos_qty         INT           NULL,
    product_weight_g           INT           NULL,
    product_length_cm          INT           NULL,
    product_height_cm          INT           NULL,
    product_width_cm           INT           NULL,
    CONSTRAINT pk_products PRIMARY KEY (product_id),
    CONSTRAINT fk_product_category
        FOREIGN KEY (product_category_name)
        REFERENCES product_category_translation (category_name_portuguese)
);
GO


-- ------------------------------------------------------------
--  TABLE: customers
--  Source file: olist_customers_dataset.csv
--  Role: dimension — customer attributes
--  Quality notes: 99,441 rows, 0 nulls.
--
--  ⚠️  CRITICAL DESIGN NOTE — two customer identifiers exist:
--    · customer_id        → changes per order (not a true person ID)
--    · customer_unique_id → stable identifier for the real person
--  For RFM analysis and any customer-level aggregation, always
--  use customer_unique_id. Using customer_id would artificially
--  inflate the customer count (one person appears multiple times).
-- ------------------------------------------------------------

CREATE TABLE customers (
    customer_id        NVARCHAR(50)  NOT NULL,  -- order-scoped ID (FK target from orders)
    customer_unique_id NVARCHAR(50)  NOT NULL,  -- TRUE person identifier — use for RFM
    customer_zip_code  NVARCHAR(10)  NULL,
    customer_city      NVARCHAR(100) NULL,
    customer_state     NCHAR(2)      NULL,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id)
);
GO

CREATE INDEX idx_customers_unique ON customers (customer_unique_id);
GO


-- ============================================================
--  FACT & TRANSACTION TABLES
-- ============================================================

-- ------------------------------------------------------------
--  TABLE: orders
--  Source file: olist_orders_dataset.csv
--  Role: central fact hub — all other tables join here
--  Quality notes: 99,441 rows.
--
--  CLEANING DECISIONS per Quality Report:
--    · order_approved_at (160 nulls / 0.16%) → SEVERITY: MEDIUM
--      Origin: cancelled orders never get approval timestamp.
--      Decision: keep nulls; filter with WHERE order_approved_at
--      IS NOT NULL only in approval-time analysis queries.
--
--    · order_delivered_carrier_date (1,783 nulls / 1.79%) → SEVERITY: MEDIUM
--      Origin: orders not yet shipped or cancelled before pickup.
--      Decision: keep nulls; filter with WHERE order_status =
--      'delivered' in logistics lead-time queries.
--
--    · order_delivered_customer_date (2,965 nulls / 2.98%) → SEVERITY: HIGH
--      Origin: orders not yet delivered or cancelled.
--      Decision: keep nulls in raw table; apply
--      WHERE order_delivered_customer_date IS NOT NULL
--      in delivery-vs-promise analysis.
--      For RFM: use order_purchase_timestamp, NOT this column.
--
--  T-SQL difference: DATETIME works the same in SQL Server.
-- ------------------------------------------------------------

CREATE TABLE orders (
    order_id                      NVARCHAR(50) NOT NULL,
    customer_id                   NVARCHAR(50) NOT NULL,
    order_status                  NVARCHAR(20) NOT NULL,
    order_purchase_timestamp      DATETIME     NOT NULL,
    order_approved_at             DATETIME     NULL,  -- 160 nulls: cancelled orders
    order_delivered_carrier_date  DATETIME     NULL,  -- 1,783 nulls: unshipped orders
    order_delivered_customer_date DATETIME     NULL,  -- 2,965 nulls: undelivered (HIGH)
    order_estimated_delivery_date DATETIME     NOT NULL,
    CONSTRAINT pk_orders
        PRIMARY KEY (order_id),
    CONSTRAINT fk_orders_customers
        FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
);
GO

CREATE INDEX idx_orders_status   ON orders (order_status);
CREATE INDEX idx_orders_purchase ON orders (order_purchase_timestamp);
CREATE INDEX idx_orders_customer ON orders (customer_id);
GO


-- ------------------------------------------------------------
--  TABLE: order_items
--  Source file: olist_order_items_dataset.csv
--  Role: transaction detail — one row per product per order
--  Quality notes: 112,650 rows > 99,441 orders → one order
--  can contain multiple products. 0 nulls.
-- ------------------------------------------------------------

CREATE TABLE order_items (
    order_id            NVARCHAR(50)   NOT NULL,
    order_item_id       INT            NOT NULL,  -- item sequence within the order (1,2,3...)
    product_id          NVARCHAR(50)   NOT NULL,
    seller_id           NVARCHAR(50)   NOT NULL,
    shipping_limit_date DATETIME       NULL,
    price               DECIMAL(10, 2) NOT NULL,
    freight_value       DECIMAL(10, 2) NOT NULL,
    CONSTRAINT pk_order_items
        PRIMARY KEY (order_id, order_item_id),    -- composite PK: order + item sequence
    CONSTRAINT fk_items_orders
        FOREIGN KEY (order_id)
        REFERENCES orders (order_id),
    CONSTRAINT fk_items_products
        FOREIGN KEY (product_id)
        REFERENCES products (product_id),
    CONSTRAINT fk_items_sellers
        FOREIGN KEY (seller_id)
        REFERENCES sellers (seller_id)
);
GO

CREATE INDEX idx_items_product ON order_items (product_id);
CREATE INDEX idx_items_seller  ON order_items (seller_id);
GO


-- ------------------------------------------------------------
--  TABLE: order_payments
--  Source file: olist_order_payments_dataset.csv
--  Role: payment detail per order
--  Quality notes: 103,886 rows > 99,441 orders → SEVERITY: MEDIUM
--
--  CLEANING DECISION:
--  Some orders use multiple payment methods (e.g. credit card +
--  voucher). This creates multiple rows per order_id.
--  → NEVER join payments directly to orders without aggregating.
--    Always use SUM(payment_value) GROUP BY order_id first.
--    Encapsulated in v_order_financials view (03_views.sql).
-- ------------------------------------------------------------

CREATE TABLE order_payments (
    order_id             NVARCHAR(50)   NOT NULL,
    payment_sequential   INT            NOT NULL,  -- sequence when multiple methods used
    payment_type         NVARCHAR(30)   NOT NULL,  -- credit_card, boleto, voucher, debit_card
    payment_installments INT            NOT NULL,
    payment_value        DECIMAL(10, 2) NOT NULL,
    CONSTRAINT pk_order_payments
        PRIMARY KEY (order_id, payment_sequential),
    CONSTRAINT fk_payments_orders
        FOREIGN KEY (order_id)
        REFERENCES orders (order_id)
);
GO

CREATE INDEX idx_payments_type ON order_payments (payment_type);
GO


-- ------------------------------------------------------------
--  TABLE: order_reviews
--  Source file: olist_order_reviews_dataset.csv
--  Role: customer satisfaction signal per order
--  Quality notes: 99,224 rows < 99,441 orders.
--
--  CLEANING DECISION:
--  217 orders have no review (0.22%) → SEVERITY: LOW
--  Always use LEFT JOIN from orders TO order_reviews.
--  An INNER JOIN silently drops 217 orders from analysis.
--
--  review_comment_title   (88.3% nulls) → SEVERITY: LOW — optional
--  review_comment_message (58.7% nulls) → SEVERITY: LOW — optional
--  Use review_score only for quantitative analysis.
--
--  T-SQL difference: CHECK constraints use same syntax.
--  T-SQL difference: TEXT type is deprecated — use NVARCHAR(MAX).
-- ------------------------------------------------------------

CREATE TABLE order_reviews (
    review_id               NVARCHAR(50)   NOT NULL,
    order_id                NVARCHAR(50)   NOT NULL,
    review_score            TINYINT        NOT NULL,
    review_comment_title    NVARCHAR(100)  NULL,        -- 88.3% null — optional
    review_comment_message  NVARCHAR(MAX)  NULL,        -- 58.7% null — optional
    review_creation_date    DATETIME       NOT NULL,
    review_answer_timestamp DATETIME       NOT NULL,
    CONSTRAINT pk_order_reviews
        PRIMARY KEY (review_id),
    CONSTRAINT fk_reviews_orders
        FOREIGN KEY (order_id)
        REFERENCES orders (order_id),
    CONSTRAINT chk_review_score
        CHECK (review_score BETWEEN 1 AND 5)
);
GO

CREATE INDEX idx_reviews_order ON order_reviews (order_id);
CREATE INDEX idx_reviews_score ON order_reviews (review_score);
GO


-- ============================================================
--  END OF DDL — SQL Server / T-SQL version
--  Next script: 02_data_load.sql  → BULK INSERT for each table
--  Then:        03_views.sql      → Reusable analytical views
--  Then:        04_analysis.sql   → CTE-based business queries
-- ============================================================