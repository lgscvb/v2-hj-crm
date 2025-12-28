-- 057_payment_workspace.sql
-- 付款流程 Workspace 視圖 - Decision Table 模式
-- Date: 2025-12-28

-- ============================================================================
-- 1. 付款 Workspace 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_payment_workspace CASCADE;

CREATE VIEW v_payment_workspace AS
WITH
-- 最近一次催繳記錄
last_reminders AS (
    SELECT DISTINCT ON (payment_id)
        payment_id,
        created_at AS last_reminder_at,
        status AS last_reminder_status
    FROM notification_logs
    WHERE notification_type = 'payment_reminder'
      AND payment_id IS NOT NULL
    ORDER BY payment_id, created_at DESC
),
-- 客戶風險標籤
customer_risk AS (
    SELECT
        id AS customer_id,
        CASE
            WHEN traits->'tags' ? 'payment_risk' THEN TRUE
            ELSE FALSE
        END AS is_high_risk
    FROM customers
)
SELECT
    -- 付款基本資訊
    p.id AS payment_id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.late_fee,
    p.payment_method,
    p.payment_status,
    p.due_date,
    p.paid_at,
    p.invoice_number,
    p.invoice_date,
    p.invoice_status,
    p.overdue_days,
    p.notes,
    p.created_at,
    p.updated_at,

    -- 合約資訊
    c.contract_number,
    c.status AS contract_status,
    c.company_name,
    c.position_number,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 風險標籤
    COALESCE(cr.is_high_risk, FALSE) AS is_high_risk,

    -- 催繳記錄
    lr.last_reminder_at,
    lr.last_reminder_status,

    -- ========== 計算欄位 ==========

    -- 流程識別
    'payment'::TEXT AS process_key,
    p.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(c.position_number, ' ', cust.name, ' (', p.payment_period, ')') AS title,

    -- 距到期天數（負數表示已逾期）
    p.due_date - CURRENT_DATE AS days_until_due,

    -- 是否逾期
    CASE
        WHEN p.payment_status = 'paid' THEN FALSE
        WHEN p.payment_status = 'cancelled' THEN FALSE
        WHEN p.payment_status = 'waived' THEN FALSE
        WHEN p.due_date < CURRENT_DATE THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- 實際逾期天數
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived') THEN 0
        WHEN p.due_date < CURRENT_DATE THEN CURRENT_DATE - p.due_date
        ELSE 0
    END AS actual_overdue_days,

    -- 催繳後天數（距上次催繳）
    CASE
        WHEN lr.last_reminder_at IS NOT NULL
        THEN EXTRACT(DAY FROM NOW() - lr.last_reminder_at)::INT
        ELSE NULL
    END AS days_since_reminder,

    -- ========== Decision Table（卡點判斷，first-match wins） ==========

    CASE
        -- 已付/已取消/已免收 = 無卡點
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL

        -- 優先序 1：高風險客戶逾期 - 最高優先
        WHEN COALESCE(cr.is_high_risk, FALSE) = TRUE
         AND p.due_date < CURRENT_DATE
        THEN 'high_risk_overdue'

        -- 優先序 2：嚴重逾期（超過 60 天）
        WHEN p.due_date < CURRENT_DATE - 60
        THEN 'severe_overdue'

        -- 優先序 3：超過 30 天需存證信函
        WHEN p.due_date < CURRENT_DATE - 30
        THEN 'need_legal_notice'

        -- 優先序 4：超過 14 天需再次催繳
        WHEN p.due_date < CURRENT_DATE - 14
         AND (lr.last_reminder_at IS NULL OR lr.last_reminder_at < NOW() - INTERVAL '7 days')
        THEN 'need_second_reminder'

        -- 優先序 5：首次逾期需催繳（1-14 天）
        WHEN p.due_date < CURRENT_DATE
         AND lr.last_reminder_at IS NULL
        THEN 'need_first_reminder'

        -- 優先序 6：3 天內到期
        WHEN p.due_date <= CURRENT_DATE + 3
         AND p.due_date >= CURRENT_DATE
        THEN 'due_soon'

        -- 其他未付款
        WHEN p.payment_status = 'pending'
        THEN NULL

        ELSE NULL
    END AS decision_blocked_by,

    -- 下一步行動（繁體中文，顯示用）
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN COALESCE(cr.is_high_risk, FALSE) = TRUE
         AND p.due_date < CURRENT_DATE
        THEN '高風險客戶催款 - 需主管關注'
        WHEN p.due_date < CURRENT_DATE - 60
        THEN '嚴重逾期 - 考慮法律途徑'
        WHEN p.due_date < CURRENT_DATE - 30
        THEN '發送存證信函'
        WHEN p.due_date < CURRENT_DATE - 14
         AND (lr.last_reminder_at IS NULL OR lr.last_reminder_at < NOW() - INTERVAL '7 days')
        THEN '再次發送催繳通知'
        WHEN p.due_date < CURRENT_DATE
         AND lr.last_reminder_at IS NULL
        THEN '發送首次催繳通知'
        WHEN p.due_date <= CURRENT_DATE + 3
         AND p.due_date >= CURRENT_DATE
        THEN '即將到期提醒'
        ELSE NULL
    END AS decision_next_action,

    -- 行動代碼（程式用）
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN COALESCE(cr.is_high_risk, FALSE) = TRUE
         AND p.due_date < CURRENT_DATE
        THEN 'SEND_REMINDER'
        WHEN p.due_date < CURRENT_DATE - 60
        THEN 'SEND_LEGAL_NOTICE'
        WHEN p.due_date < CURRENT_DATE - 30
        THEN 'SEND_LEGAL_NOTICE'
        WHEN p.due_date < CURRENT_DATE - 14
         AND (lr.last_reminder_at IS NULL OR lr.last_reminder_at < NOW() - INTERVAL '7 days')
        THEN 'SEND_REMINDER'
        WHEN p.due_date < CURRENT_DATE
         AND lr.last_reminder_at IS NULL
        THEN 'SEND_REMINDER'
        WHEN p.due_date <= CURRENT_DATE + 3
         AND p.due_date >= CURRENT_DATE
        THEN 'SEND_REMINDER'
        ELSE NULL
    END AS decision_action_key,

    -- 責任人
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN p.due_date < CURRENT_DATE - 30
        THEN 'Admin'  -- 存證信函需要管理階層處理
        ELSE 'Finance'
    END AS decision_owner,

    -- 優先級
    CASE
        WHEN p.payment_status IN ('paid', 'cancelled', 'waived')
        THEN NULL
        WHEN COALESCE(cr.is_high_risk, FALSE) = TRUE
         AND p.due_date < CURRENT_DATE
        THEN 'urgent'
        WHEN p.due_date < CURRENT_DATE - 60
        THEN 'urgent'
        WHEN p.due_date < CURRENT_DATE - 30
        THEN 'high'
        WHEN p.due_date < CURRENT_DATE - 14
        THEN 'high'
        WHEN p.due_date < CURRENT_DATE
        THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + 3
        THEN 'low'
        ELSE NULL
    END AS decision_priority,

    -- 應處理日期
    p.due_date AS decision_due_date,

    -- Workspace URL
    CONCAT('/payments/', p.id) AS workspace_url

FROM payments p
JOIN contracts c ON p.contract_id = c.id
JOIN customers cust ON p.customer_id = cust.id
JOIN branches b ON p.branch_id = b.id
LEFT JOIN customer_risk cr ON cr.customer_id = cust.id
LEFT JOIN last_reminders lr ON lr.payment_id = p.id
WHERE p.amount > 0;  -- 排除零金額

COMMENT ON VIEW v_payment_workspace IS '付款流程 Workspace 視圖 - Decision Table 模式';

GRANT SELECT ON v_payment_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 付款待辦清單視圖（僅顯示需處理項目）
-- ============================================================================

DROP VIEW IF EXISTS v_payment_queue CASCADE;

CREATE VIEW v_payment_queue AS
SELECT *
FROM v_payment_workspace
WHERE decision_blocked_by IS NOT NULL
  AND payment_status NOT IN ('paid', 'cancelled', 'waived')
ORDER BY
    CASE decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
    END,
    is_overdue DESC,
    due_date ASC;

COMMENT ON VIEW v_payment_queue IS '付款待辦清單 - 僅顯示需處理項目';

GRANT SELECT ON v_payment_queue TO anon, authenticated;

-- ============================================================================
-- 3. Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_payment_dashboard_stats CASCADE;

CREATE VIEW v_payment_dashboard_stats AS
SELECT
    COUNT(*) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE decision_priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'high_risk_overdue') AS high_risk_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'severe_overdue') AS severe_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_legal_notice') AS need_legal_count,
    COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_first_reminder', 'need_second_reminder')) AS need_reminder_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'due_soon') AS due_soon_count,
    SUM(amount) FILTER (WHERE is_overdue = TRUE AND payment_status = 'pending') AS total_overdue_amount
FROM v_payment_workspace
WHERE payment_status NOT IN ('paid', 'cancelled', 'waived');

COMMENT ON VIEW v_payment_dashboard_stats IS '付款 Dashboard 統計';

GRANT SELECT ON v_payment_dashboard_stats TO anon, authenticated;
