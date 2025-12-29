-- 067_payment_dashboard_stats.sql
-- 付款 Dashboard 統計視圖
-- Date: 2025-12-29

-- ============================================================================
-- 1. 建立付款 Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_payment_dashboard_stats CASCADE;

CREATE VIEW v_payment_dashboard_stats AS
SELECT
    -- 總計
    COUNT(*) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_action_needed,

    -- 按卡點分類
    COUNT(*) FILTER (WHERE decision_blocked_by = 'waiting_promise') AS waiting_promise_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'promise_overdue') AS promise_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'severe_overdue') AS severe_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_legal_notice') AS need_legal_notice_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_second_reminder') AS need_second_reminder_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_first_reminder') AS need_first_reminder_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'due_soon') AS due_soon_count,

    -- 逾期統計
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,

    -- 金額統計
    COALESCE(SUM(amount) FILTER (WHERE decision_blocked_by IS NOT NULL), 0) AS total_pending_amount,
    COALESCE(SUM(amount) FILTER (WHERE is_overdue = TRUE), 0) AS total_overdue_amount

FROM v_payment_workspace
WHERE payment_status NOT IN ('paid', 'cancelled', 'waived');

COMMENT ON VIEW v_payment_dashboard_stats IS '付款 Dashboard 統計';

GRANT SELECT ON v_payment_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 067 完成 ===';
    RAISE NOTICE '✅ v_payment_dashboard_stats 視圖已建立';
END $$;
