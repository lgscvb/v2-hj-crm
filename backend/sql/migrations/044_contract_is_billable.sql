-- ============================================================================
-- Migration 044: 新增合約計費標記
--
-- 目的：區分需要產生應收帳款的合約和不需要的合約
--
-- 使用場景：
-- - 內部使用的座位（如公司自用）
-- - 合作夥伴免租金座位
-- - 這些座位需要顯示在平面圖，但不應產生繳費記錄
--
-- 影響：
-- - 平面圖：不受影響（繼續顯示所有 active 合約）
-- - 繳費管理：只顯示 is_billable = true 的合約
-- ============================================================================

-- 1. 新增欄位
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS is_billable BOOLEAN DEFAULT true;

COMMENT ON COLUMN contracts.is_billable IS '是否需要產生應收帳款。false = 內部/免租金座位，不產生繳費記錄但仍顯示在平面圖';

-- 2. 更新特定合約為不計費
-- 樞紐前沿股份有限公司 (contract_id = 1242)
-- 韌帶斷裂有限公司 (contract_id = 1243)
UPDATE contracts
SET is_billable = false
WHERE id IN (1242, 1243);

-- 3. 建立索引（加速繳費查詢）
CREATE INDEX IF NOT EXISTS idx_contracts_is_billable ON contracts(is_billable) WHERE is_billable = true;

-- 4. 重建 v_payments_due 視圖（加入 is_billable 過濾）
CREATE OR REPLACE VIEW v_payments_due AS
SELECT
    p.id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.late_fee,
    p.due_date,
    p.payment_status,
    p.overdue_days,
    p.notes,
    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.line_user_id,
    c.risk_level,
    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,
    -- 合約資訊
    ct.contract_number,
    ct.monthly_rent,
    ct.end_date AS contract_end_date,
    -- 緊急度計算
    CASE
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 30 THEN 'critical'
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 14 THEN 'high'
        WHEN p.payment_status = 'overdue' THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days' THEN 'upcoming'
        ELSE 'normal'
    END AS urgency,
    -- 總應收金額
    p.amount + COALESCE(p.late_fee, 0) AS total_due
FROM payments p
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
LEFT JOIN contracts ct ON p.contract_id = ct.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 排除非計費合約（內部/免租金座位）
  AND (ct.is_billable IS NULL OR ct.is_billable = true)
ORDER BY
    CASE
        WHEN p.payment_status = 'overdue' THEN 0
        ELSE 1
    END,
    p.due_date ASC;

COMMENT ON VIEW v_payments_due IS '應收款列表，含緊急度標記（排除 is_billable=false 的合約）';

-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 044 completed: Added is_billable column to contracts' AS status;
SELECT id, contract_number, is_billable
FROM contracts
WHERE id IN (1242, 1243);
