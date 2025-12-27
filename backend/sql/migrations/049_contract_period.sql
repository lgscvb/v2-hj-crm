-- 049_contract_period.sql
-- 新增 contract_period 欄位，用於標註合約期數
-- 續約時沿用合約編號，用 period 區分第幾期

-- 1. 新增欄位
ALTER TABLE contracts
ADD COLUMN IF NOT EXISTS contract_period INTEGER DEFAULT 1;

COMMENT ON COLUMN contracts.contract_period IS '合約期數，第一期=1，續約後遞增';

-- 2. 為現有合約設定期數（根據 renewed_from_id 鏈計算）
-- 先把所有沒有 renewed_from_id 的設為第 1 期
UPDATE contracts
SET contract_period = 1
WHERE renewed_from_id IS NULL AND contract_period IS NULL;

-- 遞迴計算續約鏈的期數
WITH RECURSIVE contract_chain AS (
    -- 基礎：第一期合約
    SELECT
        id,
        contract_number,
        renewed_from_id,
        1 AS period
    FROM contracts
    WHERE renewed_from_id IS NULL

    UNION ALL

    -- 遞迴：找續約合約
    SELECT
        c.id,
        c.contract_number,
        c.renewed_from_id,
        cc.period + 1 AS period
    FROM contracts c
    JOIN contract_chain cc ON c.renewed_from_id = cc.id
)
UPDATE contracts c
SET contract_period = cc.period
FROM contract_chain cc
WHERE c.id = cc.id AND c.contract_period IS NULL;

-- 3. 建立索引（方便查詢同編號不同期數）
CREATE INDEX IF NOT EXISTS idx_contracts_number_period
ON contracts(contract_number, contract_period);

-- 4. 建立唯一約束（同編號 + 同期數 = 唯一）
-- 注意：這會防止重複，但需要確保現有資料沒有衝突
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_contract_number_period'
    ) THEN
        ALTER TABLE contracts
        ADD CONSTRAINT uq_contract_number_period
        UNIQUE (contract_number, contract_period);
    END IF;
EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE '無法建立唯一約束，可能有重複資料';
END $$;
