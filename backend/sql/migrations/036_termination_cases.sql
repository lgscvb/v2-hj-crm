-- ============================================================================
-- Hour Jungle CRM - Termination Cases
-- Migration: 036_termination_cases.sql
-- Date: 2025-12-25
-- Purpose: 解約流程追蹤 - 處理提前解約、退租、不續約等情況
-- ============================================================================

-- ============================================================================
-- 1. 創建 TerminationCase 表（解約流程追蹤）
-- ============================================================================
--
-- 解約流程：
-- 1. notice_received - 客戶通知要解約
-- 2. moving_out - 搬遷作業中
-- 3. pending_doc - 等待稅籍遷出公文
-- 4. pending_settlement - 押金結算中（計算額外使用費）
-- 5. completed - 完成（押金已退還）
--
-- 押金結算邏輯：
-- - 合約到期日（或通知日）到公文核准日之間的天數
-- - 需扣除這段期間的使用費用
-- - 押金 - 扣除費用 = 實際退還金額

CREATE TABLE IF NOT EXISTS termination_cases (
    id              SERIAL PRIMARY KEY,
    contract_id     INTEGER NOT NULL REFERENCES contracts(id),

    -- 解約類型
    termination_type VARCHAR(20) DEFAULT 'not_renewing'
                    CHECK (termination_type IN (
                        'early',           -- 提前解約
                        'not_renewing',    -- 到期不續約
                        'breach'           -- 違約終止
                    )),

    -- 狀態機
    status          VARCHAR(20) DEFAULT 'notice_received'
                    CHECK (status IN (
                        'notice_received',    -- 客戶已通知
                        'moving_out',         -- 搬遷中
                        'pending_doc',        -- 等待公文
                        'pending_settlement', -- 押金結算中
                        'completed',          -- 已完成
                        'cancelled'           -- 已取消（客戶反悔續租）
                    )),

    -- 時間戳記錄
    notice_date         DATE,                -- 客戶通知解約日期
    expected_end_date   DATE,                -- 預計搬離日期
    actual_move_out     DATE,                -- 實際搬離日期
    doc_submitted_date  DATE,                -- 公文送件日期
    doc_approved_date   DATE,                -- 公文核准日期
    settlement_date     DATE,                -- 押金結算日期
    refund_date         DATE,                -- 押金退還日期
    cancelled_at        TIMESTAMPTZ,         -- 取消時間

    -- 押金結算
    deposit_amount      NUMERIC(10,2),       -- 原始押金金額
    deduction_days      INTEGER DEFAULT 0,   -- 扣除天數（公文核准日 - 合約到期日）
    daily_rate          NUMERIC(10,2),       -- 日租金（月租 / 30）
    deduction_amount    NUMERIC(10,2),       -- 扣除金額
    other_deductions    NUMERIC(10,2) DEFAULT 0,  -- 其他扣款（清潔費、損壞等）
    other_deduction_notes TEXT,              -- 其他扣款說明
    refund_amount       NUMERIC(10,2),       -- 實際退還金額

    -- 退款資訊
    refund_method       VARCHAR(20)          -- 退款方式
                        CHECK (refund_method IS NULL OR refund_method IN (
                            'cash',          -- 現金
                            'transfer',      -- 匯款
                            'check'          -- 支票
                        )),
    refund_account      TEXT,                -- 退款帳戶（若匯款）
    refund_receipt      TEXT,                -- 收據編號

    -- 檢查清單
    checklist           JSONB DEFAULT '{
        "notice_confirmed": false,
        "belongings_removed": false,
        "keys_returned": false,
        "room_inspected": false,
        "doc_submitted": false,
        "doc_approved": false,
        "settlement_calculated": false,
        "refund_processed": false
    }'::jsonb,

    -- 備註
    notes               TEXT,
    cancel_reason       TEXT,                -- 取消原因（若客戶反悔）

    -- 系統欄位
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    created_by      TEXT,

    -- 約束：每個合約只能有一個進行中的解約案件
    CONSTRAINT unique_active_termination
        EXCLUDE (contract_id WITH =)
        WHERE (status NOT IN ('completed', 'cancelled'))
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_termination_cases_contract_id ON termination_cases(contract_id);
CREATE INDEX IF NOT EXISTS idx_termination_cases_status ON termination_cases(status)
    WHERE status NOT IN ('completed', 'cancelled');
CREATE INDEX IF NOT EXISTS idx_termination_cases_created_at ON termination_cases(created_at);
CREATE INDEX IF NOT EXISTS idx_termination_cases_doc_dates ON termination_cases(doc_submitted_date, doc_approved_date)
    WHERE status = 'pending_doc';

COMMENT ON TABLE termination_cases IS '解約流程追蹤（Process Manager）- 處理提前解約、退租、不續約';

-- ============================================================================
-- 2. 更新 contracts 表，新增解約相關狀態
-- ============================================================================

-- 備份現有約束
ALTER TABLE contracts DROP CONSTRAINT IF EXISTS contracts_status_check;

-- 新增包含 pending_termination 的約束
ALTER TABLE contracts ADD CONSTRAINT contracts_status_check
    CHECK (status IN (
        'draft',              -- 草稿
        'pending_sign',       -- 待簽署
        'active',             -- 生效中
        'pending_termination',-- 解約中（新增）
        'terminated',         -- 已終止
        'expired',            -- 已到期
        'cancelled'           -- 已取消
    ));

COMMENT ON COLUMN contracts.status IS '合約狀態: draft=草稿, pending_sign=待簽署, active=生效中, pending_termination=解約中, terminated=已終止, expired=已到期, cancelled=已取消';

-- ============================================================================
-- 3. 創建解約案件視圖
-- ============================================================================

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
    ct.contract_number,
    ct.start_date AS contract_start_date,
    ct.end_date AS contract_end_date,
    ct.monthly_rent,
    ct.deposit AS contract_deposit,
    ct.position_number,
    c.id AS customer_id,
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.line_user_id,
    b.id AS branch_id,
    b.name AS branch_name,
    -- 計算進度（8個步驟）
    (CASE WHEN (tc.checklist->>'notice_confirmed')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'belongings_removed')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'keys_returned')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'room_inspected')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'doc_submitted')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'doc_approved')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'settlement_calculated')::boolean THEN 1 ELSE 0 END +
     CASE WHEN (tc.checklist->>'refund_processed')::boolean THEN 1 ELSE 0 END) AS progress,
    -- 狀態標籤
    CASE tc.status
        WHEN 'notice_received' THEN '已收到通知'
        WHEN 'moving_out' THEN '搬遷中'
        WHEN 'pending_doc' THEN '等待公文'
        WHEN 'pending_settlement' THEN '押金結算中'
        WHEN 'completed' THEN '已完成'
        WHEN 'cancelled' THEN '已取消'
    END AS status_label,
    -- 解約類型標籤
    CASE tc.termination_type
        WHEN 'early' THEN '提前解約'
        WHEN 'not_renewing' THEN '到期不續約'
        WHEN 'breach' THEN '違約終止'
    END AS type_label
FROM termination_cases tc
JOIN contracts ct ON tc.contract_id = ct.id
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
ORDER BY
    CASE tc.status
        WHEN 'pending_doc' THEN 0     -- 等待公文最緊急
        WHEN 'pending_settlement' THEN 1
        WHEN 'moving_out' THEN 2
        WHEN 'notice_received' THEN 3
        ELSE 4
    END,
    tc.created_at DESC;

-- ============================================================================
-- 4. PostgREST 權限
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON termination_cases TO web_anon;
GRANT SELECT ON v_termination_cases TO web_anon;
GRANT USAGE, SELECT ON SEQUENCE termination_cases_id_seq TO web_anon;

-- ============================================================================
-- 5. 觸發器：更新 updated_at
-- ============================================================================

CREATE OR REPLACE FUNCTION update_termination_case_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_termination_case_timestamp ON termination_cases;
CREATE TRIGGER trigger_update_termination_case_timestamp
    BEFORE UPDATE ON termination_cases
    FOR EACH ROW
    EXECUTE FUNCTION update_termination_case_timestamp();

-- ============================================================================
-- 6. 輔助函數：計算押金扣除
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_deposit_deduction(
    p_monthly_rent NUMERIC,
    p_contract_end_date DATE,
    p_doc_approved_date DATE
) RETURNS TABLE (
    deduction_days INTEGER,
    daily_rate NUMERIC,
    deduction_amount NUMERIC
) AS $$
BEGIN
    -- 計算超出天數
    deduction_days := GREATEST(0, p_doc_approved_date - p_contract_end_date);

    -- 日租金 = 月租 / 30
    daily_rate := ROUND(p_monthly_rent / 30, 2);

    -- 扣除金額
    deduction_amount := deduction_days * daily_rate;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_deposit_deduction IS '計算押金扣除金額：(公文核准日 - 合約到期日) * 日租金';

-- ============================================================================
-- 7. 驗證
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Termination Cases Migration 完成 ===';
    RAISE NOTICE '已創建: termination_cases 表';
    RAISE NOTICE '已創建: v_termination_cases 視圖';
    RAISE NOTICE '已更新: contracts.status 新增 pending_termination';
    RAISE NOTICE '已創建: calculate_deposit_deduction 函數';
END $$;
