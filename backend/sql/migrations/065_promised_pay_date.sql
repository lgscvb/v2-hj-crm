-- 065_promised_pay_date.sql
-- 新增「客戶承諾付款日期」欄位
-- Date: 2025-12-29
--
-- 用途：
-- - 記錄客戶承諾的付款日期
-- - 自動催繳邏輯會跳過已有承諾日期（且未過期）的付款
-- - 避免業務與客戶協調後系統仍持續催繳

-- ============================================================================
-- 1. 新增欄位
-- ============================================================================

ALTER TABLE payments
ADD COLUMN IF NOT EXISTS promised_pay_date DATE;

COMMENT ON COLUMN payments.promised_pay_date IS '客戶承諾付款日期';

-- ============================================================================
-- 2. 更新 v_payment_workspace 視圖，加入承諾日期相關欄位
-- ============================================================================

-- 先備份原視圖定義（查看現有欄位）
-- 注意：這會 DROP CASCADE 相關視圖，稍後需重建

DROP VIEW IF EXISTS v_payment_queue CASCADE;
DROP VIEW IF EXISTS v_payment_workspace CASCADE;

CREATE VIEW v_payment_workspace AS
SELECT
    -- 付款基本資訊
    p.id AS payment_id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.payment_status,
    p.due_date,
    p.paid_at,
    p.payment_method,
    p.payment_reference,

    -- 發票資訊
    p.invoice_number,
    p.invoice_date,
    p.invoice_status,

    -- 承諾付款日期
    p.promised_pay_date,

    -- 合約資訊
    c.contract_number,
    c.company_name AS contract_company_name,
    c.position_number,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- ========== 計算欄位 ==========

    -- 流程識別
    'payment'::TEXT AS process_key,
    p.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(c.position_number, ' ', cust.name, ' (', p.payment_period, ')') AS title,

    -- 逾期天數
    CASE
        WHEN p.payment_status = 'pending' AND p.due_date < CURRENT_DATE
        THEN CURRENT_DATE - p.due_date
        ELSE 0
    END AS actual_overdue_days,

    -- 是否逾期
    CASE
        WHEN p.payment_status = 'pending' AND p.due_date < CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- 是否有承諾付款日期（且未過期）
    CASE
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS has_valid_promise,

    -- 承諾日期剩餘天數
    CASE
        WHEN p.promised_pay_date IS NOT NULL
        THEN p.promised_pay_date - CURRENT_DATE
        ELSE NULL
    END AS days_until_promise,

    -- ========== Decision Table ==========

    CASE
        -- 已付款 = 無卡點
        WHEN p.payment_status = 'paid'
        THEN NULL

        -- 已取消/免收 = 無卡點
        WHEN p.payment_status IN ('cancelled', 'waived')
        THEN NULL

        -- 有效承諾日期 = 暫緩催繳
        WHEN p.promised_pay_date IS NOT NULL
         AND p.promised_pay_date >= CURRENT_DATE
        THEN 'waiting_promise'

        -- 承諾日期已過期 = 需要跟進
        WHEN p.promised_pay_date IS NOT NULL
         AND p.promised_pay_date < CURRENT_DATE
        THEN 'promise_overdue'

        -- 嚴重逾期（60天以上）
        WHEN p.payment_status = 'pending'
         AND p.due_date < CURRENT_DATE - INTERVAL '60 days'
        THEN 'severe_overdue'

        -- 需要存證信函（30天以上）
        WHEN p.payment_status = 'pending'
         AND p.due_date < CURRENT_DATE - INTERVAL '30 days'
        THEN 'need_legal_notice'

        -- 需要二次催繳（14天以上）
        WHEN p.payment_status = 'pending'
         AND p.due_date < CURRENT_DATE - INTERVAL '14 days'
        THEN 'need_second_reminder'

        -- 需要首次催繳（逾期）
        WHEN p.payment_status = 'pending'
         AND p.due_date < CURRENT_DATE
        THEN 'need_first_reminder'

        -- 即將到期（3天內）
        WHEN p.payment_status = 'pending'
         AND p.due_date <= CURRENT_DATE + INTERVAL '3 days'
        THEN 'due_soon'

        ELSE NULL
    END AS decision_blocked_by,

    -- 下一步行動（繁體中文）
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN CONCAT('等待客戶付款（承諾：', p.promised_pay_date, '）')
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date < CURRENT_DATE
        THEN '承諾日期已過，請跟進'
        WHEN p.due_date < CURRENT_DATE - INTERVAL '60 days'
        THEN '嚴重逾期，考慮法律途徑'
        WHEN p.due_date < CURRENT_DATE - INTERVAL '30 days'
        THEN '發送存證信函'
        WHEN p.due_date < CURRENT_DATE - INTERVAL '14 days'
        THEN '發送二次催繳'
        WHEN p.due_date < CURRENT_DATE
        THEN '發送催繳通知'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days'
        THEN '即將到期提醒'
        ELSE NULL
    END AS decision_next_action,

    -- 行動代碼
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN NULL  -- 等待中，不需行動
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date < CURRENT_DATE
        THEN 'SEND_REMINDER'
        WHEN p.due_date < CURRENT_DATE
        THEN 'SEND_REMINDER'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days'
        THEN 'SEND_REMINDER'
        ELSE NULL
    END AS decision_action_key,

    -- 責任人
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN p.due_date < CURRENT_DATE - INTERVAL '30 days'
        THEN 'Manager'  -- 嚴重逾期需主管介入
        ELSE 'Finance'
    END AS decision_owner,

    -- 優先級
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN 'low'  -- 有承諾日期，優先級降低
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date < CURRENT_DATE
        THEN 'high'  -- 承諾日期過期，需要跟進
        WHEN p.due_date < CURRENT_DATE - INTERVAL '60 days'
        THEN 'urgent'
        WHEN p.due_date < CURRENT_DATE - INTERVAL '30 days'
        THEN 'urgent'
        WHEN p.due_date < CURRENT_DATE - INTERVAL '14 days'
        THEN 'high'
        WHEN p.due_date < CURRENT_DATE
        THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days'
        THEN 'low'
        ELSE NULL
    END AS decision_priority,

    -- Workspace URL
    CONCAT('/payments/', p.id) AS workspace_url

FROM payments p
JOIN contracts c ON p.contract_id = c.id
JOIN customers cust ON p.customer_id = cust.id
JOIN branches b ON p.branch_id = b.id
WHERE p.amount > 0;

COMMENT ON VIEW v_payment_workspace IS '付款流程 Workspace 視圖（含承諾付款日期）';

GRANT SELECT ON v_payment_workspace TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_payment_queue 視圖
-- ============================================================================

CREATE VIEW v_payment_queue AS
SELECT
    pw.*,
    -- 優先級升級
    calculate_escalated_priority(
        pw.decision_priority,
        pw.actual_overdue_days
    ) AS escalated_priority
FROM v_payment_workspace pw
WHERE pw.decision_blocked_by IS NOT NULL
  AND pw.payment_status NOT IN ('paid', 'cancelled', 'waived')
ORDER BY
    CASE calculate_escalated_priority(pw.decision_priority, pw.actual_overdue_days)
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
    END,
    pw.is_overdue DESC,
    pw.due_date ASC;

COMMENT ON VIEW v_payment_queue IS '付款待辦清單（含承諾付款日期）';

GRANT SELECT ON v_payment_queue TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 065 完成 ===';
    RAISE NOTICE '✅ payments.promised_pay_date 欄位已新增';
    RAISE NOTICE '✅ v_payment_workspace 已更新（含承諾日期邏輯）';
    RAISE NOTICE '✅ v_payment_queue 已重建';
    RAISE NOTICE '';
    RAISE NOTICE '新增卡點類型：';
    RAISE NOTICE '- waiting_promise: 等待客戶承諾付款日';
    RAISE NOTICE '- promise_overdue: 承諾日期已過期';
END $$;
