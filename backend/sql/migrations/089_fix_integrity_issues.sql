-- 089_fix_integrity_issues.sql
-- 修復 data_integrity_check 發現的問題
--
-- 1. 補建 waive_request for payment 301 (DZ-171)
-- 2. 清除無意義的 renewal_notified_at
-- 3. 更新檢查視圖排除「外部開立」
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 補建 waive_request for payment 301
-- ============================================================================

INSERT INTO waive_requests (
    payment_id,
    requested_by,
    request_reason,
    request_amount,
    status,
    approved_by,
    approved_at,
    idempotency_key,
    created_at
)
SELECT
    301,
    'system',
    '業務折扣（資料補建）',
    p.amount,
    'approved',
    'system',
    p.updated_at,  -- 使用付款更新時間作為核准時間
    'fix-waive-301-' || NOW()::TEXT,
    p.updated_at
FROM payments p
WHERE p.id = 301
  AND NOT EXISTS (
    SELECT 1 FROM waive_requests wr WHERE wr.payment_id = 301
  );

DO $$
BEGIN
    IF FOUND THEN
        RAISE NOTICE '✅ 已補建 waive_request for payment 301';
    ELSE
        RAISE NOTICE '⏭️ waive_request for payment 301 已存在或付款不存在';
    END IF;
END $$;

-- ============================================================================
-- 2. 清除無意義的 renewal_notified_at（無 notification_logs 記錄）
-- ============================================================================

UPDATE contracts c
SET renewal_notified_at = NULL,
    updated_at = NOW()
WHERE c.renewal_notified_at IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM notification_logs n
    WHERE n.contract_id = c.id
      AND n.notification_type = 'renewal_reminder'
      AND n.status = 'sent'
  );

DO $$
DECLARE
    affected INT;
BEGIN
    GET DIAGNOSTICS affected = ROW_COUNT;
    RAISE NOTICE '✅ 已清除 % 筆無意義的 renewal_notified_at', affected;
END $$;

-- ============================================================================
-- 3. 更新 data_integrity_check 排除「外部開立」
-- ============================================================================

DROP VIEW IF EXISTS data_integrity_summary CASCADE;
DROP VIEW IF EXISTS data_integrity_check CASCADE;

CREATE VIEW data_integrity_check AS

-- ============================================================================
-- 1. 合約狀態一致性
-- ============================================================================

-- 1.1 active 但已過期（排除有草稿/待簽的）
SELECT 'active_but_expired'::TEXT AS issue_key,
       'high'::TEXT AS severity,
       'contract'::TEXT AS entity_type,
       c.id::TEXT AS entity_id,
       NULL::TEXT AS related_id,
       c.contract_number,
       jsonb_build_object(
         'status', c.status,
         'end_date', c.end_date,
         'days_expired', (CURRENT_DATE - c.end_date)
       ) AS details,
       NOW() AS detected_at
FROM contracts c
WHERE c.status = 'active'
  AND c.end_date < CURRENT_DATE
  AND NOT EXISTS (
    SELECT 1 FROM contracts nc
    WHERE nc.renewed_from_id = c.id
      AND nc.status IN ('draft', 'pending_sign')
  )

UNION ALL

-- 1.2 pending_sign 超過 14 天（以 sent_for_sign_at 為準，無則用 created_at）
SELECT 'pending_sign_overdue', 'medium', 'contract',
       c.id::TEXT, NULL::TEXT, c.contract_number,
       jsonb_build_object(
         'sent_for_sign_at', c.sent_for_sign_at,
         'created_at', c.created_at,
         'days_pending', (CURRENT_DATE - COALESCE(c.sent_for_sign_at, c.created_at)::DATE)
       ),
       NOW()
FROM contracts c
WHERE c.status = 'pending_sign'
  AND c.signed_at IS NULL
  AND COALESCE(c.sent_for_sign_at, c.created_at) < NOW() - INTERVAL '14 days'

UNION ALL

-- 1.3 termination_case 存在但合約不是 pending_termination
SELECT 'termination_case_not_pending', 'high', 'termination_case',
       tc.id::TEXT, tc.contract_id::TEXT, c.contract_number,
       jsonb_build_object('case_status', tc.status, 'contract_status', c.status),
       NOW()
FROM termination_cases tc
JOIN contracts c ON c.id = tc.contract_id
WHERE tc.status NOT IN ('completed', 'cancelled')
  AND c.status <> 'pending_termination'

UNION ALL

-- 1.4 合約是 pending_termination 但沒有 case
SELECT 'pending_termination_no_case', 'high', 'contract',
       c.id::TEXT, NULL::TEXT, c.contract_number,
       jsonb_build_object('contract_status', c.status),
       NOW()
FROM contracts c
LEFT JOIN termination_cases tc
  ON tc.contract_id = c.id AND tc.status NOT IN ('completed', 'cancelled')
WHERE c.status = 'pending_termination' AND tc.id IS NULL

UNION ALL

-- 1.5 使用已棄用的 renewal_* 欄位（排除 renewal_status = 'none'）
SELECT 'deprecated_renewal_fields', 'low', 'contract',
       c.id::TEXT, NULL::TEXT, c.contract_number,
       jsonb_strip_nulls(jsonb_build_object(
         'renewal_status', c.renewal_status,
         'renewal_paid_at', c.renewal_paid_at,
         'renewal_invoiced_at', c.renewal_invoiced_at,
         'renewal_signed_at', c.renewal_signed_at
       )),
       NOW()
FROM contracts c
WHERE (c.renewal_status IS NOT NULL AND c.renewal_status <> 'none')
   OR c.renewal_paid_at IS NOT NULL
   OR c.renewal_invoiced_at IS NOT NULL
   OR c.renewal_signed_at IS NOT NULL

UNION ALL

-- ============================================================================
-- 2. 付款/發票一致性
-- ============================================================================

-- 2.1 付款狀態與 paid_at 不一致
SELECT 'payment_paid_at_mismatch', 'high', 'payment',
       p.id::TEXT, p.contract_id::TEXT, c.contract_number,
       jsonb_build_object('payment_status', p.payment_status, 'paid_at', p.paid_at),
       NOW()
FROM payments p
LEFT JOIN contracts c ON c.id = p.contract_id
WHERE (p.payment_status = 'paid' AND p.paid_at IS NULL)
   OR (p.payment_status <> 'paid' AND p.paid_at IS NOT NULL)

UNION ALL

-- 2.2 付款有發票狀態但沒有連結到 invoices 表（排除「外部開立」）
SELECT 'payment_invoice_link_missing', 'medium', 'payment',
       p.id::TEXT, p.contract_id::TEXT, c.contract_number,
       jsonb_build_object('invoice_status', p.invoice_status, 'invoice_number', p.invoice_number),
       NOW()
FROM payments p
LEFT JOIN payment_invoices pi ON pi.payment_id = p.id
LEFT JOIN invoices i ON i.id = pi.invoice_id
LEFT JOIN contracts c ON c.id = p.contract_id
WHERE (p.invoice_status = 'issued' OR p.invoice_number IS NOT NULL)
  AND i.id IS NULL
  AND COALESCE(p.invoice_number, '') <> '外部開立'  -- ★ 排除外部開立

UNION ALL

-- 2.3 付款與發票狀態不一致
SELECT 'payment_invoice_status_mismatch', 'medium', 'payment',
       p.id::TEXT, p.contract_id::TEXT, c.contract_number,
       jsonb_build_object('payment_invoice_status', p.invoice_status, 'invoice_status', i.status),
       NOW()
FROM payment_invoices pi
JOIN payments p ON p.id = pi.payment_id
JOIN invoices i ON i.id = pi.invoice_id
LEFT JOIN contracts c ON c.id = p.contract_id
WHERE (i.status = 'issued' AND p.invoice_status <> 'issued')
   OR (i.status = 'voided' AND p.invoice_status <> 'void')

UNION ALL

-- ============================================================================
-- 3. 減免一致性
-- ============================================================================

-- 3.1 付款是 waived 但沒有核准的 waive_request
SELECT 'waive_payment_without_request', 'medium', 'payment',
       p.id::TEXT, p.contract_id::TEXT, c.contract_number,
       jsonb_build_object('payment_status', p.payment_status),
       NOW()
FROM payments p
LEFT JOIN waive_requests wr
  ON wr.payment_id = p.id AND wr.status = 'approved'
LEFT JOIN contracts c ON c.id = p.contract_id
WHERE p.payment_status = 'waived' AND wr.id IS NULL

UNION ALL

-- 3.2 waive_request 已核准但付款沒變 waived
SELECT 'waive_request_not_applied', 'medium', 'waive_request',
       wr.id::TEXT, wr.payment_id::TEXT, c.contract_number,
       jsonb_build_object('request_status', wr.status, 'payment_status', p.payment_status),
       NOW()
FROM waive_requests wr
JOIN payments p ON p.id = wr.payment_id
LEFT JOIN contracts c ON c.id = p.contract_id
WHERE wr.status = 'approved' AND p.payment_status <> 'waived'

UNION ALL

-- ============================================================================
-- 4. 佣金一致性
-- ============================================================================

-- 4.1 佣金狀態與 paid_at 不一致
SELECT 'commission_paid_at_mismatch', 'medium', 'commission',
       cm.id::TEXT, cm.contract_id::TEXT, c.contract_number,
       jsonb_build_object('status', cm.status, 'paid_at', cm.paid_at),
       NOW()
FROM commissions cm
LEFT JOIN contracts c ON c.id = cm.contract_id
WHERE (cm.status = 'paid' AND cm.paid_at IS NULL)
   OR (cm.status <> 'paid' AND cm.paid_at IS NOT NULL)

UNION ALL

-- ============================================================================
-- 5. 通知一致性
-- ============================================================================

-- 5.1 通知已發送但 flag 沒設
SELECT 'renewal_notice_sent_but_flag_missing', 'low', 'notification_log',
       n.id::TEXT, n.contract_id::TEXT, c.contract_number,
       jsonb_build_object('created_at', n.created_at, 'notification_type', n.notification_type),
       NOW()
FROM notification_logs n
JOIN contracts c ON c.id = n.contract_id
WHERE n.notification_type = 'renewal_reminder'
  AND n.status = 'sent'
  AND c.renewal_notified_at IS NULL

UNION ALL

-- 5.2 flag 設了但沒有通知記錄（已在步驟 2 清除，此處保留監控）
SELECT 'renewal_flag_without_notice_log', 'low', 'contract',
       c.id::TEXT, NULL::TEXT, c.contract_number,
       jsonb_build_object('renewal_notified_at', c.renewal_notified_at),
       NOW()
FROM contracts c
LEFT JOIN notification_logs n
  ON n.contract_id = c.id
 AND n.notification_type = 'renewal_reminder'
 AND n.status = 'sent'
WHERE c.renewal_notified_at IS NOT NULL AND n.id IS NULL

UNION ALL

-- ============================================================================
-- 6. 續約鏈一致性
-- ============================================================================

-- 6.1 renewed_from_id 指向不存在的合約
SELECT 'orphan_renewed_from_id', 'high', 'contract',
       c.id::TEXT, c.renewed_from_id::TEXT, c.contract_number,
       jsonb_build_object(
         'renewed_from_id', c.renewed_from_id,
         'contract_period', c.contract_period
       ),
       NOW()
FROM contracts c
LEFT JOIN contracts p ON p.id = c.renewed_from_id
WHERE c.renewed_from_id IS NOT NULL AND p.id IS NULL

UNION ALL

-- 6.2 contract_period 與前約不連續
SELECT 'contract_period_mismatch', 'medium', 'contract',
       c.id::TEXT, c.renewed_from_id::TEXT, c.contract_number,
       jsonb_build_object(
         'contract_period', c.contract_period,
         'parent_period', p.contract_period,
         'expected_period', p.contract_period + 1
       ),
       NOW()
FROM contracts c
JOIN contracts p ON p.id = c.renewed_from_id
WHERE c.contract_period IS NOT NULL
  AND p.contract_period IS NOT NULL
  AND c.contract_period <> p.contract_period + 1

UNION ALL

-- 6.3 續約合約缺少 contract_period
SELECT 'contract_period_is_null', 'medium', 'contract',
       c.id::TEXT, c.renewed_from_id::TEXT, c.contract_number,
       jsonb_build_object(
         'contract_period', c.contract_period,
         'renewed_from_id', c.renewed_from_id,
         'parent_contract_number', p.contract_number
       ),
       NOW()
FROM contracts c
LEFT JOIN contracts p ON p.id = c.renewed_from_id
WHERE c.renewed_from_id IS NOT NULL
  AND (c.contract_period IS NULL OR p.contract_period IS NULL);

-- ============================================================================
-- 權限與說明
-- ============================================================================

COMMENT ON VIEW data_integrity_check IS '資料一致性檢查視圖 - 監控系統髒資料';
GRANT SELECT ON data_integrity_check TO anon, authenticated;

-- ============================================================================
-- 統計視圖
-- ============================================================================

CREATE VIEW data_integrity_summary AS
SELECT
    severity,
    issue_key,
    COUNT(*) AS issue_count
FROM data_integrity_check
GROUP BY severity, issue_key
ORDER BY
    CASE severity
        WHEN 'high' THEN 1
        WHEN 'medium' THEN 2
        WHEN 'low' THEN 3
    END,
    issue_count DESC;

COMMENT ON VIEW data_integrity_summary IS '資料一致性問題摘要';
GRANT SELECT ON data_integrity_summary TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 089 完成 ===';
    RAISE NOTICE '✅ waive_request 已補建';
    RAISE NOTICE '✅ renewal_notified_at 已清除';
    RAISE NOTICE '✅ data_integrity_check 已更新（排除外部開立）';
END $$;
