-- ============================================================================
-- Migration 045: 修復 v_renewal_reminders 欄位相容性
--
-- 問題：前端使用 days_remaining，但視圖只有 days_until_expiry
-- 解法：新增 days_remaining 別名欄位
-- ============================================================================

-- 重建視圖，加入 days_remaining 相容欄位
DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;

CREATE VIEW v_renewal_reminders AS
SELECT
    ct.id,
    ct.contract_number,
    ct.customer_id,
    ct.branch_id,
    ct.contract_type,
    ct.plan_name,
    ct.start_date,
    ct.end_date,
    ct.monthly_rent,
    ct.deposit,
    ct.payment_cycle,
    ct.status AS contract_status,
    ct.position_number,
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_paid_at,
    ct.renewal_invoiced_at,
    ct.renewal_signed_at,
    ct.renewal_notes,
    ct.invoice_status,
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,  -- 相容舊前端
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,
    b.code AS branch_code,
    b.name AS branch_name,
    CASE
        WHEN ct.end_date - CURRENT_DATE <= 7 THEN 'urgent'
        WHEN ct.end_date - CURRENT_DATE <= 30 THEN 'high'
        WHEN ct.end_date - CURRENT_DATE <= 60 THEN 'medium'
        ELSE 'low'
    END AS priority,
    (SELECT COUNT(*) FROM contracts WHERE customer_id = ct.customer_id) AS total_contracts_history,
    EXISTS (
        SELECT 1 FROM contracts c2
        WHERE c2.renewed_from_id = ct.id
          AND c2.status IN ('active', 'renewal_draft')
    ) AS has_renewal_draft
FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'
  AND NOT EXISTS (
      SELECT 1 FROM contracts c2
      WHERE c2.renewed_from_id = ct.id
        AND c2.status IN ('active', 'renewal_draft')
  )
  AND ct.renewal_signed_at IS NULL
ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖（V2）- 排除已有續約草稿和已簽約的合約';
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- 重建 v_monthly_reminders_summary
CREATE VIEW v_monthly_reminders_summary AS
SELECT
    branch_id,
    branch_name,
    COUNT(*) AS total_reminders,
    COUNT(*) FILTER (WHERE priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE priority = 'high') AS high_count
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 045 completed: Added days_remaining alias for frontend compatibility' AS status;
