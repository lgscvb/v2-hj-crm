-- ============================================================================
-- Migration 095: 修復 next_contracts CTE - 排除已取消的續約草稿
--
-- 問題：
-- - v_renewal_reminders 和 v_contract_workspace 的 next_contracts CTE
--   沒有排除 cancelled/terminated 狀態的合約
-- - 導致取消續約草稿後，原合約仍顯示 has_renewal_draft = true
--
-- 修復：
-- - 統一在 next_contracts CTE 加入 status NOT IN ('cancelled', 'terminated')
-- - 同時修復 091 的 trigger 加入 BEFORE INSERT
--
-- Date: 2025-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_contract_workspace（修復 next_contracts CTE）
-- ============================================================================

DROP VIEW IF EXISTS v_contract_workspace CASCADE;

CREATE VIEW v_contract_workspace AS
WITH
-- 找出每張合約的「上一張合約」（renewed_from）
prev_contracts AS (
    SELECT
        id AS contract_id,
        renewed_from_id AS prev_contract_id
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
),
-- 找出每張合約的「下一張續約合約」（最新一筆，排除已取消）
next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        start_date AS next_start_date,
        end_date AS next_end_date,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')  -- ★ 修復：排除已取消
    ORDER BY renewed_from_id, created_at DESC
),
-- 第一期付款狀態
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        payment_status AS first_payment_status,
        paid_at AS first_payment_paid_at,
        due_date AS first_payment_due_date,
        amount AS first_payment_amount,
        payment_method AS first_payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- 第一期發票狀態
first_invoices AS (
    SELECT DISTINCT ON (p.contract_id)
        p.contract_id,
        p.invoice_status AS first_invoice_status,
        p.invoice_number AS first_invoice_number,
        p.invoice_date AS first_invoice_date
    FROM payments p
    WHERE p.payment_type = 'rent'
      AND p.invoice_status IS NOT NULL
    ORDER BY p.contract_id, p.payment_period ASC
)
SELECT
    -- 合約基本資訊
    c.id,
    c.contract_number,
    c.contract_period,
    c.customer_id,
    c.branch_id,
    c.contract_type,
    c.plan_name,
    c.start_date,
    c.end_date,
    c.monthly_rent,
    c.deposit,
    c.payment_cycle,
    c.payment_day,
    c.status,
    c.position_number,
    c.signed_at,
    c.sent_for_sign_at,
    c.renewed_from_id,
    c.created_at,
    c.updated_at,

    -- 承租人資訊（合約層級）
    c.company_name,
    c.representative_name,
    c.representative_address,
    c.id_number,
    c.company_tax_id,
    c.phone,
    c.email,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,
    cust.status AS customer_status,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 續約追蹤欄位（意願管理）
    c.renewal_notified_at,
    c.renewal_confirmed_at,
    c.renewal_notes,

    -- 上一張合約
    pc.prev_contract_id,

    -- 下一張續約合約
    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_start_date,
    nc.next_end_date,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,

    -- 送簽開始時間
    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,

    -- 是否有續約草稿
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- 第一期付款狀態
    fp.first_payment_id,
    fp.first_payment_status,
    fp.first_payment_paid_at,
    fp.first_payment_due_date,
    fp.first_payment_amount,
    fp.first_payment_method,

    -- 第一期發票狀態
    fi.first_invoice_status,
    fi.first_invoice_number,
    fi.first_invoice_date,

    -- ========== 計算欄位 ==========

    -- 剩餘天數
    c.end_date - CURRENT_DATE AS days_until_expiry,

    -- 回簽等待天數
    CASE
        WHEN nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at)::INT
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_created_at)::INT
        ELSE NULL
    END AS days_pending_sign,

    -- ========== Timeline 節點狀態 ==========

    -- 1. 續約意願
    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL THEN 'done'
        WHEN c.renewal_notified_at IS NOT NULL THEN 'pending'
        ELSE 'not_started'
    END AS timeline_intent_status,

    -- 2. 文件回簽（看 next_contract）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN 'done'
        WHEN nc.next_status IN ('active', 'signed') THEN 'done'
        WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 'pending'
        WHEN nc.next_status = 'renewal_draft' THEN 'draft'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'unknown'
    END AS timeline_signing_status,

    -- 3. 收款（看 next_contract 的第一期）
    CASE
        WHEN fp.first_payment_status = 'paid' THEN 'done'
        WHEN fp.first_payment_status = 'overdue' THEN 'blocked'
        WHEN fp.first_payment_status IS NOT NULL THEN 'pending'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'not_created'
    END AS timeline_payment_status,

    -- 4. 發票
    CASE
        WHEN fi.first_invoice_status = 'issued' THEN 'done'
        WHEN fi.first_invoice_status IS NOT NULL THEN 'pending'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'not_created'
    END AS timeline_invoice_status,

    -- 5. 啟用
    CASE
        WHEN nc.next_status = 'active' THEN 'done'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'pending'
    END AS timeline_activation_status,

    -- ========== 布林 Flags（與 v_renewal_reminders 相容） ==========

    c.renewal_notified_at IS NOT NULL AS is_notified,
    c.renewal_confirmed_at IS NOT NULL AS is_confirmed,
    CASE WHEN fp.first_payment_status = 'paid' THEN true ELSE false END AS is_paid,
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,
    fi.first_invoice_number IS NOT NULL AS is_invoiced,

    -- ========== Decision（卡點判斷，first-match wins） ==========

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'need_create_renewal'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'signing_overdue'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'payment_pending'
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN 'invoice_pending'
        WHEN nc.next_status = 'active'
        THEN 'completed'
        ELSE NULL
    END AS decision_blocked_by,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN '建立續約合約草稿'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN '發催簽通知'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN '催收首期款項'
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN '開立首期發票'
        WHEN nc.next_status = 'active'
        THEN NULL
        ELSE NULL
    END AS decision_next_action,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'Sales'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'Sales'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'Finance'
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN 'Finance'
        ELSE NULL
    END AS decision_owner

FROM contracts c
JOIN customers cust ON c.customer_id = cust.id
JOIN branches b ON c.branch_id = b.id
LEFT JOIN prev_contracts pc ON pc.contract_id = c.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = c.id
LEFT JOIN first_payments fp ON fp.contract_id = COALESCE(nc.next_contract_id, c.id)
LEFT JOIN first_invoices fi ON fi.contract_id = COALESCE(nc.next_contract_id, c.id);

COMMENT ON VIEW v_contract_workspace IS 'Contract Workspace 視圖 V2 - 修復 next_contracts 排除 cancelled，新增布林 flags';

GRANT SELECT ON v_contract_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_renewal_reminders（修復 next_contracts CTE）
-- ============================================================================

DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;

CREATE VIEW v_renewal_reminders AS
WITH next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')  -- ★ 修復：排除已取消
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        payment_status,
        paid_at,
        payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date
    FROM invoices
    WHERE status = 'issued'
    ORDER BY contract_id, invoice_date ASC
)
SELECT
    ct.id,
    ct.contract_number,
    ct.contract_period,
    ct.customer_id,
    ct.branch_id,
    ct.contract_type,
    ct.plan_name,
    ct.start_date,
    ct.end_date,
    ct.monthly_rent,
    ct.deposit,
    ct.payment_cycle,
    ct.status AS contract_status,
    ct.position_number,
    ct.metadata,

    -- 續約追蹤欄位（原始時間戳）
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_notes,

    -- [DEPRECATED] 保留讀取
    ct.renewal_paid_at,
    ct.renewal_invoiced_at,
    ct.renewal_signed_at,
    ct.invoice_status,

    -- 剩餘天數
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 提醒優先級
    CASE
        WHEN ct.end_date - CURRENT_DATE <= 7 THEN 'urgent'
        WHEN ct.end_date - CURRENT_DATE <= 30 THEN 'high'
        WHEN ct.end_date - CURRENT_DATE <= 60 THEN 'medium'
        ELSE 'low'
    END AS priority,

    -- 合約歷史
    (SELECT COUNT(*) FROM contracts WHERE customer_id = ct.customer_id) AS total_contracts_history,

    -- ========== Next Contract 資訊 ==========

    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,

    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- 三段視圖狀態
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'pending'
        WHEN nc.next_status = 'active' THEN 'completed'
        ELSE 'handoff'
    END AS renewal_stage,

    -- ========== SSOT 計算欄位 ==========

    -- 收款狀態
    CASE WHEN fp.payment_status = 'paid' THEN true ELSE false END AS is_first_payment_paid,
    fp.payment_status AS first_payment_status,
    fp.paid_at AS first_payment_paid_at,
    fp.payment_method AS first_payment_method,

    -- 發票狀態
    fi.invoice_number AS next_invoice_number,
    fi.invoice_date AS next_invoice_date,
    fi.invoice_number IS NOT NULL AS is_next_invoiced,

    -- 回簽狀態
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_next_signed,

    -- 回簽等待天數
    CASE
        WHEN nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at)::INT
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_created_at)::INT
        ELSE NULL
    END AS days_pending_sign,

    -- ========== 前端用計算欄位 ==========

    -- 意願 flags（布林）
    ct.renewal_notified_at IS NOT NULL AS is_notified,
    ct.renewal_confirmed_at IS NOT NULL AS is_confirmed,

    -- 別名（與 computeFlags 相容）
    CASE WHEN fp.payment_status = 'paid' THEN true ELSE false END AS is_paid,
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,
    fi.invoice_number IS NOT NULL AS is_invoiced,

    -- 下一步建議動作
    CASE
        WHEN ct.renewal_notified_at IS NULL THEN 'notify'
        WHEN ct.renewal_confirmed_at IS NULL THEN 'confirm'
        WHEN nc.next_contract_id IS NULL THEN 'create_draft'
        WHEN fp.payment_status IS NULL OR fp.payment_status != 'paid' THEN 'collect_payment'
        WHEN fi.invoice_number IS NULL THEN 'create_invoice'
        WHEN nc.next_signed_at IS NULL AND nc.next_status NOT IN ('active', 'signed') THEN 'get_signature'
        WHEN nc.next_status NOT IN ('active') THEN 'activate'
        ELSE 'completed'
    END AS next_action,

    -- 完成度分數（0-7，對應 7 步驟）
    (
        (CASE WHEN ct.renewal_notified_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN ct.renewal_confirmed_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_signed_at IS NOT NULL OR nc.next_status IN ('active', 'signed') THEN 1 ELSE 0 END) +
        (CASE WHEN fp.payment_status = 'paid' THEN 1 ELSE 0 END) +
        (CASE WHEN fi.invoice_number IS NOT NULL THEN 1 ELSE 0 END)
    ) AS completion_score

FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = ct.id
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id
LEFT JOIN first_invoices fi ON fi.contract_id = nc.next_contract_id

WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'
  AND (nc.next_status IS NULL OR nc.next_status != 'active')

ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖 V3.3 - 修復 next_contracts 排除 cancelled，7 步驟 completion_score';

GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_monthly_reminders_summary
-- ============================================================================

CREATE VIEW v_monthly_reminders_summary AS
SELECT
    branch_id,
    branch_name,
    COUNT(*) AS total_reminders,
    COUNT(*) FILTER (WHERE priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'handoff') AS handoff_count,
    ROUND(AVG(completion_score), 2) AS avg_completion_score
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 4. 修復 091 的 trigger（加入 BEFORE INSERT）
-- ============================================================================

DROP TRIGGER IF EXISTS tr_prevent_deprecated_renewal_fields ON contracts;

CREATE TRIGGER tr_prevent_deprecated_renewal_fields
BEFORE INSERT OR UPDATE ON contracts  -- ★ 修復：加入 INSERT
FOR EACH ROW
EXECUTE FUNCTION prevent_deprecated_renewal_fields();

-- ============================================================================
-- 5. 驗證
-- ============================================================================

DO $$
DECLARE
    workspace_count INT;
    reminders_count INT;
BEGIN
    SELECT COUNT(*) INTO workspace_count FROM v_contract_workspace;
    SELECT COUNT(*) INTO reminders_count FROM v_renewal_reminders;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 095 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_contract_workspace 重建完成';
    RAISE NOTICE '   ✅ next_contracts CTE 排除 cancelled/terminated';
    RAISE NOTICE '   ✅ 新增布林 flags (is_notified, is_confirmed, is_paid, is_signed, is_invoiced)';
    RAISE NOTICE '   ✅ 總筆數: %', workspace_count;
    RAISE NOTICE '';
    RAISE NOTICE '2. v_renewal_reminders 重建完成';
    RAISE NOTICE '   ✅ next_contracts CTE 排除 cancelled/terminated';
    RAISE NOTICE '   ✅ completion_score 改為 7 步驟';
    RAISE NOTICE '   ✅ 總筆數: %', reminders_count;
    RAISE NOTICE '';
    RAISE NOTICE '3. tr_prevent_deprecated_renewal_fields 已加入 BEFORE INSERT';
    RAISE NOTICE '';
END $$;
