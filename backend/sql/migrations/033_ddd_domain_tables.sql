-- ============================================================================
-- Hour Jungle CRM - DDD Domain Tables
-- Migration: 033_ddd_domain_tables.sql
-- Date: 2025-12-22
-- Purpose: 實作 PRD v2.1/v2.2 + SSD v1.2 定義的領域模型
-- ============================================================================

-- ============================================================================
-- 1. 擴展 payments.payment_status，新增 cancelled 狀態
-- ============================================================================

-- 刪除舊的 CHECK 約束
ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_payment_status_check;

-- 新增包含 cancelled 的 CHECK 約束
ALTER TABLE payments ADD CONSTRAINT payments_payment_status_check
    CHECK (payment_status IN ('pending', 'paid', 'overdue', 'waived', 'cancelled'));

-- 新增取消相關欄位
ALTER TABLE payments ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

COMMENT ON COLUMN payments.payment_status IS '繳費狀態: pending=待繳, paid=已繳, overdue=逾期, waived=免收, cancelled=已取消（合約終止）';
COMMENT ON COLUMN payments.cancelled_at IS '取消時間（合約終止時標記）';
COMMENT ON COLUMN payments.cancel_reason IS '取消原因';

-- ============================================================================
-- 2. 創建 RenewalCase 表（獨立續約流程追蹤）
-- ============================================================================

CREATE TABLE IF NOT EXISTS renewal_cases (
    id              SERIAL PRIMARY KEY,
    contract_id     INTEGER NOT NULL REFERENCES contracts(id),

    -- 狀態機
    status          VARCHAR(20) DEFAULT 'created'
                    CHECK (status IN ('created', 'notified', 'confirmed', 'paid', 'invoiced', 'completed', 'cancelled')),

    -- 時間戳記錄（每個階段完成的時間）
    notified_at     TIMESTAMPTZ,     -- 發送通知的時間
    confirmed_at    TIMESTAMPTZ,     -- 客戶確認續約的時間
    paid_at         TIMESTAMPTZ,     -- 收到續約款的時間
    invoiced_at     TIMESTAMPTZ,     -- 開立發票的時間
    signed_at       TIMESTAMPTZ,     -- 簽署新合約的時間
    cancelled_at    TIMESTAMPTZ,     -- 取消的時間

    -- 續約結果
    new_contract_id INTEGER REFERENCES contracts(id),  -- 續約產生的新合約
    cancel_reason   TEXT,                              -- 取消原因

    -- 預留資訊
    reserved_position_number INTEGER,  -- 預留的位置編號（若有）

    -- 系統欄位
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    created_by      TEXT,

    -- 約束：每個合約只能有一個進行中的續約
    CONSTRAINT unique_active_renewal UNIQUE (contract_id)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_renewal_cases_contract_id ON renewal_cases(contract_id);
CREATE INDEX IF NOT EXISTS idx_renewal_cases_status ON renewal_cases(status) WHERE status NOT IN ('completed', 'cancelled');
CREATE INDEX IF NOT EXISTS idx_renewal_cases_created_at ON renewal_cases(created_at);

COMMENT ON TABLE renewal_cases IS '續約流程追蹤（Process Manager）- 每個合約到期前自動產生';

-- ============================================================================
-- 3. 創建 Position Reservations 表（座位預留）
-- ============================================================================

CREATE TABLE IF NOT EXISTS position_reservations (
    id              SERIAL PRIMARY KEY,
    floor_plan_id   INTEGER REFERENCES floor_plans(id),
    position_number INTEGER NOT NULL,
    renewal_case_id INTEGER REFERENCES renewal_cases(id),

    -- 預留時間
    reserved_at     TIMESTAMPTZ DEFAULT NOW(),
    expires_at      TIMESTAMPTZ,     -- 預留過期時間（通常 7 天）

    -- 狀態
    status          VARCHAR(20) DEFAULT 'active'
                    CHECK (status IN ('active', 'released', 'converted')),
    released_at     TIMESTAMPTZ,
    release_reason  TEXT,

    -- 約束
    CONSTRAINT unique_active_reservation UNIQUE (floor_plan_id, position_number, renewal_case_id)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_position_reservations_renewal ON position_reservations(renewal_case_id);
CREATE INDEX IF NOT EXISTS idx_position_reservations_position ON position_reservations(floor_plan_id, position_number)
    WHERE status = 'active';

COMMENT ON TABLE position_reservations IS '座位預留表 - 續約流程中預留原座位';

-- ============================================================================
-- 4. 創建 Waive Requests 表（免收申請）
-- ============================================================================

CREATE TABLE IF NOT EXISTS waive_requests (
    id              SERIAL PRIMARY KEY,
    payment_id      INTEGER NOT NULL REFERENCES payments(id),

    -- 申請資訊
    requested_by    TEXT NOT NULL,           -- 申請人
    request_reason  TEXT NOT NULL,           -- 申請原因
    request_amount  NUMERIC(10,2),           -- 申請免收金額（通常 = payment.amount）

    -- 狀態
    status          VARCHAR(20) DEFAULT 'pending'
                    CHECK (status IN ('pending', 'approved', 'rejected')),

    -- 審批資訊
    approved_by     TEXT,
    approved_at     TIMESTAMPTZ,
    reject_reason   TEXT,

    -- 冪等性 Key
    idempotency_key VARCHAR(64) UNIQUE,      -- 防止重複提交

    -- 系統欄位
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_waive_requests_payment ON waive_requests(payment_id);
CREATE INDEX IF NOT EXISTS idx_waive_requests_status ON waive_requests(status) WHERE status = 'pending';

COMMENT ON TABLE waive_requests IS '免收申請表 - 需要主管核准';

-- ============================================================================
-- 5. 創建獨立的 Invoices 表
-- ============================================================================

CREATE TABLE IF NOT EXISTS invoices (
    id              SERIAL PRIMARY KEY,
    contract_id     INTEGER REFERENCES contracts(id),  -- 從 payment 推導

    -- 發票資訊
    invoice_number  VARCHAR(20) UNIQUE NOT NULL,
    invoice_date    DATE NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,

    -- 快照（開票當下的客戶資料）
    snapshot_company_name VARCHAR(200),
    snapshot_tax_id VARCHAR(20),
    snapshot_address TEXT,

    -- 狀態
    status          VARCHAR(20) DEFAULT 'issued'
                    CHECK (status IN ('issued', 'voided')),

    -- 作廢資訊
    voided_at       TIMESTAMPTZ,
    void_reason     TEXT,

    -- 折讓
    allowance_amount NUMERIC(10,2) DEFAULT 0,
    allowance_number VARCHAR(20),

    -- 外部 API 回應
    api_response    JSONB,

    -- 系統欄位
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    created_by      TEXT
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_invoices_contract ON invoices(contract_id);
CREATE INDEX IF NOT EXISTS idx_invoices_number ON invoices(invoice_number);
CREATE INDEX IF NOT EXISTS idx_invoices_date ON invoices(invoice_date);

COMMENT ON TABLE invoices IS '發票表 - 獨立實體，透過關聯表連接 payments';

-- ============================================================================
-- 6. 創建 Payment-Invoice 關聯表
-- ============================================================================

CREATE TABLE IF NOT EXISTS payment_invoices (
    payment_id      INTEGER REFERENCES payments(id),
    invoice_id      INTEGER REFERENCES invoices(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (payment_id, invoice_id)
);

COMMENT ON TABLE payment_invoices IS 'Payment 與 Invoice 的多對多關聯表';

-- ============================================================================
-- 7. 創建 Batch Tasks 表（批量操作追蹤）
-- ============================================================================

CREATE TABLE IF NOT EXISTS batch_tasks (
    id              VARCHAR(36) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    task_type       VARCHAR(50) NOT NULL,    -- send_reminder, send_renewal_notice

    -- 狀態
    status          VARCHAR(20) DEFAULT 'pending'
                    CHECK (status IN ('pending', 'processing', 'completed', 'partial_success', 'failed')),

    -- 統計
    total_count     INTEGER DEFAULT 0,
    success_count   INTEGER DEFAULT 0,
    failed_count    INTEGER DEFAULT 0,

    -- 系統欄位
    created_by      TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS batch_task_items (
    id              SERIAL PRIMARY KEY,
    task_id         VARCHAR(36) REFERENCES batch_tasks(id),
    target_id       INTEGER NOT NULL,        -- payment_id 或 contract_id
    target_type     VARCHAR(20),             -- payment, contract

    -- 狀態
    status          VARCHAR(20) DEFAULT 'pending'
                    CHECK (status IN ('pending', 'success', 'failed')),
    error_code      VARCHAR(50),
    error_message   TEXT,

    -- 時間
    processed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_batch_task_items_task ON batch_task_items(task_id);

COMMENT ON TABLE batch_tasks IS '批量任務主表';
COMMENT ON TABLE batch_task_items IS '批量任務項目（可用 PostgREST embed 查詢）';

-- ============================================================================
-- 8. 更新視圖
-- ============================================================================

-- 8.1 更新應收款視圖（排除 cancelled）
CREATE OR REPLACE VIEW v_payments_due AS
SELECT
    p.id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.amount + COALESCE(p.late_fee, 0) AS total_due,
    p.payment_status,
    p.due_date,
    p.paid_at,
    p.overdue_days,
    p.notes,
    c.name AS customer_name,
    c.phone AS customer_phone,
    c.line_user_id,
    b.name AS branch_name,
    ct.contract_number,
    ct.company_name,
    CASE
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 30 THEN 'critical'
        WHEN p.payment_status = 'overdue' AND p.overdue_days > 14 THEN 'high'
        WHEN p.payment_status = 'overdue' THEN 'medium'
        WHEN p.due_date <= CURRENT_DATE + INTERVAL '7 days' THEN 'upcoming'
        ELSE 'normal'
    END AS urgency
FROM payments p
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
JOIN contracts ct ON p.contract_id = ct.id
WHERE p.payment_status IN ('pending', 'overdue')  -- 排除 cancelled, waived, paid
ORDER BY
    CASE p.payment_status WHEN 'overdue' THEN 0 ELSE 1 END,
    p.due_date ASC;

-- 8.2 創建續約案件視圖
CREATE OR REPLACE VIEW v_renewal_cases AS
SELECT
    rc.id,
    rc.contract_id,
    rc.status,
    rc.notified_at,
    rc.confirmed_at,
    rc.paid_at,
    rc.invoiced_at,
    rc.signed_at,
    rc.new_contract_id,
    rc.created_at,
    ct.contract_number,
    ct.end_date AS contract_end_date,
    ct.monthly_rent,
    ct.position_number,
    c.id AS customer_id,
    c.name AS customer_name,
    c.company_name,
    c.line_user_id,
    b.id AS branch_id,
    b.name AS branch_name,
    -- 計算進度
    (CASE WHEN rc.notified_at IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN rc.confirmed_at IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN rc.paid_at IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN rc.invoiced_at IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN rc.signed_at IS NOT NULL THEN 1 ELSE 0 END) AS progress,
    -- 到期天數
    ct.end_date - CURRENT_DATE AS days_remaining
FROM renewal_cases rc
JOIN contracts ct ON rc.contract_id = ct.id
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
ORDER BY ct.end_date ASC;

-- 8.3 創建免收申請視圖
CREATE OR REPLACE VIEW v_waive_requests AS
SELECT
    wr.id,
    wr.payment_id,
    wr.requested_by,
    wr.request_reason,
    wr.request_amount,
    wr.status,
    wr.approved_by,
    wr.approved_at,
    wr.reject_reason,
    wr.created_at,
    p.payment_period,
    p.amount AS payment_amount,
    p.payment_status,
    c.id AS customer_id,
    c.name AS customer_name,
    c.company_name,
    b.id AS branch_id,
    b.name AS branch_name,
    ct.contract_number
FROM waive_requests wr
JOIN payments p ON wr.payment_id = p.id
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
JOIN contracts ct ON p.contract_id = ct.id
ORDER BY
    CASE wr.status WHEN 'pending' THEN 0 ELSE 1 END,
    wr.created_at DESC;

-- ============================================================================
-- 9. PostgREST 權限
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON renewal_cases TO web_anon;
GRANT SELECT, INSERT, UPDATE ON position_reservations TO web_anon;
GRANT SELECT, INSERT, UPDATE ON waive_requests TO web_anon;
GRANT SELECT, INSERT, UPDATE ON invoices TO web_anon;
GRANT SELECT, INSERT, DELETE ON payment_invoices TO web_anon;
GRANT SELECT, INSERT, UPDATE ON batch_tasks TO web_anon;
GRANT SELECT, INSERT, UPDATE ON batch_task_items TO web_anon;

GRANT SELECT ON v_renewal_cases TO web_anon;
GRANT SELECT ON v_waive_requests TO web_anon;

GRANT USAGE, SELECT ON SEQUENCE renewal_cases_id_seq TO web_anon;
GRANT USAGE, SELECT ON SEQUENCE position_reservations_id_seq TO web_anon;
GRANT USAGE, SELECT ON SEQUENCE waive_requests_id_seq TO web_anon;
GRANT USAGE, SELECT ON SEQUENCE invoices_id_seq TO web_anon;
GRANT USAGE, SELECT ON SEQUENCE batch_task_items_id_seq TO web_anon;

-- ============================================================================
-- 10. 驗證
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== DDD Domain Tables Migration 完成 ===';
    RAISE NOTICE '已創建: renewal_cases, position_reservations, waive_requests, invoices, payment_invoices, batch_tasks, batch_task_items';
    RAISE NOTICE '已更新: payments (新增 cancelled 狀態)';
    RAISE NOTICE '已創建視圖: v_renewal_cases, v_waive_requests';
END $$;
