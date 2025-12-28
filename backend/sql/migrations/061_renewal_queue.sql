-- 061_renewal_queue.sql
-- 續約流程 Queue 視圖 + Dashboard 統計
-- Date: 2025-12-28
--
-- 補充 v_contract_workspace 缺少的 decision_priority 欄位
-- 與其他流程（付款/發票/佣金）保持一致的 Decision Table 介面

-- ============================================================================
-- 1. 續約待辦清單視圖（含 decision_priority）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_queue CASCADE;

CREATE VIEW v_renewal_queue AS
SELECT
    -- 從 workspace 繼承所有欄位
    cw.*,

    -- 流程識別（統一介面）
    'renewal'::TEXT AS process_key,
    cw.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(cw.position_number, ' ', cw.customer_name) AS title,

    -- 是否逾期（根據卡點判斷）
    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN TRUE
        WHEN cw.days_until_expiry < 0 AND cw.next_contract_id IS NULL THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- 逾期天數
    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN cw.days_pending_sign
        WHEN cw.days_until_expiry < 0 THEN ABS(cw.days_until_expiry)
        ELSE 0
    END AS overdue_days,

    -- 應處理日期
    cw.end_date AS decision_due_date,

    -- Workspace URL
    CONCAT('/contracts/', cw.id, '/workspace') AS workspace_url,

    -- ========== 補充 decision_priority ==========
    CASE
        -- 回簽逾期 = 緊急
        WHEN cw.decision_blocked_by = 'signing_overdue'
        THEN 'urgent'

        -- 款項未入帳 = 高
        WHEN cw.decision_blocked_by = 'payment_pending'
        THEN 'high'

        -- 發票未開 = 中
        WHEN cw.decision_blocked_by = 'invoice_pending'
        THEN 'medium'

        -- 需要建立續約 = 根據剩餘天數
        WHEN cw.decision_blocked_by = 'need_create_renewal'
        THEN CASE
            WHEN cw.days_until_expiry <= 0 THEN 'urgent'
            WHEN cw.days_until_expiry <= 14 THEN 'high'
            WHEN cw.days_until_expiry <= 30 THEN 'medium'
            ELSE 'low'
        END

        -- 其他有卡點的 = 中
        WHEN cw.decision_blocked_by IS NOT NULL
        THEN 'medium'

        ELSE NULL
    END AS decision_priority,

    -- 行動代碼（供 ActionDispatcher 使用）
    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal'
        THEN 'CREATE_DRAFT'

        WHEN cw.decision_blocked_by = 'signing_overdue'
        THEN 'SEND_FOR_SIGN'  -- 催簽

        WHEN cw.decision_blocked_by = 'payment_pending'
        THEN 'SEND_REMINDER'

        WHEN cw.decision_blocked_by = 'invoice_pending'
        THEN 'ISSUE_INVOICE'

        ELSE NULL
    END AS decision_action_key

FROM v_contract_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
  AND cw.decision_blocked_by != 'completed'
  AND cw.status = 'active'  -- 只看進行中的合約
ORDER BY
    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 1
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 0 THEN 2
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 3
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 14 THEN 4
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 5
        ELSE 6
    END,
    cw.days_until_expiry ASC NULLS LAST;

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 - 僅顯示需處理項目，含 decision_priority';

GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 2. Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_dashboard_stats CASCADE;

CREATE VIEW v_renewal_dashboard_stats AS
SELECT
    -- 總數
    COUNT(*) AS total_action_needed,

    -- 按優先級統計
    COUNT(*) FILTER (
        WHERE decision_blocked_by = 'signing_overdue'
           OR (decision_blocked_by = 'need_create_renewal' AND days_until_expiry <= 0)
    ) AS urgent_count,

    COUNT(*) FILTER (
        WHERE decision_blocked_by = 'payment_pending'
           OR (decision_blocked_by = 'need_create_renewal' AND days_until_expiry > 0 AND days_until_expiry <= 14)
    ) AS high_count,

    -- 按卡點統計
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_create_renewal') AS need_create_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'signing_overdue') AS signing_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_pending') AS payment_pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_pending') AS invoice_pending_count,

    -- 逾期統計
    COUNT(*) FILTER (
        WHERE decision_blocked_by = 'signing_overdue'
           OR (decision_blocked_by = 'need_create_renewal' AND days_until_expiry < 0)
    ) AS overdue_count,

    -- 即將到期統計
    COUNT(*) FILTER (WHERE days_until_expiry BETWEEN 0 AND 30) AS expiring_soon_count,
    COUNT(*) FILTER (WHERE days_until_expiry BETWEEN 0 AND 7) AS expiring_this_week_count

FROM v_contract_workspace
WHERE decision_blocked_by IS NOT NULL
  AND decision_blocked_by != 'completed'
  AND status = 'active';

COMMENT ON VIEW v_renewal_dashboard_stats IS '續約 Dashboard 統計';

GRANT SELECT ON v_renewal_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 061 完成 ===';
    RAISE NOTICE '✅ v_renewal_queue 視圖已建立（含 decision_priority）';
    RAISE NOTICE '✅ v_renewal_dashboard_stats 視圖已建立';
    RAISE NOTICE '';
    RAISE NOTICE '使用方式：';
    RAISE NOTICE '- 待辦清單：SELECT * FROM v_renewal_queue';
    RAISE NOTICE '- 統計資料：SELECT * FROM v_renewal_dashboard_stats';
END $$;
