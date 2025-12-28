-- 064_priority_escalation.sql
-- 優先級自動升級機制
-- Date: 2025-12-28
--
-- 邏輯：
-- - 卡點逾期 7 天以上：medium → high
-- - 卡點逾期 14 天以上：high → urgent
-- - 使用 system_settings.automation.priority_escalation 設定

-- ============================================================================
-- 1. 建立優先級計算函數
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_escalated_priority(
    base_priority TEXT,
    overdue_days INT
) RETURNS TEXT AS $$
DECLARE
    settings JSONB;
    medium_to_high_days INT;
    high_to_urgent_days INT;
BEGIN
    -- 取得設定
    SELECT setting_value::jsonb->'priority_escalation'
    INTO settings
    FROM system_settings
    WHERE setting_key = 'automation';

    -- 預設值
    medium_to_high_days := COALESCE((settings->>'medium_to_high_days')::INT, 7);
    high_to_urgent_days := COALESCE((settings->>'high_to_urgent_days')::INT, 14);

    -- 如果沒有逾期，返回原始優先級
    IF overdue_days IS NULL OR overdue_days <= 0 THEN
        RETURN base_priority;
    END IF;

    -- 根據逾期天數升級
    IF overdue_days >= high_to_urgent_days THEN
        -- 14+ 天：升級到 urgent
        RETURN 'urgent';
    ELSIF overdue_days >= medium_to_high_days THEN
        -- 7-13 天：medium 升級到 high
        IF base_priority = 'medium' THEN
            RETURN 'high';
        ELSIF base_priority = 'low' THEN
            RETURN 'medium';
        END IF;
    END IF;

    RETURN base_priority;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION calculate_escalated_priority IS '根據逾期天數計算升級後的優先級';

-- ============================================================================
-- 2. 更新 v_renewal_queue 視圖（加入優先級升級）
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

    -- 是否逾期
    CASE
        WHEN cw.end_date < CURRENT_DATE AND cw.decision_blocked_by IS NOT NULL THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- 逾期天數
    CASE
        WHEN cw.end_date < CURRENT_DATE THEN CURRENT_DATE - cw.end_date
        ELSE 0
    END AS actual_overdue_days,

    -- 應處理日期
    cw.end_date AS decision_due_date,

    -- Workspace URL
    CONCAT('/contracts/', cw.id, '/workspace') AS workspace_url,

    -- ========== 優先級（含升級邏輯） ==========
    calculate_escalated_priority(
        -- 基礎優先級
        CASE
            WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
            WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
            WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
            WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
                CASE
                    WHEN cw.days_until_expiry <= 7 THEN 'high'
                    WHEN cw.days_until_expiry <= 30 THEN 'medium'
                    ELSE 'low'
                END
            WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
            ELSE NULL
        END,
        -- 逾期天數
        CASE
            WHEN cw.end_date < CURRENT_DATE THEN CURRENT_DATE - cw.end_date
            ELSE 0
        END
    ) AS decision_priority,

    -- 行動代碼（供 ActionDispatcher 使用）
    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN 'CREATE_DRAFT'
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'SEND_SIGN_REMINDER'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'SEND_REMINDER'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'ISSUE_INVOICE'
        WHEN cw.decision_blocked_by = 'need_send_for_sign' THEN 'SEND_FOR_SIGN'
        WHEN cw.decision_blocked_by = 'waiting_for_sign' THEN 'SEND_SIGN_REMINDER'
        WHEN cw.decision_blocked_by = 'need_activate' THEN 'ACTIVATE'
        ELSE NULL
    END AS decision_action_key

FROM v_contract_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
  AND cw.decision_blocked_by != 'completed'
ORDER BY
    -- 按優先級排序
    CASE
        WHEN calculate_escalated_priority(
            CASE
                WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
                WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
                WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
                WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
                    CASE
                        WHEN cw.days_until_expiry <= 7 THEN 'high'
                        WHEN cw.days_until_expiry <= 30 THEN 'medium'
                        ELSE 'low'
                    END
                WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
                ELSE NULL
            END,
            CASE
                WHEN cw.end_date < CURRENT_DATE THEN CURRENT_DATE - cw.end_date
                ELSE 0
            END
        ) = 'urgent' THEN 1
        WHEN calculate_escalated_priority(
            CASE
                WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
                WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
                WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
                WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
                    CASE
                        WHEN cw.days_until_expiry <= 7 THEN 'high'
                        WHEN cw.days_until_expiry <= 30 THEN 'medium'
                        ELSE 'low'
                    END
                WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
                ELSE NULL
            END,
            CASE
                WHEN cw.end_date < CURRENT_DATE THEN CURRENT_DATE - cw.end_date
                ELSE 0
            END
        ) = 'high' THEN 2
        WHEN calculate_escalated_priority(
            CASE
                WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
                WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
                WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
                WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
                    CASE
                        WHEN cw.days_until_expiry <= 7 THEN 'high'
                        WHEN cw.days_until_expiry <= 30 THEN 'medium'
                        ELSE 'low'
                    END
                WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
                ELSE NULL
            END,
            CASE
                WHEN cw.end_date < CURRENT_DATE THEN CURRENT_DATE - cw.end_date
                ELSE 0
            END
        ) = 'medium' THEN 3
        ELSE 4
    END,
    cw.days_until_expiry ASC NULLS LAST;

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 - 含優先級自動升級';

GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 3. 更新 v_payment_queue 視圖（加入優先級升級）
-- ============================================================================

DROP VIEW IF EXISTS v_payment_queue CASCADE;

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

COMMENT ON VIEW v_payment_queue IS '付款待辦清單 - 含優先級自動升級';

GRANT SELECT ON v_payment_queue TO anon, authenticated;

-- ============================================================================
-- 4. 更新 v_invoice_queue 視圖（如果存在）
-- ============================================================================

-- 先檢查 v_invoice_workspace 是否存在
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_views WHERE viewname = 'v_invoice_workspace') THEN
        DROP VIEW IF EXISTS v_invoice_queue CASCADE;

        -- 使用 days_since_paid 作為逾期天數
        EXECUTE '
        CREATE VIEW v_invoice_queue AS
        SELECT
            iw.*,
            calculate_escalated_priority(
                iw.decision_priority,
                COALESCE(iw.days_since_paid, 0)
            ) AS escalated_priority
        FROM v_invoice_workspace iw
        WHERE iw.decision_blocked_by IS NOT NULL
          AND iw.invoice_status != ''issued''
        ORDER BY
            CASE calculate_escalated_priority(iw.decision_priority, COALESCE(iw.days_since_paid, 0))
                WHEN ''urgent'' THEN 1
                WHEN ''high'' THEN 2
                WHEN ''medium'' THEN 3
                WHEN ''low'' THEN 4
                ELSE 5
            END,
            iw.days_since_paid DESC NULLS LAST';

        EXECUTE 'COMMENT ON VIEW v_invoice_queue IS ''發票待辦清單 - 含優先級自動升級''';
        EXECUTE 'GRANT SELECT ON v_invoice_queue TO anon, authenticated';
    END IF;
END $$;

-- ============================================================================
-- 5. 重建 Dashboard 統計視圖（使用升級後的優先級）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_dashboard_stats CASCADE;

CREATE VIEW v_renewal_dashboard_stats AS
SELECT
    COUNT(*) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE decision_priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE decision_priority = 'medium') AS medium_count,
    COUNT(*) FILTER (WHERE decision_priority = 'low') AS low_count,
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_create_renewal') AS need_create_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_send_for_sign') AS need_send_sign_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'waiting_for_sign') AS waiting_sign_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'signing_overdue') AS signing_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_pending') AS payment_pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_pending') AS invoice_pending_count
FROM v_renewal_queue;

COMMENT ON VIEW v_renewal_dashboard_stats IS '續約 Dashboard 統計（含優先級升級）';

GRANT SELECT ON v_renewal_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 064 完成 ===';
    RAISE NOTICE '✅ calculate_escalated_priority 函數已建立';
    RAISE NOTICE '✅ v_renewal_queue 已更新（含優先級升級）';
    RAISE NOTICE '✅ v_payment_queue 已更新（含優先級升級）';
    RAISE NOTICE '✅ v_renewal_dashboard_stats 已更新';
    RAISE NOTICE '';
    RAISE NOTICE '優先級升級規則：';
    RAISE NOTICE '- 逾期 7 天以上：medium → high';
    RAISE NOTICE '- 逾期 14 天以上：任何 → urgent';
    RAISE NOTICE '- 可在 system_settings.automation.priority_escalation 調整';
END $$;
