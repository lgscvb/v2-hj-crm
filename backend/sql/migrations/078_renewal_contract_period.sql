-- 078_renewal_contract_period.sql
-- 續約合約沿用編號 + contract_period 區分
--
-- 修改項目：
-- 1. contract_period 初始化 (DEFAULT 1 + NOT NULL)
-- 2. partial unique index 保護（同一舊合約只能有一筆草稿/待簽）
-- 3. 建立 get_or_create_renewal_draft 函數
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. contract_period 初始化
-- ============================================================================

-- 先將 NULL 補成 1
UPDATE contracts SET contract_period = 1 WHERE contract_period IS NULL;

-- 設定 DEFAULT 和 NOT NULL
ALTER TABLE contracts
    ALTER COLUMN contract_period SET DEFAULT 1,
    ALTER COLUMN contract_period SET NOT NULL;

-- ============================================================================
-- 2. partial unique index：同一舊合約只能有一筆草稿/待簽
-- ============================================================================

-- 先刪除可能存在的舊 index
DROP INDEX IF EXISTS idx_contracts_one_draft_per_renewal;

-- 建立 partial unique index
-- 保護：同一 renewed_from_id 只能有一筆 draft 或 pending_sign
CREATE UNIQUE INDEX idx_contracts_one_draft_per_renewal
ON contracts (renewed_from_id)
WHERE renewed_from_id IS NOT NULL
  AND status IN ('draft', 'pending_sign');

COMMENT ON INDEX idx_contracts_one_draft_per_renewal IS
'確保同一舊合約只能有一筆續約草稿或待簽合約';

-- ============================================================================
-- 3. get_or_create_renewal_draft 函數
-- ============================================================================

CREATE OR REPLACE FUNCTION get_or_create_renewal_draft(
    p_old_contract_id INT,
    p_new_start_date DATE DEFAULT NULL,
    p_new_end_date DATE DEFAULT NULL,
    p_new_monthly_rent NUMERIC DEFAULT NULL,
    p_created_by TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_old_contract RECORD;
    v_existing_draft RECORD;
    v_new_contract_id INT;
    v_new_period INT;
    v_new_start DATE;
    v_new_end DATE;
BEGIN
    -- 1. 取得舊合約資訊
    SELECT * INTO v_old_contract
    FROM contracts
    WHERE id = p_old_contract_id;

    IF v_old_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '找不到舊合約',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- 2. 檢查是否已有草稿或待簽合約
    SELECT * INTO v_existing_draft
    FROM contracts
    WHERE renewed_from_id = p_old_contract_id
      AND status IN ('draft', 'pending_sign');

    IF v_existing_draft IS NOT NULL THEN
        -- 已存在，直接回傳
        RETURN jsonb_build_object(
            'success', true,
            'action', 'existing',
            'message', '已有續約草稿，返回現有草稿',
            'contract_id', v_existing_draft.id,
            'contract_number', v_existing_draft.contract_number,
            'contract_period', v_existing_draft.contract_period,
            'status', v_existing_draft.status
        );
    END IF;

    -- 3. 計算新合約參數
    v_new_period := COALESCE(v_old_contract.contract_period, 1) + 1;

    -- 新合約起始日：預設為舊合約結束日 + 1 天
    v_new_start := COALESCE(p_new_start_date, v_old_contract.end_date + INTERVAL '1 day');

    -- 新合約結束日：預設為起始日 + 1 年 - 1 天
    v_new_end := COALESCE(p_new_end_date, v_new_start + INTERVAL '1 year' - INTERVAL '1 day');

    -- 4. 建立新合約草稿（沿用原編號）
    INSERT INTO contracts (
        contract_number,
        contract_period,
        customer_id,
        branch_id,
        contract_type,
        plan_name,
        rental_address,
        start_date,
        end_date,
        original_price,
        discount_rate,
        monthly_rent,
        deposit,
        deposit_status,
        payment_cycle,
        payment_day,
        status,
        position_number,
        company_name,
        representative_name,
        representative_address,
        id_number,
        company_tax_id,
        phone,
        email,
        renewed_from_id,
        is_billable,
        created_by,
        notes
    )
    SELECT
        v_old_contract.contract_number,           -- 沿用原編號
        v_new_period,                              -- 期數 +1
        v_old_contract.customer_id,
        v_old_contract.branch_id,
        v_old_contract.contract_type,
        v_old_contract.plan_name,
        v_old_contract.rental_address,
        v_new_start,                               -- 新起始日
        v_new_end,                                 -- 新結束日
        v_old_contract.original_price,
        v_old_contract.discount_rate,
        COALESCE(p_new_monthly_rent, v_old_contract.monthly_rent),  -- 新租金或沿用
        v_old_contract.deposit,
        'held',                                    -- 押金狀態重置
        v_old_contract.payment_cycle,
        v_old_contract.payment_day,
        'draft',                                   -- 草稿狀態
        v_old_contract.position_number,
        v_old_contract.company_name,
        v_old_contract.representative_name,
        v_old_contract.representative_address,
        v_old_contract.id_number,
        v_old_contract.company_tax_id,
        v_old_contract.phone,
        v_old_contract.email,
        p_old_contract_id,                         -- 連結舊合約
        v_old_contract.is_billable,
        p_created_by,
        '續約草稿（自動建立）'
    RETURNING id INTO v_new_contract_id;

    -- 5. 回傳結果
    RETURN jsonb_build_object(
        'success', true,
        'action', 'created',
        'message', '已建立續約草稿',
        'contract_id', v_new_contract_id,
        'contract_number', v_old_contract.contract_number,
        'contract_period', v_new_period,
        'status', 'draft',
        'old_contract_id', p_old_contract_id,
        'new_start_date', v_new_start,
        'new_end_date', v_new_end
    );

EXCEPTION
    WHEN unique_violation THEN
        -- 並發情況：其他人同時建立了草稿
        SELECT * INTO v_existing_draft
        FROM contracts
        WHERE renewed_from_id = p_old_contract_id
          AND status IN ('draft', 'pending_sign');

        RETURN jsonb_build_object(
            'success', true,
            'action', 'existing',
            'message', '已有續約草稿（並發建立）',
            'contract_id', v_existing_draft.id,
            'contract_number', v_existing_draft.contract_number,
            'contract_period', v_existing_draft.contract_period,
            'status', v_existing_draft.status
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'code', 'DB_ERROR'
        );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_or_create_renewal_draft IS
'取得或建立續約草稿（冪等）：
- 若已有草稿/待簽，直接回傳
- 若無，建立新草稿（沿用原編號 + period +1）
- partial unique index 保護並發';

-- ============================================================================
-- 4. 付款搬移函數（草稿建立後呼叫）
-- ============================================================================

CREATE OR REPLACE FUNCTION migrate_renewal_payments(
    p_old_contract_id INT,
    p_new_contract_id INT
)
RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
    v_migrated_count INT := 0;
BEGIN
    -- 取得新合約資訊
    SELECT * INTO v_new_contract
    FROM contracts
    WHERE id = p_new_contract_id;

    IF v_new_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '找不到新合約',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- 搬移付款：due_date 在新合約區間內的 pending/paid 付款
    UPDATE payments
    SET
        contract_id = p_new_contract_id,
        notes = COALESCE(notes, '') || E'\n[系統] 自動從舊合約 #' || p_old_contract_id || ' 搬移'
    WHERE contract_id = p_old_contract_id
      AND due_date >= v_new_contract.start_date
      AND payment_status IN ('pending', 'paid', 'overdue')
      AND payment_type = 'rent';

    GET DIAGNOSTICS v_migrated_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'migrated_count', v_migrated_count,
        'old_contract_id', p_old_contract_id,
        'new_contract_id', p_new_contract_id,
        'new_start_date', v_new_contract.start_date
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION migrate_renewal_payments IS
'搬移付款到新合約：將 due_date 在新合約區間的付款自動轉移';

-- ============================================================================
-- 5. 驗證
-- ============================================================================

DO $$
DECLARE
    v_null_period_count INT;
    v_index_exists BOOLEAN;
BEGIN
    -- 檢查 NULL period
    SELECT COUNT(*) INTO v_null_period_count
    FROM contracts WHERE contract_period IS NULL;

    -- 檢查 index
    SELECT EXISTS(
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_contracts_one_draft_per_renewal'
    ) INTO v_index_exists;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 078 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '✅ contract_period: DEFAULT 1, NOT NULL';
    RAISE NOTICE '✅ partial unique index: idx_contracts_one_draft_per_renewal';
    RAISE NOTICE '✅ 函數: get_or_create_renewal_draft（冪等建立）';
    RAISE NOTICE '✅ 函數: migrate_renewal_payments（付款搬移）';
    RAISE NOTICE '';
    RAISE NOTICE '--- 驗證 ---';
    RAISE NOTICE 'NULL period 數量: % (應為 0)', v_null_period_count;
    RAISE NOTICE 'Index 存在: %', v_index_exists;
END $$;
