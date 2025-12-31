-- 081_fix_contract_number_constraint.sql
-- 修復 contracts 表的 unique constraint
--
-- 問題：
-- contracts_contract_number_key 約束要求 contract_number 唯一
-- 但續約合約需要沿用原編號並以 contract_period 區分
-- 這導致 renewal_create_draft 時報 409 Conflict
--
-- 解法：
-- 移除 contracts_contract_number_key（只有 contract_number 唯一）
-- 保留 uq_contract_number_period（contract_number + contract_period 唯一）
--
-- Date: 2025-12-31

-- 移除錯誤的 unique constraint（如果存在）
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'contracts_contract_number_key'
        AND conrelid = 'contracts'::regclass
    ) THEN
        ALTER TABLE contracts DROP CONSTRAINT contracts_contract_number_key;
        RAISE NOTICE '✅ 已移除 contracts_contract_number_key 約束';
    ELSE
        RAISE NOTICE '⏭️ contracts_contract_number_key 約束不存在（可能已移除）';
    END IF;
END $$;

-- 確認 uq_contract_number_period 存在
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_contract_number_period'
        AND conrelid = 'contracts'::regclass
    ) THEN
        ALTER TABLE contracts ADD CONSTRAINT uq_contract_number_period
            UNIQUE (contract_number, contract_period);
        RAISE NOTICE '✅ 已建立 uq_contract_number_period 約束';
    ELSE
        RAISE NOTICE '✅ uq_contract_number_period 約束已存在';
    END IF;
END $$;

-- 完成
DO $$
BEGIN
    RAISE NOTICE '=== Migration 081 完成 ===';
    RAISE NOTICE '續約功能現在可以正常使用：';
    RAISE NOTICE '- 同一個 contract_number 可以有多期（contract_period 1, 2, 3...）';
    RAISE NOTICE '- 例如 DZ-112 第 1 期、DZ-112 第 2 期';
END $$;
