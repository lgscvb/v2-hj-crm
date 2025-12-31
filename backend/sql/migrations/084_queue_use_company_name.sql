-- 084_queue_use_company_name.sql
-- 流程看板統一使用公司名稱
--
-- 問題：
-- 合約主體是法人（公司），看板應顯示公司名稱而非客戶姓名
--
-- 修正：
-- 更新 v_renewal_queue 的 title 欄位使用 company_name
-- 其他視圖（payment/invoice/commission）的 title 在 workspace 視圖中定義
-- 這裡只修復 renewal_queue，其他需要單獨更新 workspace 視圖
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. v_renewal_queue - 續約看板（直接建立，不依賴 workspace 的 title）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_queue CASCADE;

CREATE VIEW v_renewal_queue AS
SELECT
    cw.*,
    'renewal'::TEXT AS process_key,
    cw.id AS entity_id,

    -- ★ 改用公司名稱（合約編號 + 公司名稱）
    CONCAT(
        cw.contract_number, ' ',
        COALESCE(NULLIF(cw.company_name, ''), cw.customer_name)
    ) AS title,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN TRUE
        WHEN cw.days_until_expiry < 0 AND cw.next_contract_id IS NULL THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN cw.days_pending_sign
        WHEN cw.days_until_expiry < 0 THEN ABS(cw.days_until_expiry)
        ELSE 0
    END AS overdue_days,

    cw.end_date AS decision_due_date,
    CONCAT('/contracts/', cw.id, '/workspace') AS workspace_url,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
            CASE
                WHEN cw.days_until_expiry <= 0 THEN 'urgent'
                WHEN cw.days_until_expiry <= 14 THEN 'high'
                WHEN cw.days_until_expiry <= 30 THEN 'medium'
                ELSE 'low'
            END
        WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
        ELSE NULL
    END AS decision_priority,

    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN 'CREATE_DRAFT'
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'SEND_FOR_SIGN'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'SEND_REMINDER'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'ISSUE_INVOICE'
        ELSE NULL
    END AS decision_action_key

FROM v_contract_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
  AND cw.decision_blocked_by != 'completed'
  AND cw.status = 'active'
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

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 - 使用公司名稱';
GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 084 完成 ===';
    RAISE NOTICE '✅ v_renewal_queue 已改用公司名稱';
    RAISE NOTICE '';
    RAISE NOTICE '顯示格式：合約編號 + 公司名稱';
    RAISE NOTICE '若無公司名稱則 fallback 到客戶姓名';
    RAISE NOTICE '';
    RAISE NOTICE '注意：payment/invoice/commission 的 title';
    RAISE NOTICE '需要在各自的 workspace 視圖中修改';
END $$;
