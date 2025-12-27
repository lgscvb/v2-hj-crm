-- 052_termination_workspace.sql
-- 解約流程 Workspace 視圖 - 加入 Decision 卡點判斷
-- 設計模式：狀態機 + Decision Table + 工作隊列

-- ============================================================================
-- v_termination_workspace 視圖
-- ============================================================================
-- 目的：提供解約流程的 Decision 判斷，告訴用戶「卡在哪裡」和「下一步做什麼」

CREATE OR REPLACE VIEW v_termination_workspace AS
WITH checklist_parsed AS (
    SELECT
        tc.id,
        tc.contract_id,
        tc.termination_type,
        tc.status,
        tc.notice_date,
        tc.expected_end_date,
        tc.actual_move_out,
        tc.doc_submitted_date,
        tc.doc_approved_date,
        tc.settlement_date,
        tc.refund_date,
        tc.deposit_amount,
        tc.deduction_days,
        tc.daily_rate,
        tc.deduction_amount,
        tc.other_deductions,
        tc.refund_amount,
        tc.refund_method,
        tc.notes,
        tc.created_at,
        tc.updated_at,
        -- 解析 checklist
        (tc.checklist->>'notice_confirmed')::boolean AS chk_notice_confirmed,
        (tc.checklist->>'belongings_removed')::boolean AS chk_belongings_removed,
        (tc.checklist->>'keys_returned')::boolean AS chk_keys_returned,
        (tc.checklist->>'room_inspected')::boolean AS chk_room_inspected,
        (tc.checklist->>'doc_submitted')::boolean AS chk_doc_submitted,
        (tc.checklist->>'doc_approved')::boolean AS chk_doc_approved,
        (tc.checklist->>'settlement_calculated')::boolean AS chk_settlement_calculated,
        (tc.checklist->>'refund_processed')::boolean AS chk_refund_processed,
        -- 合約資訊
        ct.contract_number,
        ct.start_date AS contract_start_date,
        ct.end_date AS contract_end_date,
        ct.monthly_rent,
        ct.deposit AS contract_deposit,
        ct.position_number,
        -- 客戶資訊
        cust.id AS customer_id,
        cust.name AS customer_name,
        cust.company_name,
        cust.phone AS customer_phone,
        cust.line_user_id,
        -- 場館資訊
        b.id AS branch_id,
        b.name AS branch_name
    FROM termination_cases tc
    JOIN contracts ct ON tc.contract_id = ct.id
    JOIN customers cust ON ct.customer_id = cust.id
    JOIN branches b ON ct.branch_id = b.id
    WHERE tc.status NOT IN ('completed', 'cancelled')
)
SELECT
    cp.*,

    -- ========== 計算欄位 ==========

    -- 進度（8 個步驟）
    (CASE WHEN cp.chk_notice_confirmed THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_belongings_removed THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_keys_returned THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_room_inspected THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_doc_submitted THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_doc_approved THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_settlement_calculated THEN 1 ELSE 0 END +
     CASE WHEN cp.chk_refund_processed THEN 1 ELSE 0 END) AS progress,

    -- 狀態標籤
    CASE cp.status
        WHEN 'notice_received' THEN '已收到通知'
        WHEN 'moving_out' THEN '搬遷中'
        WHEN 'pending_doc' THEN '等待公文'
        WHEN 'pending_settlement' THEN '押金結算中'
    END AS status_label,

    -- 解約類型標籤
    CASE cp.termination_type
        WHEN 'early' THEN '提前解約'
        WHEN 'not_renewing' THEN '到期不續約'
        WHEN 'breach' THEN '違約終止'
    END AS type_label,

    -- 等待天數
    CASE
        WHEN cp.doc_submitted_date IS NOT NULL AND cp.doc_approved_date IS NULL
        THEN (CURRENT_DATE - cp.doc_submitted_date)
        ELSE NULL
    END AS days_waiting_doc,

    -- 公文逾期（超過 30 天未核准）
    CASE
        WHEN cp.doc_submitted_date IS NOT NULL
         AND cp.doc_approved_date IS NULL
         AND (CURRENT_DATE - cp.doc_submitted_date) > 30
        THEN TRUE
        ELSE FALSE
    END AS is_doc_overdue,

    -- 結算逾期（公文核准超過 14 天未結算）
    CASE
        WHEN cp.doc_approved_date IS NOT NULL
         AND cp.settlement_date IS NULL
         AND (CURRENT_DATE - cp.doc_approved_date) > 14
        THEN TRUE
        ELSE FALSE
    END AS is_settlement_overdue,

    -- 退款逾期（結算完成超過 7 天未退款）
    CASE
        WHEN cp.settlement_date IS NOT NULL
         AND cp.refund_date IS NULL
         AND (CURRENT_DATE - cp.settlement_date) > 7
        THEN TRUE
        ELSE FALSE
    END AS is_refund_overdue,

    -- ========== Decision（卡點判斷，first-match wins） ==========

    CASE
        -- 優先序 1：尚未確認通知
        WHEN NOT cp.chk_notice_confirmed
        THEN 'need_confirm_notice'

        -- 優先序 2：待搬遷（東西還沒搬完）
        WHEN NOT cp.chk_belongings_removed
        THEN 'need_move_out'

        -- 優先序 3：待還鑰匙
        WHEN NOT cp.chk_keys_returned
        THEN 'need_return_keys'

        -- 優先序 4：待驗收
        WHEN NOT cp.chk_room_inspected
        THEN 'need_inspect_room'

        -- 優先序 5：待送國稅局
        WHEN NOT cp.chk_doc_submitted
        THEN 'need_submit_doc'

        -- 優先序 6：公文逾期（送件超過 30 天未核准）
        WHEN cp.chk_doc_submitted AND NOT cp.chk_doc_approved
         AND cp.doc_submitted_date IS NOT NULL
         AND (CURRENT_DATE - cp.doc_submitted_date) > 30
        THEN 'doc_overdue'

        -- 優先序 7：等待公文核准
        WHEN cp.chk_doc_submitted AND NOT cp.chk_doc_approved
        THEN 'waiting_doc_approval'

        -- 優先序 8：結算逾期（公文核准超過 14 天未結算）
        WHEN cp.chk_doc_approved AND NOT cp.chk_settlement_calculated
         AND cp.doc_approved_date IS NOT NULL
         AND (CURRENT_DATE - cp.doc_approved_date) > 14
        THEN 'settlement_overdue'

        -- 優先序 9：待結算押金
        WHEN cp.chk_doc_approved AND NOT cp.chk_settlement_calculated
        THEN 'need_calculate_settlement'

        -- 優先序 10：退款逾期
        WHEN cp.chk_settlement_calculated AND NOT cp.chk_refund_processed
         AND cp.settlement_date IS NOT NULL
         AND (CURRENT_DATE - cp.settlement_date) > 7
        THEN 'refund_overdue'

        -- 優先序 11：待退款
        WHEN cp.chk_settlement_calculated AND NOT cp.chk_refund_processed
        THEN 'need_process_refund'

        -- 優先序 12：全部完成（應該不會到這裡）
        ELSE 'ready_to_complete'
    END AS decision_blocked_by,

    CASE
        WHEN NOT cp.chk_notice_confirmed
        THEN '確認解約通知'

        WHEN NOT cp.chk_belongings_removed
        THEN '催促客戶搬遷'

        WHEN NOT cp.chk_keys_returned
        THEN '回收鑰匙'

        WHEN NOT cp.chk_room_inspected
        THEN '安排驗收'

        WHEN NOT cp.chk_doc_submitted
        THEN '準備並送出公文'

        WHEN cp.chk_doc_submitted AND NOT cp.chk_doc_approved
         AND cp.doc_submitted_date IS NOT NULL
         AND (CURRENT_DATE - cp.doc_submitted_date) > 30
        THEN '跟進國稅局（逾期 ' || (CURRENT_DATE - cp.doc_submitted_date) || ' 天）'

        WHEN cp.chk_doc_submitted AND NOT cp.chk_doc_approved
        THEN '等待公文核准'

        WHEN cp.chk_doc_approved AND NOT cp.chk_settlement_calculated
         AND cp.doc_approved_date IS NOT NULL
         AND (CURRENT_DATE - cp.doc_approved_date) > 14
        THEN '結算押金（逾期 ' || (CURRENT_DATE - cp.doc_approved_date) || ' 天）'

        WHEN cp.chk_doc_approved AND NOT cp.chk_settlement_calculated
        THEN '計算押金結算'

        WHEN cp.chk_settlement_calculated AND NOT cp.chk_refund_processed
         AND cp.settlement_date IS NOT NULL
         AND (CURRENT_DATE - cp.settlement_date) > 7
        THEN '處理退款（逾期 ' || (CURRENT_DATE - cp.settlement_date) || ' 天）'

        WHEN cp.chk_settlement_calculated AND NOT cp.chk_refund_processed
        THEN '處理退款'

        ELSE '完成解約'
    END AS decision_next_action,

    CASE
        WHEN NOT cp.chk_notice_confirmed
        THEN 'Sales'

        WHEN NOT cp.chk_belongings_removed OR NOT cp.chk_keys_returned OR NOT cp.chk_room_inspected
        THEN 'Sales'

        WHEN NOT cp.chk_doc_submitted OR NOT cp.chk_doc_approved
        THEN 'Admin'

        WHEN NOT cp.chk_settlement_calculated OR NOT cp.chk_refund_processed
        THEN 'Finance'

        ELSE 'Sales'
    END AS decision_owner

FROM checklist_parsed cp
ORDER BY
    -- 優先處理逾期的
    CASE
        WHEN cp.doc_submitted_date IS NOT NULL
         AND cp.doc_approved_date IS NULL
         AND (CURRENT_DATE - cp.doc_submitted_date) > 30 THEN 0
        WHEN cp.doc_approved_date IS NOT NULL
         AND cp.settlement_date IS NULL
         AND (CURRENT_DATE - cp.doc_approved_date) > 14 THEN 1
        WHEN cp.settlement_date IS NOT NULL
         AND cp.refund_date IS NULL
         AND (CURRENT_DATE - cp.settlement_date) > 7 THEN 2
        ELSE 3
    END,
    -- 再按狀態順序
    CASE cp.status
        WHEN 'pending_settlement' THEN 0
        WHEN 'pending_doc' THEN 1
        WHEN 'moving_out' THEN 2
        WHEN 'notice_received' THEN 3
    END,
    cp.created_at DESC;

COMMENT ON VIEW v_termination_workspace IS '解約流程 Workspace 視圖 - 含 Decision 卡點判斷和下一步行動建議';

GRANT SELECT ON v_termination_workspace TO anon, authenticated;

-- ============================================================================
-- 建立 get_termination_stats 函數（Dashboard 用）
-- ============================================================================

CREATE OR REPLACE FUNCTION get_termination_stats()
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'total', COUNT(*),
        'by_status', jsonb_build_object(
            'notice_received', COUNT(*) FILTER (WHERE status = 'notice_received'),
            'moving_out', COUNT(*) FILTER (WHERE status = 'moving_out'),
            'pending_doc', COUNT(*) FILTER (WHERE status = 'pending_doc'),
            'pending_settlement', COUNT(*) FILTER (WHERE status = 'pending_settlement')
        ),
        'by_blocked', jsonb_build_object(
            'need_confirm', COUNT(*) FILTER (WHERE decision_blocked_by = 'need_confirm_notice'),
            'need_move_out', COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_move_out', 'need_return_keys', 'need_inspect_room')),
            'need_doc', COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_submit_doc', 'waiting_doc_approval')),
            'doc_overdue', COUNT(*) FILTER (WHERE decision_blocked_by = 'doc_overdue'),
            'need_settlement', COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_calculate_settlement', 'settlement_overdue')),
            'need_refund', COUNT(*) FILTER (WHERE decision_blocked_by IN ('need_process_refund', 'refund_overdue'))
        ),
        'overdue', jsonb_build_object(
            'doc_overdue', COUNT(*) FILTER (WHERE is_doc_overdue),
            'settlement_overdue', COUNT(*) FILTER (WHERE is_settlement_overdue),
            'refund_overdue', COUNT(*) FILTER (WHERE is_refund_overdue)
        ),
        'total_overdue', COUNT(*) FILTER (WHERE is_doc_overdue OR is_settlement_overdue OR is_refund_overdue)
    ) INTO v_result
    FROM v_termination_workspace;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_termination_stats IS '取得解約流程統計（Dashboard 用）';

GRANT EXECUTE ON FUNCTION get_termination_stats TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 052 完成 ===';
    RAISE NOTICE '✅ v_termination_workspace 視圖已建立（含 Decision）';
    RAISE NOTICE '✅ get_termination_stats 函數已建立';
    RAISE NOTICE '';
    RAISE NOTICE 'Decision 狀態：';
    RAISE NOTICE '- need_confirm_notice: 待確認通知';
    RAISE NOTICE '- need_move_out/keys/inspect: 搬遷相關';
    RAISE NOTICE '- need_submit_doc: 待送公文';
    RAISE NOTICE '- doc_overdue: 公文逾期';
    RAISE NOTICE '- waiting_doc_approval: 等待公文';
    RAISE NOTICE '- need_calculate_settlement: 待結算';
    RAISE NOTICE '- settlement_overdue: 結算逾期';
    RAISE NOTICE '- need_process_refund: 待退款';
    RAISE NOTICE '- refund_overdue: 退款逾期';
END $$;
