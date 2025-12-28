-- 059_commission_workspace.sql
-- 佣金流程 Workspace 視圖 - Decision Table 模式
-- Date: 2025-12-28

-- ============================================================================
-- 1. 佣金 Workspace 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_commission_workspace CASCADE;

CREATE VIEW v_commission_workspace AS
SELECT
    -- 佣金基本資訊
    comm.id AS commission_id,
    comm.accounting_firm_id,
    comm.customer_id,
    comm.contract_id,
    comm.amount,
    comm.based_on_rent,
    comm.contract_start,
    comm.eligible_date,
    comm.status,
    comm.paid_at,
    comm.payment_method,
    comm.payment_reference,
    comm.notes,
    comm.created_at,
    comm.updated_at,

    -- 會計事務所資訊
    af.name AS firm_name,
    af.short_name AS firm_short_name,
    af.contact_person AS firm_contact,
    af.phone AS firm_phone,
    af.email AS firm_email,
    af.commission_rate,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.phone AS customer_phone,

    -- 合約資訊
    c.contract_number,
    c.position_number,
    c.status AS contract_status,
    c.start_date AS contract_start_date,
    c.end_date AS contract_end_date,
    c.monthly_rent,

    -- 場館資訊
    b.id AS branch_id,
    b.code AS branch_code,
    b.name AS branch_name,

    -- ========== 計算欄位 ==========

    -- 流程識別
    'commission'::TEXT AS process_key,
    comm.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(
        COALESCE(af.short_name, af.name, '無事務所'),
        ' - ',
        cust.name,
        ' ($', comm.amount::INT, ')'
    ) AS title,

    -- 距離可付款日天數
    CASE
        WHEN comm.eligible_date IS NOT NULL
        THEN comm.eligible_date - CURRENT_DATE
        ELSE NULL
    END AS days_until_eligible,

    -- 可付款後天數
    CASE
        WHEN comm.status = 'eligible' AND comm.eligible_date IS NOT NULL
        THEN CURRENT_DATE - comm.eligible_date
        ELSE NULL
    END AS days_since_eligible,

    -- 是否已達可付款日
    CASE
        WHEN comm.eligible_date IS NOT NULL AND comm.eligible_date <= CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS is_eligible,

    -- 是否付款逾期（可付款後超過 30 天）
    CASE
        WHEN comm.status = 'eligible'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date < CURRENT_DATE - 30
        THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- ========== Decision Table（卡點判斷，first-match wins） ==========

    CASE
        -- 已付款/已取消 = 無卡點
        WHEN comm.status IN ('paid', 'cancelled')
        THEN NULL

        -- 合約已終止且未付款 = 需確認
        WHEN c.status = 'terminated' AND comm.status = 'pending'
        THEN 'contract_terminated'

        -- 優先序 1：付款逾期（可付款後 30 天）
        WHEN comm.status = 'eligible'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date < CURRENT_DATE - 30
        THEN 'payment_overdue'

        -- 優先序 2：可付款
        WHEN comm.status = 'eligible'
        THEN 'ready_to_pay'

        -- 優先序 3：即將可付款（7 天內）
        WHEN comm.status = 'pending'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date <= CURRENT_DATE + 7
         AND comm.eligible_date > CURRENT_DATE
        THEN 'almost_eligible'

        -- 優先序 4：等待滿 6 個月
        WHEN comm.status = 'pending'
        THEN 'waiting_eligibility'

        ELSE NULL
    END AS decision_blocked_by,

    -- 下一步行動（繁體中文，顯示用）
    CASE
        WHEN comm.status IN ('paid', 'cancelled')
        THEN NULL
        WHEN c.status = 'terminated' AND comm.status = 'pending'
        THEN '確認是否取消佣金'
        WHEN comm.status = 'eligible'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date < CURRENT_DATE - 30
        THEN '儘速支付佣金'
        WHEN comm.status = 'eligible'
        THEN '支付佣金給事務所'
        WHEN comm.status = 'pending'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date <= CURRENT_DATE + 7
        THEN '準備支付（7天內到期）'
        WHEN comm.status = 'pending'
        THEN CONCAT('等待滿 6 個月 (', comm.eligible_date, ')')
        ELSE NULL
    END AS decision_next_action,

    -- 行動代碼（程式用）
    CASE
        WHEN comm.status IN ('paid', 'cancelled')
        THEN NULL
        WHEN c.status = 'terminated' AND comm.status = 'pending'
        THEN 'CANCEL_COMMISSION'
        WHEN comm.status = 'eligible'
        THEN 'PAY_COMMISSION'
        WHEN comm.status = 'pending'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date <= CURRENT_DATE + 7
        THEN 'MARK_ELIGIBLE'
        ELSE NULL
    END AS decision_action_key,

    -- 責任人
    CASE
        WHEN comm.status IN ('paid', 'cancelled')
        THEN NULL
        WHEN c.status = 'terminated'
        THEN 'Admin'
        WHEN comm.status = 'eligible'
        THEN 'Finance'
        ELSE NULL  -- pending 狀態無需行動
    END AS decision_owner,

    -- 優先級
    CASE
        WHEN comm.status IN ('paid', 'cancelled')
        THEN NULL
        WHEN c.status = 'terminated' AND comm.status = 'pending'
        THEN 'medium'
        WHEN comm.status = 'eligible'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date < CURRENT_DATE - 30
        THEN 'high'
        WHEN comm.status = 'eligible'
        THEN 'medium'
        WHEN comm.status = 'pending'
         AND comm.eligible_date IS NOT NULL
         AND comm.eligible_date <= CURRENT_DATE + 7
        THEN 'low'
        ELSE NULL
    END AS decision_priority,

    -- 應處理日期
    comm.eligible_date AS decision_due_date,

    -- Workspace URL
    CONCAT('/commissions/', comm.id) AS workspace_url

FROM commissions comm
LEFT JOIN accounting_firms af ON comm.accounting_firm_id = af.id
JOIN customers cust ON comm.customer_id = cust.id
JOIN contracts c ON comm.contract_id = c.id
JOIN branches b ON c.branch_id = b.id;

COMMENT ON VIEW v_commission_workspace IS '佣金流程 Workspace 視圖 - Decision Table 模式';

GRANT SELECT ON v_commission_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 佣金待辦清單視圖（僅顯示需處理項目）
-- ============================================================================

DROP VIEW IF EXISTS v_commission_queue CASCADE;

CREATE VIEW v_commission_queue AS
SELECT *
FROM v_commission_workspace
WHERE decision_blocked_by IS NOT NULL
  AND decision_blocked_by != 'waiting_eligibility'  -- 排除等待中的
ORDER BY
    CASE decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
    END,
    is_overdue DESC,
    decision_due_date ASC NULLS LAST;

COMMENT ON VIEW v_commission_queue IS '佣金待辦清單 - 僅顯示需處理項目';

GRANT SELECT ON v_commission_queue TO anon, authenticated;

-- ============================================================================
-- 3. Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_commission_dashboard_stats CASCADE;

CREATE VIEW v_commission_dashboard_stats AS
SELECT
    COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE status = 'eligible') AS eligible_count,
    COUNT(*) FILTER (WHERE status = 'paid') AS paid_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_overdue') AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'ready_to_pay') AS ready_to_pay_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'almost_eligible') AS almost_eligible_count,
    SUM(amount) FILTER (WHERE status = 'eligible') AS total_eligible_amount,
    SUM(amount) FILTER (WHERE status = 'paid') AS total_paid_amount
FROM v_commission_workspace;

COMMENT ON VIEW v_commission_dashboard_stats IS '佣金 Dashboard 統計';

GRANT SELECT ON v_commission_dashboard_stats TO anon, authenticated;
