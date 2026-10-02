# Olist Retail Analytics — Customer Behavior & Retention Intelligence

## Business Context

Olist is a Brazilian e-commerce marketplace that connects small and medium-sized businesses
to major retail channels. Between 2016 and 2018, the platform processed over 99,000 orders
across multiple product categories and seller profiles.

Leadership needed to move beyond surface-level sales reporting to understand what was
actually driving — and limiting — business growth. The core question: **is this a customer
acquisition problem or a retention problem?**

This project builds a full analytics pipeline from raw data to executive dashboard,
answering six business questions that directly inform strategic and operational decisions.

---

## Dashboard Preview

### Executive Overview
![Executive Overview](04_powerbi/screenshots/01_executive_overview.png)

Revenue trend with 3-month moving average, RFM segment revenue distribution, top categories,
and geographic revenue concentration across Brazilian states.

### Customer Segmentation
![Customer Segmentation](04_powerbi/screenshots/02_customer_segmentation.png)

RFM scatter plot, Pareto revenue concentration analysis, and a monthly cohort retention
heatmap revealing that fewer than 1% of customers return after their first purchase.

### Delivery & Satisfaction
![Delivery Satisfaction](04_powerbi/screenshots/03_delivery_satisfaction.png)

Customer satisfaction by delivery timing (continuous color scale), late delivery rate trend,
and a seller risk matrix identifying high-impact underperforming sellers.

> Full interactive report: [`04_powerbi/olist_dashboard.pbix`](04_powerbi/olist_dashboard.pbix)

---

## Analyst's Role

End-to-end ownership of the analytics pipeline:

- Data profiling and quality assessment in Excel
- Relational data modeling and schema design in SQL Server
- ETL pipeline with documented cleaning decisions
- Analytical view layer for reusable business logic
- CTE-based business queries using window functions
- Executive dashboard in Power BI (star schema + DAX + Power Query)

---

## Data Architecture

**Source:** Brazilian E-Commerce Public Dataset — Olist (Kaggle)
**Engine:** SQL Server (primary) | MySQL (parallel validation)
**Model:** Star schema — 1 central fact hub + 4 analytical dimensions

| Table | Rows | Role |
|---|---|---|
| orders | 99,441 | Central fact hub |
| order_items | 112,650 | Transaction detail |
| order_payments | 103,886 | Payment methods |
| order_reviews | 98,410 | Customer satisfaction |
| customers | 99,441 | Customer dimension |
| products | 32,951 | Product catalog |
| sellers | 3,095 | Seller dimension |
| geolocation | 1,000,163 | Geographic reference |
| category_translation | 71 | Lookup table |

---

## Data Quality Findings

Key issues identified during Excel profiling and resolved in the SQL pipeline:

| Issue | Severity | Resolution |
|---|---|---|
| order_delivered_customer_date — 2,965 nulls (2.98%) | High | Excluded from delivery analysis; RFM uses purchase date |
| Payments > Orders (103,886 vs 99,441) | Medium | Multi-payment orders aggregated with SUM() GROUP BY order_id before joining |
| Duplicate review_id in order_reviews | Medium | Deduplicated with ROW_NUMBER() PARTITION BY review_id at load time |
| Duplicate order_id in reviews (268 orders) | Medium | Second deduplication layer: ROW_NUMBER() PARTITION BY order_id in v_order_review_agg view |
| 2 categories missing from translation table | Medium | Inserted manually: pc_gamer and portateis_cozinha_e_preparadores_de_alimentos |
| 1 delivered order with no payment record | Low | Excluded from revenue views — cannot calculate financials without payment data |
| customer_id vs customer_unique_id | Critical design note | All customer-level analysis uses customer_unique_id (stable person identifier) |

---

## Technical Highlights

### SQL — Scripts in `/03_sql/`

**`01_ddl.sql`** — Schema design with FK constraints, indexes, and data type decisions
(DECIMAL for prices, NVARCHAR for Unicode safety, composite PKs for order_items and payments)

**`02_data_load.sql`** — BULK INSERT pipeline with staging tables for date parsing and
null handling. Multi-step load strategy for orders and reviews to handle empty strings in
typed columns without data loss.

**`03_views.sql`** — 9 reusable analytical views encapsulating all cleaning logic:

| View | Purpose |
|---|---|
| v_delivered_orders | Base filter: delivered orders with valid delivery date |
| v_order_financials | Revenue per order — multi-payment safe (SUM + ROW_NUMBER) |
| v_order_review_agg | One review per order — duplicate-safe (ROW_NUMBER PARTITION BY order_id) |
| v_delivery_performance | Promised vs actual delivery with delay buckets and is_late flag |
| v_product_catalog | Portuguese → English category resolution via LEFT JOIN |
| v_customer_orders | Customer-level order history using customer_unique_id |
| v_rfm_base | RFM inputs per customer with dataset-anchored reference date |
| v_seller_performance | Seller-level KPIs: revenue, review score, delay rate |
| v_review_summary | Reviews joined to delivery and financial context |

**`04_analysis.sql`** — 6 business queries using:
- Chained CTEs
- NTILE(5) for RFM quintile scoring
- SUM() OVER with ROWS UNBOUNDED PRECEDING for Pareto cumulative revenue
- LAG() for month-over-month revenue trend
- AVG() OVER with ROWS BETWEEN for 3-month moving average
- PERCENT_RANK() for seller composite risk scoring
- MIN() OVER PARTITION BY for cohort first-purchase assignment
- DATEDIFF() MONTH for cohort retention matrix

---

## Business Questions & Key Findings

### BQ1 — Customer Segmentation: RFM + Pareto Analysis
*"Which customer segments generate 80% of revenue?"*

**Finding 1:** 78.6% of total revenue comes from customers classified as "At Risk"
(37,354 customers) and "Recent Customers" (36,171 customers) — both with an average
order frequency of 1. The platform is almost entirely dependent on single-purchase customers.

**Finding 2:** Champions — the highest-value segment — represent only 967 customers (1% of
the base) averaging $373 per customer and 2 orders. Converting 10% of At Risk customers
into Loyal would recover approximately $617K in annual revenue.

**Business implication:** This is a retention problem, not an acquisition problem.

---

### BQ2 — Category Review Performance & Repurchase Signal
*"Which categories have the worst satisfaction rates and how does that affect repurchase?"*

**Finding 3:** office_furniture has a 22% negative review rate (scores 1-2) across 1,238
orders and $332K in revenue — the highest-volume category with a significant satisfaction
risk. fashion_male_clothing (23.1%) and audio (21.7%) follow.

**Finding 4:** office_furniture repeat customer rate is only 3.7% — among the lowest in
the catalog. High dissatisfaction directly correlates with near-zero repurchase in this
category. home_appliances, by contrast, has 13.1% repeat customers and low negative rates.

**Business implication:** office_furniture is destroying long-term customer value while
appearing healthy in top-line revenue metrics.

---

### BQ3 — Delivery Performance vs Customer Satisfaction
*"What is the real vs promised delivery time, and how does it impact satisfaction?"*

**Finding 5:** 78% of orders (75,346) arrive more than 7 days before the promised date,
with an average review score of 4.32. When orders arrive late, review scores collapse:
Late 8-14 days averages 1.67 stars. Late 1-7 days averages 2.72 stars. This is a drop
of 2.65 stars — 61% lower satisfaction — from early to moderately late delivery.

**Finding 6:** Olist systematically over-promises delivery dates. The real SLA risk is
concentrated in the 6.6% of orders that arrive late. A tighter promised-date algorithm
would reduce the early-delivery buffer while protecting SLA compliance.

**Finding 7:** November 2017 shows a late_pct spike to 14.3% (vs 3-5% in normal months),
confirming Black Friday logistics stress. February-March 2018 shows a sustained spike
to 16-21%, signaling an operational issue beyond seasonal demand.

---

### BQ4 — Seller Risk Profile
*"Which sellers show patterns of delay or low satisfaction that hurt customer experience?"*

**Finding 8:** Seller b1b3948701c5c72445495bd161b83a4c has a risk_score of 1.0 —
the maximum — with 1.93 avg review score and 64.3% late delivery rate across 14 orders.

**Finding 9:** The highest-impact risk is seller 2eb70248d66e0e3ef83659f71b244378:
187 orders, $39K revenue, 2.81 avg review score, risk_score 0.908. High volume combined
with consistently poor satisfaction generates the largest accumulated customer damage.

**Business implication:** The composite risk score using PERCENT_RANK() across both
late rate and satisfaction identifies two risk profiles: high-frequency moderate-risk
sellers (revenue impact) and low-frequency extreme-risk sellers (reputation impact).

---

### BQ5 — Monthly Revenue Trend & Seasonality
*"What does the revenue trend look like and is there seasonality?"*

**Finding 10:** Revenue grew 25x from $46K (October 2016) to $1.15M (November 2017)
in 13 months. The 3-month moving average confirms a consistent upward trend, not noise.

**Finding 11:** November 2017 Black Friday generated a 53.6% month-over-month spike —
the largest single-month jump in the dataset. Revenue stabilized between $966K and
$1.13M from January 2018 onward, indicating market maturation rather than decline.

**Dataset note:** December 2016 contains only 1 order ($19.62) — data is incomplete
for the platform's early operating months and excluded from trend analysis.

---

### BQ6 — Customer Cohort Retention Analysis
*"What percentage of customers return to buy again in the months after their first purchase?"*

**Finding 12:** Retention at month 1 never exceeds 0.7% across any cohort.
At month 6, no cohort surpasses 0.4%. This is the most critical finding of the project.

**Business implication:** Olist operates as a pure acquisition machine with no retention
mechanism. The business case for a retention program is quantifiable: if month-1 retention
improved from 0.5% to 3% on an average cohort of 4,500 new customers, with an average
order value of $160, that represents approximately $1.3M in incremental annual revenue —
without acquiring a single new customer.

---

## Business Recommendations

1. **Launch a retention program targeting the At Risk segment** (37,354 customers, $6.17M revenue at risk). Even a 5% conversion to Loyal Customers would generate ~$617K in recoverable revenue annually.

2. **Audit office_furniture category** — 22% negative review rate with $332K revenue and 3.7% repeat rate. Investigate product quality, seller fulfillment, and packaging standards for this category specifically.

3. **Recalibrate delivery promise dates** — 78% of orders arrive 7+ days early, creating a false SLA buffer. Tighter promised dates would reduce logistics cost while maintaining customer satisfaction.

4. **Implement seller scorecard reviews** — Use the composite risk score to trigger quarterly reviews for High Risk sellers. Sellers with risk_score > 0.85 across both late rate and satisfaction should face performance improvement plans or marketplace restrictions.

5. **Prioritize Black Friday logistics planning** — November shows a consistent SLA degradation spike. Pre-positioning inventory and pre-negotiating carrier capacity before October would protect the highest-revenue month of the year.

---

## Project Structure

```
Olist_Retail_Analytics/
├── 01_raw_data/          ← Original CSV files (unmodified)
├── 02_excel/
│   ├── olist_exploration.xlsx    ← Data profiling workbook
│   │   ├── Sheet: Data_Dictionary
│   │   ├── Sheet: Quality_Report
│   │   └── Sheet: Findings
│   └── screenshots/              ← Pivot table captures
├── 03_sql/
│   ├── 01_ddl_sqlserver.sql
│   ├── 01_ddl_mysql.sql
│   ├── 02_data_load_sqlserver.sql
│   ├── 02_data_load_mysql.sql
│   ├── 03_views.sql
│   └── 04_analysis.sql
├── 04_powerbi/
│   └── olist_dashboard.pbix      ← (in progress)
└── README.md
```

---

## Tools & Stack

| Tool | Usage |
|---|---|
| Microsoft Excel 365 | Data profiling, pivot analysis, findings documentation |
| SQL Server / SSMS | Primary engine — DDL, data load, views, analysis |
| MySQL / Workbench | Parallel validation environment |
| Power BI Desktop | Star schema model, DAX measures, executive dashboard |

---

## Dataset

Brazilian E-Commerce Public Dataset by Olist
Source: [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
License: CC BY-NC-SA 4.0
Period: October 2016 — August 2018
