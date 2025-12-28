-- 062_termination_queue.sql
-- 解約流程 Queue 視圖 + Dashboard 統計
-- Date: 2025-12-28
--
-- 補充 v_termination_workspace 缺少的 decision_priority 欄位
-- 與其他流程（付款/發票/佣金）保持一致的 Decision Table 介面

-- ============================================================================
-- 1. 解約待辦清單視圖（含 decision_priority）
-- ============================================================================

DROP VIEW IF EXISTS v_termination_queue CASCADE;

CREATE VIEW v_termination_queue AS
SELECT
    -- 從 workspace 繼承所有欄位
    tw.*,

    -- 流程識別（統一介面）
    'termination'::TEXT AS process_key,
    tw.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(tw.position_number, ' ', tw.customer_name, ' - ', tw.type_label) AS title,

    -- 是否逾期
    CASE
        WHEN tw.is_doc_overdue THEN TRUE
        WHEN tw.is_settlement_overdue THEN TRUE
        WHEN tw.is_refund_overdue THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- 逾期天數
    CASE
        WHEN tw.is_doc_overdue THEN tw.days_waiting_doc
        WHEN tw.is_settlement_overdue THEN CURRENT_DATE - tw.doc_approved_date
        WHEN tw.is_refund_overdue THEN CURRENT_DATE - tw.settlement_date
        ELSE 0
    END AS overdue_days,

    -- 應處理日期（預計搬遷日）
    tw.expected_end_date AS decision_due_date,

    -- Workspace URL
    CONCAT('/terminations/', tw.id) AS workspace_url,

    -- ========== 補充 decision_priority ==========
    CASE
        -- 逾期項目 = 緊急/高
        WHEN tw.decision_blocked_by IN ('doc_overdue', 'settlement_overdue', 'refund_overdue')
        THEN 'urgent'

        -- 等待中的項目 = 中
        WHEN tw.decision_blocked_by = 'waiting_doc_approval'
        THEN 'medium'

        -- 可操作的項目 = 高（因為可以直接處理）
        WHEN tw.decision_blocked_by IN ('need_confirm_notice', 'need_submit_doc', 'need_calculate_settlement', 'need_process_refund')
        THEN 'high'

        -- 客戶動作項目 = 中
        WHEN tw.decision_blocked_by IN ('need_move_out', 'need_return_keys', 'need_inspect_room')
        THEN 'medium'

        -- 其他 = 低
        ELSE 'low'
    END AS decision_priority,

    -- 行動代碼（供 ActionDispatcher 使用）
    CASE
        WHEN tw.decision_blocked_by = 'need_confirm_notice'
        THEN 'CONFIRM_NOTICE'

        WHEN tw.decision_blocked_by IN ('need_move_out', 'need_return_keys', 'need_inspect_room')
        THEN 'UPDATE_CHECKLIST'

        WHEN tw.decision_blocked_by = 'need_submit_doc'
        THEN 'SUBMIT_DOC'

        WHEN tw.decision_blocked_by IN ('doc_overdue', 'waiting_doc_approval')
        THEN 'APPROVE_DOC'

        WHEN tw.decision_blocked_by IN ('need_calculate_settlement', 'settlement_overdue')
        THEN 'CALCULATE_SETTLEMENT'

        WHEN tw.decision_blocked_by IN ('need_process_refund', 'refund_overdue')
        THEN 'PROCESS_REFUND'

        WHEN tw.decision_blocked_by = 'ready_to_complete'
        THEN 'COMPLETE_TERMINATION'

        ELSE 'UPDATE_STATUS'
    END AS decision_action_key

FROM v_termination_workspace tw
WHERE tw.status NOT IN ('completed', 'cancelled')
ORDER BY
    -- 逾期優先
    CASE
        WHEN tw.decision_blocked_by IN ('doc_overdue', 'settlement_overdue', 'refund_overdue') THEN 1
        WHEN tw.decision_blocked_by IN ('need_process_refund', 'need_calculate_settlement') THEN 2
        WHEN tw.decision_blocked_by IN ('need_submit_doc', 'waiting_doc_approval') THEN 3
        ELSE 4
    END,
    -- 再按預計結束日
    tw.expected_end_date ASC NULLS LAST;

COMMENT ON VIEW v_termination_queue IS '解約待辦清單 - 僅顯示需處理項目，含 decision_priority';

GRANT SELECT ON v_termination_queue TO anon, authenticated;

-- ============================================================================
-- 2. Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_termination_dashboard_stats CASCADE;

CREATE VIEW v_termination_dashboard_stats AS
SELECT
    -- 總數
    COUNT(*) AS total_action_needed,

    -- 按優先級統計
    COUNT(*) FILTER (
        WHERE decision_blocked_by IN ('doc_overdue', 'settlement_overdue', 'refund_overdue')
    ) AS urgent_count,

    COUNT(*) FILTER (
        WHERE decision_blocked_by IN ('need_confirm_notice', 'need_submit_doc', 'need_calculate_settlement', 'need_process_refund')
    ) AS high_count,

    -- 按狀態統計
    COUNT(*) FILTER (WHERE status = 'notice_received') AS notice_received_count,
    COUNT(*) FILTER (WHERE status = 'moving_out') AS moving_out_count,
    COUNT(*) FILTER (WHERE status = 'pending_doc') AS pending_doc_count,
    COUNT(*) FILTER (WHERE status = 'pending_settlement') AS pending_settlement_count,

    -- 按卡點統計
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_confirm_notice') AS need_confirm_count,
    COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_move_out', 'need_return_keys', 'need_inspect_room')) AS moving_related_count,
    COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_submit_doc', 'waiting_doc_approval')) AS doc_related_count,
    COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_calculate_settlement', 'need_process_refund')) AS settlement_related_count,

    -- 逾期統計
    COUNT(*) FILTER (WHERE is_doc_overdue) AS doc_overdue_count,
    COUNT(*) FILTER (WHERE is_settlement_overdue) AS settlement_overdue_count,
    COUNT(*) FILTER (WHERE is_refund_overdue) AS refund_overdue_count,
    COUNT(*) FILTER (WHERE is_doc_overdue OR is_settlement_overdue OR is_refund_overdue) AS total_overdue_count

FROM v_termination_workspace
WHERE status NOT IN ('completed', 'cancelled');

COMMENT ON VIEW v_termination_dashboard_stats IS '解約 Dashboard 統計';

GRANT SELECT ON v_termination_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 062 完成 ===';
    RAISE NOTICE '✅ v_termination_queue 視圖已建立（含 decision_priority）';
    RAISE NOTICE '✅ v_termination_dashboard_stats 視圖已建立';
    RAISE NOTICE '';
    RAISE NOTICE '使用方式：';
    RAISE NOTICE '- 待辦清單：SELECT * FROM v_termination_queue';
    RAISE NOTICE '- 統計資料：SELECT * FROM v_termination_dashboard_stats';
END $$;
