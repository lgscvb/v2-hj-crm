-- 050_contract_signing_status.sql
-- 新增合約簽署流程狀態：pending_sign, signed
-- 新增 sent_for_sign_at 欄位追蹤送簽時間

-- 1. 新增 sent_for_sign_at 欄位
ALTER TABLE contracts
ADD COLUMN IF NOT EXISTS sent_for_sign_at TIMESTAMPTZ;

COMMENT ON COLUMN contracts.sent_for_sign_at IS '送出簽署的時間';

-- 2. 新增狀態值到 enum（PostgreSQL 需要用 ALTER TYPE）
-- 檢查並新增 pending_sign
DO $$
BEGIN
    -- 檢查 status 欄位是否為 enum 類型
    IF EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_enum e ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'contract_status'
    ) THEN
        -- 是 enum，新增值
        IF NOT EXISTS (SELECT 1 FROM pg_enum WHERE enumlabel = 'pending_sign' AND enumtypid = 'contract_status'::regtype) THEN
            ALTER TYPE contract_status ADD VALUE IF NOT EXISTS 'pending_sign';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_enum WHERE enumlabel = 'signed' AND enumtypid = 'contract_status'::regtype) THEN
            ALTER TYPE contract_status ADD VALUE IF NOT EXISTS 'signed';
        END IF;
    ELSE
        -- 不是 enum，檢查 check constraint
        RAISE NOTICE 'contracts.status 不是 enum 類型，檢查 check constraint';
    END IF;
EXCEPTION
    WHEN others THEN
        RAISE NOTICE 'enum 操作失敗: %', SQLERRM;
END $$;

-- 3. 如果 status 是 varchar + check constraint，更新 constraint
DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    -- 找到 status 欄位的 check constraint
    SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
    WHERE con.conrelid = 'contracts'::regclass
      AND con.contype = 'c'
      AND att.attname = 'status';

    IF constraint_name IS NOT NULL THEN
        -- 刪除舊 constraint
        EXECUTE format('ALTER TABLE contracts DROP CONSTRAINT %I', constraint_name);

        -- 新增包含新狀態的 constraint
        ALTER TABLE contracts ADD CONSTRAINT contracts_status_check
        CHECK (status IN (
            'draft',              -- 草稿（新合約）
            'renewal_draft',      -- 續約草稿
            'pending_sign',       -- 已送簽，等待回簽
            'signed',             -- 已回簽，待啟用
            'active',             -- 已啟用
            'expired',            -- 已過期
            'renewed',            -- 已續約（舊合約）
            'pending_termination', -- 待終止
            'terminated',         -- 已終止
            'cancelled'           -- 已取消
        ));

        RAISE NOTICE '已更新 status check constraint';
    END IF;
EXCEPTION
    WHEN others THEN
        RAISE NOTICE 'constraint 操作: %', SQLERRM;
END $$;

-- 4. 建立索引（用於查詢待簽合約）
CREATE INDEX IF NOT EXISTS idx_contracts_pending_sign
ON contracts(status) WHERE status = 'pending_sign';

CREATE INDEX IF NOT EXISTS idx_contracts_signed
ON contracts(status) WHERE status = 'signed';

-- 5. 建立待簽合約視圖
CREATE OR REPLACE VIEW v_pending_sign_contracts AS
SELECT
    c.id,
    c.contract_number,
    c.contract_period,
    c.customer_id,
    cust.name AS customer_name,
    c.company_name,
    c.branch_id,
    b.name AS branch_name,
    c.status,
    c.start_date,
    c.end_date,
    c.monthly_rent,
    c.sent_for_sign_at,
    c.signed_at,
    -- 計算等待天數
    CASE
        WHEN c.sent_for_sign_at IS NOT NULL THEN
            EXTRACT(DAY FROM NOW() - c.sent_for_sign_at)::INTEGER
        ELSE NULL
    END AS days_pending,
    -- 是否逾期（超過 14 天）
    CASE
        WHEN c.sent_for_sign_at IS NOT NULL
             AND NOW() - c.sent_for_sign_at > INTERVAL '14 days' THEN TRUE
        ELSE FALSE
    END AS is_overdue,
    c.renewed_from_id,
    c.created_at
FROM contracts c
LEFT JOIN customers cust ON c.customer_id = cust.id
LEFT JOIN branches b ON c.branch_id = b.id
WHERE c.status IN ('renewal_draft', 'pending_sign', 'signed')
ORDER BY
    CASE c.status
        WHEN 'pending_sign' THEN 1
        WHEN 'renewal_draft' THEN 2
        WHEN 'signed' THEN 3
    END,
    c.sent_for_sign_at ASC NULLS LAST;

COMMENT ON VIEW v_pending_sign_contracts IS '待簽署合約列表（含草稿、待簽、已簽待啟用）';
