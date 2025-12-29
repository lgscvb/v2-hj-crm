-- 074_align_overdue_with_promised_date.sql
-- 逾期清單與 promised_pay_date 邏輯對齊
--
-- 問題：
-- - v_payment_workspace 已納入 promised_pay_date（has_valid_promise）
-- - 但 v_overdue_details 和 v_payments_due 仍用 due_date 判斷逾期
-- - 導致「Workspace 顯示等待承諾，但逾期清單仍列出」的矛盾
--
-- 解法（採 B 方案：仍列清單但標記承諾）：
-- - 新增 effective_due_date = COALESCE(promised_pay_date, due_date)
-- - 新增 is_promised、promised_pay_date 欄位
-- - urgency 加入 'waiting_promise' 狀態
-- - 只有 effective_due_date < CURRENT_DATE 才視為逾期
--
-- Date: 2025-12-29

-- ============================================================================
-- 1. 重建 v_overdue_details 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_overdue_details CASCADE;

CREATE VIEW v_overdue_details AS
SELECT
    p.id AS payment_id,
    p.customer_id,
    cu.name AS customer_name,
    cu.company_name,
    cu.phone,
    cu.line_user_id,
    p.contract_id,
    c.contract_number,
    p.branch_id,
    b.name AS branch_name,
    p.amount AS total_due,
    p.due_date,
    p.payment_period,

    -- 承諾付款日期相關欄位
    p.promised_pay_date,
    CASE
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS is_promised,

    -- 有效到期日（優先使用承諾日期）
    COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,

    -- 逾期天數（基於有效到期日）
    CASE
        WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
        THEN CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)
        ELSE 0
    END AS days_overdue,

    -- 緊急度（含等待承諾狀態）
    CASE
        -- 有承諾日期且未過期 → 等待承諾
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN 'waiting_promise'
        -- 承諾已過期或無承諾 → 用 effective_due_date 判斷
        WHEN (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) <= 7
        THEN 'warning'
        WHEN (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) <= 30
        THEN 'danger'
        ELSE 'critical'
    END AS urgency_level

FROM payments p
JOIN customers cu ON p.customer_id = cu.id
LEFT JOIN contracts c ON p.contract_id = c.id
LEFT JOIN branches b ON p.branch_id = b.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 使用 effective_due_date 判斷是否逾期
  AND COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
  AND p.amount > 0
  AND COALESCE(c.is_billable, true) = true
ORDER BY
    -- 等待承諾的排在最後（給客戶時間）
    CASE WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE THEN 1 ELSE 0 END,
    -- 其餘按有效到期日排序
    COALESCE(p.promised_pay_date, p.due_date) ASC;

COMMENT ON VIEW v_overdue_details IS
'逾期款項詳情視圖（納入 promised_pay_date，等待承諾的降低優先級）';

GRANT SELECT ON v_overdue_details TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_payments_due 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_payments_due CASCADE;

CREATE VIEW v_payments_due AS
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

    -- 承諾付款日期相關欄位
    p.promised_pay_date,
    CASE
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS is_promised,

    -- 有效到期日
    COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,

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
    ct.status AS contract_status,

    -- 緊急度計算（含等待承諾狀態）
    CASE
        -- 有承諾日期且未過期 → 等待承諾（不催繳）
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN 'waiting_promise'
        -- 逾期判斷（基於有效到期日）
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 30
        THEN 'critical'
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 14
        THEN 'high'
        WHEN p.payment_status = 'overdue'
        THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days'
        THEN 'upcoming'
        ELSE 'normal'
    END AS urgency,

    -- 總應收金額
    p.amount + COALESCE(p.late_fee, 0) AS total_due

FROM payments p
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
LEFT JOIN contracts ct ON p.contract_id = ct.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 排除解約中/已解約的合約
  AND (ct.status IS NULL OR ct.status NOT IN ('pending_termination', 'terminated'))
  -- 排除非計費合約（內部/免租金座位）
  AND (ct.is_billable IS NULL OR ct.is_billable = true)
ORDER BY
    -- 等待承諾的排在最後
    CASE WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE THEN 1 ELSE 0 END,
    -- 其餘按原本排序
    CASE WHEN p.payment_status = 'overdue' THEN 0 ELSE 1 END,
    p.due_date ASC;

COMMENT ON VIEW v_payments_due IS
'應收款列表，含緊急度標記（納入 promised_pay_date，等待承諾的不催繳）';

GRANT SELECT ON v_payments_due TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    v_overdue_count INT;
    v_promised_count INT;
BEGIN
    -- 計算逾期款項數量
    SELECT COUNT(*) INTO v_overdue_count FROM v_overdue_details;

    -- 計算等待承諾的數量
    SELECT COUNT(*) INTO v_promised_count
    FROM v_payments_due
    WHERE urgency = 'waiting_promise';

    RAISE NOTICE '=== Migration 074 完成 ===';
    RAISE NOTICE '✅ v_overdue_details 已納入 promised_pay_date';
    RAISE NOTICE '✅ v_payments_due 已納入 promised_pay_date';
    RAISE NOTICE '逾期款項數量: %', v_overdue_count;
    RAISE NOTICE '等待承諾數量: %', v_promised_count;
    RAISE NOTICE '';
    RAISE NOTICE '新增欄位說明：';
    RAISE NOTICE '- promised_pay_date: 客戶承諾付款日期';
    RAISE NOTICE '- is_promised: 是否有有效承諾（TRUE = 承諾日未過期）';
    RAISE NOTICE '- effective_due_date: 有效到期日（優先使用承諾日期）';
    RAISE NOTICE '- urgency = waiting_promise: 有承諾且未過期，不催繳';
END $$;
