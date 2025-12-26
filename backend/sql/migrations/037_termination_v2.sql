-- ============================================================================
-- Hour Jungle CRM - Termination Cases v2
-- Migration: 037_termination_v2.sql
-- Date: 2025-12-26
-- Purpose: 解約流程改進
--   1. 新增 pending_authority 狀態（呆帳通報主管機關）
--   2. 新增呆帳相關欄位
--   3. v_payments_due 排除解約中合約
--   4. v_termination_cases 新增待收款統計
--   5. 合約狀態同步 trigger
-- ============================================================================

-- ============================================================================
-- 1. 新增 pending_authority 狀態
-- ============================================================================

-- 更新 termination_cases 的 status 約束
ALTER TABLE termination_cases DROP CONSTRAINT IF EXISTS termination_cases_status_check;
ALTER TABLE termination_cases ADD CONSTRAINT termination_cases_status_check
    CHECK (status IN (
        'notice_received',    -- 客戶已通知
        'moving_out',         -- 搬遷中
        'pending_doc',        -- 等待公文
        'pending_settlement', -- 押金結算中
        'pending_authority',  -- 通報主管機關中（呆帳流程）
        'completed',          -- 已完成
        'cancelled'           -- 已取消（客戶反悔續租）
    ));

COMMENT ON COLUMN termination_cases.status IS
    '狀態: notice_received=已通知, moving_out=搬遷中, pending_doc=等待公文, pending_settlement=押金結算中, pending_authority=通報主管機關中, completed=已完成, cancelled=已取消';

-- ============================================================================
-- 2. 新增呆帳相關欄位
-- ============================================================================

-- 主管機關通報日期
ALTER TABLE termination_cases
    ADD COLUMN IF NOT EXISTS authority_reported_date DATE;

COMMENT ON COLUMN termination_cases.authority_reported_date IS '通報國稅局日期';

-- 收到函文日期（國稅局核准逕行解散）
ALTER TABLE termination_cases
    ADD COLUMN IF NOT EXISTS authority_response_date DATE;

COMMENT ON COLUMN termination_cases.authority_response_date IS '收到國稅局函文日期';

-- 是否為呆帳
ALTER TABLE termination_cases
    ADD COLUMN IF NOT EXISTS is_bad_debt BOOLEAN DEFAULT FALSE;

COMMENT ON COLUMN termination_cases.is_bad_debt IS '是否為呆帳（押金不夠扣欠款）';

-- 呆帳金額（欠款 + 扣除費用 - 押金）
ALTER TABLE termination_cases
    ADD COLUMN IF NOT EXISTS bad_debt_amount NUMERIC(10,2) DEFAULT 0;

COMMENT ON COLUMN termination_cases.bad_debt_amount IS '呆帳金額 = 欠款 + 扣除費用 - 押金';

-- 欠款金額（用於計算呆帳）
ALTER TABLE termination_cases
    ADD COLUMN IF NOT EXISTS arrears_amount NUMERIC(10,2) DEFAULT 0;

COMMENT ON COLUMN termination_cases.arrears_amount IS '欠款金額（未繳帳款總額）';

-- ============================================================================
-- 3. 修改 v_payments_due：排除解約中合約的款項
-- ============================================================================

-- 先刪除再重建（因為欄位結構有變）
DROP VIEW IF EXISTS v_payments_due CASCADE;

CREATE OR REPLACE VIEW v_payments_due AS
SELECT
    p.id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.late_fee,
    p.due_date,
    p.payment_status,
    p.overdue_days,
    p.notes,
    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.line_user_id,
    c.risk_level,
    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,
    -- 合約資訊
    ct.contract_number,
    ct.monthly_rent,
    ct.end_date AS contract_end_date,
    ct.status AS contract_status,
    -- 緊急度計算
    CASE
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 30 THEN 'critical'
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 14 THEN 'high'
        WHEN p.payment_status = 'overdue' THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '3 days' THEN 'upcoming'
        ELSE 'normal'
    END AS urgency,
    -- 總應收金額
    p.amount + COALESCE(p.late_fee, 0) AS total_due
FROM payments p
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
LEFT JOIN contracts ct ON p.contract_id = ct.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 排除解約中的合約（這些款項會在解約流程中處理）
  AND (ct.status IS NULL OR ct.status NOT IN ('pending_termination', 'terminated'))
ORDER BY
    CASE
        WHEN p.payment_status = 'overdue' THEN 0
        ELSE 1
    END,
    p.due_date ASC;

COMMENT ON VIEW v_payments_due IS '應收款列表（排除解約中合約），含緊急度標記';

-- ============================================================================
-- 4. 修改 v_termination_cases：新增待收款統計與合約類型
-- ============================================================================

-- 先刪除再重建（因為欄位結構有變）
DROP VIEW IF EXISTS v_termination_cases CASCADE;

CREATE OR REPLACE VIEW v_termination_cases AS
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
    tc.checklist,
    tc.notes,
    tc.created_at,
    -- 呆帳相關欄位
    tc.authority_reported_date,
    tc.authority_response_date,
    tc.is_bad_debt,
    tc.bad_debt_amount,
    tc.arrears_amount,
    -- 合約資訊
    ct.contract_number,
    ct.start_date AS contract_start_date,
    ct.end_date AS contract_end_date,
    ct.monthly_rent,
    ct.deposit AS contract_deposit,
    ct.position_number,
    ct.contract_type,  -- 用於前端判斷 checklist 項目
    -- 客戶資訊
    c.id AS customer_id,
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.line_user_id,
    -- 場館資訊
    b.id AS branch_id,
    b.name AS branch_name,
    -- 待收款統計（這個合約的未付款項）
    COALESCE(pending_payments.pending_count, 0) AS pending_payment_count,
    COALESCE(pending_payments.pending_amount, 0) AS pending_payment_amount,
    -- 計算進度（動態，根據合約類型）
    -- 實體辦公室：8 個步驟
    -- 純登記（虛擬辦公室）：5 個步驟（不含 belongings/keys/room）
    CASE
        WHEN ct.contract_type IN ('virtual_office', 'business_registration') THEN
            (CASE WHEN (tc.checklist->>'notice_confirmed')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'doc_submitted')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'doc_approved')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'settlement_calculated')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'refund_processed')::boolean THEN 1 ELSE 0 END)
        ELSE
            (CASE WHEN (tc.checklist->>'notice_confirmed')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'belongings_removed')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'keys_returned')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'room_inspected')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'doc_submitted')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'doc_approved')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'settlement_calculated')::boolean THEN 1 ELSE 0 END +
             CASE WHEN (tc.checklist->>'refund_processed')::boolean THEN 1 ELSE 0 END)
    END AS progress,
    -- 總步驟數
    CASE
        WHEN ct.contract_type IN ('virtual_office', 'business_registration') THEN 5
        ELSE 8
    END AS total_steps,
    -- 狀態標籤
    CASE tc.status
        WHEN 'notice_received' THEN '已收到通知'
        WHEN 'moving_out' THEN '搬遷中'
        WHEN 'pending_doc' THEN '等待公文'
        WHEN 'pending_settlement' THEN '押金結算中'
        WHEN 'pending_authority' THEN '通報主管機關'
        WHEN 'completed' THEN '已完成'
        WHEN 'cancelled' THEN '已取消'
    END AS status_label,
    -- 解約類型標籤
    CASE tc.termination_type
        WHEN 'early' THEN '提前解約'
        WHEN 'not_renewing' THEN '到期不續約'
        WHEN 'breach' THEN '違約終止'
    END AS type_label,
    -- 是否為實體辦公室（用於前端判斷 checklist）
    CASE
        WHEN ct.contract_type IN ('virtual_office', 'business_registration') THEN FALSE
        ELSE TRUE
    END AS is_physical_office
FROM termination_cases tc
JOIN contracts ct ON tc.contract_id = ct.id
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
-- 計算待收款項
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) AS pending_count,
        SUM(amount + COALESCE(late_fee, 0)) AS pending_amount
    FROM payments
    WHERE contract_id = tc.contract_id
      AND payment_status IN ('pending', 'overdue')
) pending_payments ON TRUE
ORDER BY
    CASE tc.status
        WHEN 'pending_authority' THEN 0  -- 呆帳最緊急
        WHEN 'pending_doc' THEN 1
        WHEN 'pending_settlement' THEN 2
        WHEN 'moving_out' THEN 3
        WHEN 'notice_received' THEN 4
        ELSE 5
    END,
    tc.created_at DESC;

COMMENT ON VIEW v_termination_cases IS '解約案件視圖，含待收款統計與呆帳資訊';

-- ============================================================================
-- 5. 合約狀態同步 Trigger
-- ============================================================================

-- 當建立解約案件時，自動將合約狀態改為 pending_termination
CREATE OR REPLACE FUNCTION sync_contract_termination_status()
RETURNS TRIGGER AS $$
BEGIN
    -- 建立解約案件時，更新合約狀態
    IF TG_OP = 'INSERT' THEN
        UPDATE contracts
        SET status = 'pending_termination',
            updated_at = NOW()
        WHERE id = NEW.contract_id
          AND status = 'active';

    -- 解約案件完成時，更新合約狀態為 terminated
    ELSIF TG_OP = 'UPDATE' AND NEW.status = 'completed' AND OLD.status != 'completed' THEN
        UPDATE contracts
        SET status = 'terminated',
            updated_at = NOW()
        WHERE id = NEW.contract_id;

    -- 解約案件取消時，恢復合約狀態為 active
    ELSIF TG_OP = 'UPDATE' AND NEW.status = 'cancelled' AND OLD.status != 'cancelled' THEN
        UPDATE contracts
        SET status = 'active',
            updated_at = NOW()
        WHERE id = NEW.contract_id
          AND status = 'pending_termination';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_sync_contract_termination ON termination_cases;
CREATE TRIGGER trigger_sync_contract_termination
    AFTER INSERT OR UPDATE ON termination_cases
    FOR EACH ROW
    EXECUTE FUNCTION sync_contract_termination_status();

COMMENT ON FUNCTION sync_contract_termination_status IS '同步合約與解約案件狀態';

-- ============================================================================
-- 6. 計算呆帳金額函數
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_bad_debt(
    p_termination_case_id INTEGER
) RETURNS TABLE (
    arrears_amount NUMERIC,
    deduction_total NUMERIC,
    deposit_amount NUMERIC,
    bad_debt_amount NUMERIC,
    is_bad_debt BOOLEAN
) AS $$
DECLARE
    v_contract_id INTEGER;
    v_deposit NUMERIC;
    v_deduction NUMERIC;
    v_other_deductions NUMERIC;
    v_arrears NUMERIC;
    v_bad_debt NUMERIC;
BEGIN
    -- 取得解約案件資訊
    SELECT
        tc.contract_id,
        COALESCE(tc.deposit_amount, ct.deposit, 0),
        COALESCE(tc.deduction_amount, 0),
        COALESCE(tc.other_deductions, 0)
    INTO v_contract_id, v_deposit, v_deduction, v_other_deductions
    FROM termination_cases tc
    JOIN contracts ct ON tc.contract_id = ct.id
    WHERE tc.id = p_termination_case_id;

    -- 計算欠款（未付款項總額）
    SELECT COALESCE(SUM(p.amount + COALESCE(p.late_fee, 0)), 0)
    INTO v_arrears
    FROM payments p
    WHERE p.contract_id = v_contract_id
      AND p.payment_status IN ('pending', 'overdue');

    -- 計算呆帳金額
    v_bad_debt := v_arrears + v_deduction + v_other_deductions - v_deposit;

    -- 回傳結果
    arrears_amount := v_arrears;
    deduction_total := v_deduction + v_other_deductions;
    deposit_amount := v_deposit;
    bad_debt_amount := GREATEST(0, v_bad_debt);
    is_bad_debt := v_bad_debt > 0;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_bad_debt IS '計算呆帳金額：欠款 + 扣除費用 - 押金';

-- ============================================================================
-- 7. 更新呆帳資訊的觸發器（進入 pending_settlement 時計算）
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_calculate_bad_debt()
RETURNS TRIGGER AS $$
DECLARE
    v_result RECORD;
BEGIN
    -- 當進入 pending_settlement 狀態時，自動計算呆帳
    IF NEW.status = 'pending_settlement' AND OLD.status != 'pending_settlement' THEN
        SELECT * INTO v_result FROM calculate_bad_debt(NEW.id);

        NEW.arrears_amount := v_result.arrears_amount;
        NEW.bad_debt_amount := v_result.bad_debt_amount;
        NEW.is_bad_debt := v_result.is_bad_debt;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_auto_calculate_bad_debt ON termination_cases;
CREATE TRIGGER trigger_auto_calculate_bad_debt
    BEFORE UPDATE ON termination_cases
    FOR EACH ROW
    EXECUTE FUNCTION auto_calculate_bad_debt();

COMMENT ON FUNCTION auto_calculate_bad_debt IS '進入押金結算時自動計算呆帳金額';

-- ============================================================================
-- 8. 重新授權視圖（DROP CASCADE 會移除權限）
-- ============================================================================

-- anon 是 PostgREST 匿名角色（PGRST_DB_ANON_ROLE）
GRANT SELECT, INSERT, UPDATE, DELETE ON v_payments_due TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON v_termination_cases TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON v_payments_due TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON v_termination_cases TO authenticated;

-- ============================================================================
-- 9. 驗證
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Termination v2 Migration 完成 ===';
    RAISE NOTICE '已更新: termination_cases.status 新增 pending_authority';
    RAISE NOTICE '已新增: authority_reported_date, authority_response_date 欄位';
    RAISE NOTICE '已新增: is_bad_debt, bad_debt_amount, arrears_amount 欄位';
    RAISE NOTICE '已更新: v_payments_due 排除解約中合約';
    RAISE NOTICE '已更新: v_termination_cases 新增待收款統計';
    RAISE NOTICE '已新增: sync_contract_termination_status 觸發器';
    RAISE NOTICE '已新增: calculate_bad_debt 函數';
    RAISE NOTICE '已新增: auto_calculate_bad_debt 觸發器';
    RAISE NOTICE '已授權: web_anon 存取視圖';
END $$;
