-- Migration: 039_renewal_v2.sql
-- Description: 續約流程 V2 - 草稿機制 + 資料一致性保護
-- Date: 2025-12-26

-- ============================================================================
-- 1. 擴展 contracts.status，新增 renewal_draft 狀態
-- ============================================================================

-- 先移除舊的 CHECK 約束（如果存在）
ALTER TABLE contracts DROP CONSTRAINT IF EXISTS contracts_status_check;

-- 新增包含 renewal_draft 的 CHECK 約束
ALTER TABLE contracts ADD CONSTRAINT contracts_status_check
    CHECK (status IN (
        'draft',              -- 草稿（新建合約用）
        'active',             -- 生效中
        'expired',            -- 已到期
        'terminated',         -- 已終止
        'renewed',            -- 已續約（被新合約取代）
        'pending_termination', -- 解約中
        'renewal_draft'       -- 續約草稿（新增）
    ));

COMMENT ON COLUMN contracts.status IS '合約狀態: draft=草稿, active=生效中, expired=已到期, terminated=已終止, renewed=已續約, pending_termination=解約中, renewal_draft=續約草稿';

-- ============================================================================
-- 2. 新增 renewed_from_id 欄位（追溯續約來源）
-- ============================================================================

ALTER TABLE contracts ADD COLUMN IF NOT EXISTS renewed_from_id INT REFERENCES contracts(id);
COMMENT ON COLUMN contracts.renewed_from_id IS '此合約是從哪張合約續約來的（用於追溯）';

-- 建立索引
CREATE INDEX IF NOT EXISTS idx_contracts_renewed_from ON contracts(renewed_from_id);

-- ============================================================================
-- 3. 修改 v_renewal_reminders 視圖
-- 排除：已有續約草稿的合約、已簽約的合約
-- ============================================================================

CREATE OR REPLACE VIEW v_renewal_reminders AS
SELECT
    ct.id AS contract_id,
    ct.contract_number,
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
    -- 續約追蹤欄位（舊系統）
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_paid_at,
    ct.renewal_invoiced_at,
    ct.renewal_signed_at,
    ct.renewal_notes,
    ct.invoice_status,
    -- 剩餘天數
    ct.end_date - CURRENT_DATE AS days_until_expiry,
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
    -- 是否有續約草稿
    EXISTS (
        SELECT 1 FROM contracts c2
        WHERE c2.renewed_from_id = ct.id
          AND c2.status IN ('active', 'renewal_draft')
    ) AS has_renewal_draft
FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'  -- 包含過期 30 天內的
  -- ★ 排除已有續約草稿或新合約的
  AND NOT EXISTS (
      SELECT 1 FROM contracts c2
      WHERE c2.renewed_from_id = ct.id
        AND c2.status IN ('active', 'renewal_draft')
  )
  -- ★ 排除已標記簽約完成的（舊系統相容）
  AND ct.renewal_signed_at IS NULL
ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖（V2）- 排除已有續約草稿和已簽約的合約';

-- ============================================================================
-- 4. 建立續約操作記錄表（用於冪等性和追蹤）
-- ============================================================================

CREATE TABLE IF NOT EXISTS renewal_operations (
    id                  SERIAL PRIMARY KEY,
    idempotency_key     VARCHAR(64) UNIQUE,           -- 冪等性 Key（防止重複提交）
    old_contract_id     INT NOT NULL REFERENCES contracts(id),
    new_contract_id     INT REFERENCES contracts(id), -- 新合約（可能是草稿）

    -- 狀態
    status              VARCHAR(20) DEFAULT 'draft'
                        CHECK (status IN ('draft', 'activated', 'cancelled')),

    -- 時間戳
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    activated_at        TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,

    -- 操作者
    created_by          TEXT,
    activated_by        TEXT
);

CREATE INDEX IF NOT EXISTS idx_renewal_operations_old_contract ON renewal_operations(old_contract_id);
CREATE INDEX IF NOT EXISTS idx_renewal_operations_idempotency ON renewal_operations(idempotency_key);

COMMENT ON TABLE renewal_operations IS '續約操作記錄（用於冪等性保護和操作追蹤）';

-- ============================================================================
-- 5. 建立續約啟用函數（使用 Transaction）
-- ============================================================================

CREATE OR REPLACE FUNCTION activate_renewal(
    p_new_contract_id INT,
    p_activated_by TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
    v_old_contract_id INT;
    v_result JSONB;
BEGIN
    -- 1. 取得新合約資訊
    SELECT * INTO v_new_contract
    FROM contracts
    WHERE id = p_new_contract_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '找不到合約');
    END IF;

    IF v_new_contract.status != 'renewal_draft' THEN
        RETURN jsonb_build_object('success', false, 'error', '合約狀態不是續約草稿');
    END IF;

    v_old_contract_id := v_new_contract.renewed_from_id;

    IF v_old_contract_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '找不到原合約關聯');
    END IF;

    -- 2. 啟用新合約
    UPDATE contracts
    SET status = 'active',
        updated_at = NOW()
    WHERE id = p_new_contract_id
      AND status = 'renewal_draft';  -- 確保狀態正確

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '啟用新合約失敗');
    END IF;

    -- 3. 更新舊合約狀態
    UPDATE contracts
    SET status = 'renewed',
        updated_at = NOW()
    WHERE id = v_old_contract_id
      AND status = 'active';

    -- 4. 更新續約操作記錄（如果有）
    UPDATE renewal_operations
    SET status = 'activated',
        activated_at = NOW(),
        activated_by = p_activated_by
    WHERE new_contract_id = p_new_contract_id
      AND status = 'draft';

    -- 5. 更新 renewal_cases（如果使用新系統）
    UPDATE renewal_cases
    SET status = 'completed',
        signed_at = NOW(),
        new_contract_id = p_new_contract_id
    WHERE contract_id = v_old_contract_id
      AND status NOT IN ('completed', 'cancelled');

    RETURN jsonb_build_object(
        'success', true,
        'new_contract_id', p_new_contract_id,
        'old_contract_id', v_old_contract_id,
        'message', '續約啟用成功'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION activate_renewal IS '啟用續約草稿（使用 Transaction 保護）';

-- ============================================================================
-- 6. 建立取消續約草稿函數
-- ============================================================================

CREATE OR REPLACE FUNCTION cancel_renewal_draft(
    p_new_contract_id INT,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
BEGIN
    -- 取得新合約資訊
    SELECT * INTO v_new_contract
    FROM contracts
    WHERE id = p_new_contract_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '找不到合約');
    END IF;

    IF v_new_contract.status != 'renewal_draft' THEN
        RETURN jsonb_build_object('success', false, 'error', '只能取消續約草稿狀態的合約');
    END IF;

    -- 刪除草稿合約（或標記為 cancelled）
    DELETE FROM contracts
    WHERE id = p_new_contract_id
      AND status = 'renewal_draft';

    -- 更新操作記錄
    UPDATE renewal_operations
    SET status = 'cancelled',
        cancelled_at = NOW()
    WHERE new_contract_id = p_new_contract_id;

    RETURN jsonb_build_object(
        'success', true,
        'deleted_contract_id', p_new_contract_id,
        'message', '續約草稿已取消'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cancel_renewal_draft IS '取消續約草稿';

-- ============================================================================
-- 7. 授權
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON renewal_operations TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE renewal_operations_id_seq TO anon, authenticated;
GRANT EXECUTE ON FUNCTION activate_renewal TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cancel_renewal_draft TO anon, authenticated;

-- ============================================================================
-- 8. 驗證
-- ============================================================================

DO $$
DECLARE
    v_count INT;
BEGIN
    -- 檢查有多少合約會從續約提醒中移除（因為已簽約）
    SELECT COUNT(*) INTO v_count
    FROM contracts
    WHERE status = 'active'
      AND renewal_signed_at IS NOT NULL
      AND end_date <= CURRENT_DATE + INTERVAL '90 days';

    RAISE NOTICE '=== Renewal V2 Migration 完成 ===';
    RAISE NOTICE '已新增: contracts.status = renewal_draft';
    RAISE NOTICE '已新增: contracts.renewed_from_id 欄位';
    RAISE NOTICE '已新增: renewal_operations 表（冪等性保護）';
    RAISE NOTICE '已新增: activate_renewal 函數（Transaction 保護）';
    RAISE NOTICE '已新增: cancel_renewal_draft 函數';
    RAISE NOTICE '已更新: v_renewal_reminders 視圖';
    RAISE NOTICE '將從續約提醒移除 % 筆已簽約合約', v_count;
END $$;
