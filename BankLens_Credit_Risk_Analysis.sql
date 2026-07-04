-- BankLens | MySQL 8.0+
-- Amount fields are New Taiwan Dollars (NTD), as documented by the UCI source.
CREATE DATABASE IF NOT EXISTS banklens_analytics;
USE banklens_analytics;

DROP TABLE IF EXISTS fact_payments;
DROP TABLE IF EXISTS fact_bills;
DROP TABLE IF EXISTS dim_clients;

CREATE TABLE dim_clients (
    client_id BIGINT NOT NULL PRIMARY KEY,
    limit_bal_ntd DECIMAL(16,2) NOT NULL,
    sex_code TINYINT NOT NULL,
    education_code TINYINT NOT NULL,
    marriage_code TINYINT NOT NULL,
    age TINYINT NOT NULL,
    credit_utilization_ratio DECIMAL(10,5) NOT NULL,
    ead_ntd DECIMAL(16,2) NOT NULL,
    pd_xgb_oof DECIMAL(10,8) NOT NULL,
    pd_scorecard_oof DECIMAL(10,8) NOT NULL,
    lgd_assumption DECIMAL(5,4) NOT NULL,
    expected_loss_ntd DECIMAL(16,2) NOT NULL,
    policy_action VARCHAR(32) NOT NULL,
    risk_decile TINYINT NOT NULL,
    default_flag TINYINT NOT NULL,
    CHECK (default_flag IN (0,1))
);

CREATE TABLE fact_bills (
    client_id BIGINT NOT NULL,
    statement_month TINYINT NOT NULL,
    repayment_status SMALLINT NOT NULL,
    bill_amount_ntd DECIMAL(16,2) NOT NULL,
    PRIMARY KEY (client_id, statement_month),
    CONSTRAINT fk_bills_client FOREIGN KEY (client_id) REFERENCES dim_clients(client_id)
);

CREATE TABLE fact_payments (
    client_id BIGINT NOT NULL,
    payment_month TINYINT NOT NULL,
    paid_amount_ntd DECIMAL(16,2) NOT NULL,
    PRIMARY KEY (client_id, payment_month),
    CONSTRAINT fk_payments_client FOREIGN KEY (client_id) REFERENCES dim_clients(client_id)
);

-- Query 1: Default rate by most recent repayment status.
SELECT repayment_status, COUNT(*) AS account_months,
       ROUND(AVG(default_flag) * 100, 2) AS default_rate_pct
FROM fact_bills b JOIN dim_clients c USING (client_id)
WHERE b.statement_month = 1
GROUP BY repayment_status
ORDER BY repayment_status;

-- Query 2: CTE + DENSE_RANK: highest-risk repayment cohorts within utilisation bands.
WITH client_segments AS (
    SELECT client_id, default_flag, credit_utilization_ratio,
           CASE WHEN credit_utilization_ratio < 0.30 THEN '<30%'
                WHEN credit_utilization_ratio < 0.50 THEN '30-50%'
                WHEN credit_utilization_ratio < 0.80 THEN '50-80%'
                ELSE '>=80%' END AS utilisation_band
    FROM dim_clients
), segment_risk AS (
    SELECT utilisation_band, COUNT(*) AS clients,
           ROUND(AVG(default_flag) * 100, 2) AS bad_rate_pct,
           ROUND(SUM(expected_loss_ntd), 2) AS expected_loss_ntd
    FROM client_segments JOIN dim_clients USING (client_id)
    GROUP BY utilisation_band
)
SELECT *, DENSE_RANK() OVER (ORDER BY bad_rate_pct DESC) AS risk_rank
FROM segment_risk ORDER BY risk_rank;

-- Query 3: NTILE(10): OOF model risk deciles and share of portfolio EL.
WITH ranked AS (
    SELECT client_id, default_flag, pd_xgb_oof, expected_loss_ntd,
           NTILE(10) OVER (ORDER BY pd_xgb_oof, client_id) AS risk_decile
    FROM dim_clients
)
SELECT risk_decile, COUNT(*) AS accounts,
       ROUND(AVG(default_flag) * 100, 2) AS observed_bad_rate_pct,
       ROUND(SUM(expected_loss_ntd), 2) AS expected_loss_ntd,
       ROUND(100 * SUM(expected_loss_ntd) / SUM(SUM(expected_loss_ntd)) OVER (), 2) AS portfolio_el_share_pct
FROM ranked GROUP BY risk_decile ORDER BY risk_decile;

-- Query 4: LAG(): month-over-month bill movement by client.
WITH bill_trend AS (
    SELECT client_id, statement_month, bill_amount_ntd,
           LAG(bill_amount_ntd) OVER (PARTITION BY client_id ORDER BY statement_month) AS prior_month_bill_ntd
    FROM fact_bills
)
SELECT client_id, statement_month, bill_amount_ntd, prior_month_bill_ntd,
       bill_amount_ntd - prior_month_bill_ntd AS bill_change_ntd
FROM bill_trend WHERE prior_month_bill_ntd IS NOT NULL
ORDER BY client_id, statement_month LIMIT 100;

-- Query 5: 0.28 policy simulation: active bad rate and expected-loss routed to intervention.
SELECT
  ROUND(AVG(CASE WHEN pd_xgb_oof < 0.28 THEN default_flag END) * 100, 2) AS active_bad_rate_pct,
  SUM(CASE WHEN pd_xgb_oof >= 0.28 THEN expected_loss_ntd ELSE 0 END) AS el_routed_to_policy_ntd,
  ROUND(100 * SUM(CASE WHEN pd_xgb_oof >= 0.28 THEN expected_loss_ntd ELSE 0 END)
        / NULLIF(SUM(expected_loss_ntd),0), 2) AS el_routed_pct
FROM dim_clients;
