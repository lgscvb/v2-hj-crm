-- 088_fix_expired_contracts.sql
-- 修復過期合約狀態
--
-- 問題：
-- 6 筆合約 status='active' 但 end_date 已過
-- - DZ-058, DZ-111, DZ-195, DZ-063, DZ-196 無續約草稿，應標記 expired
-- - DZ-112 有續約草稿，保留 active（等待續約流程完成）
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 先查看狀態（確認）
-- ============================================================================

DO $$
DECLARE
    rec RECORD;
BEGIN
    RAISE NOTICE '=== 修復前狀態 ===';
    FOR rec IN
        SELECT c.id, c.contract_number, c.status, c.end_date,
               nc.id AS draft_id, nc.status AS draft_status
        FROM contracts c
        LEFT JOIN contracts nc ON nc.renewed_from_id = c.id
            AND nc.status IN ('draft', 'pending_sign')
        WHERE c.status = 'active'
          AND c.end_date < CURRENT_DATE
        ORDER BY c.contract_number
    LOOP
        RAISE NOTICE '% | status=% | end_date=% | draft=%',
            rec.contract_number, rec.status, rec.end_date,
            COALESCE(rec.draft_status, '無');
    END LOOP;
END $$;

-- ============================================================================
-- 2. 暫時停用保護 trigger，更新過期合約
-- ============================================================================

-- 停用 trigger（資料修復專用）
ALTER TABLE contracts DISABLE TRIGGER protect_contract_critical_fields_trigger;

UPDATE contracts c
SET status = 'expired',
    updated_at = NOW()
WHERE c.status = 'active'
  AND c.end_date < CURRENT_DATE
  AND NOT EXISTS (
    SELECT 1
    FROM contracts nc
    WHERE nc.renewed_from_id = c.id
      AND nc.status IN ('draft', 'pending_sign')
  );

-- 重新啟用 trigger
ALTER TABLE contracts ENABLE TRIGGER protect_contract_critical_fields_trigger;

-- ============================================================================
-- 3. 驗證結果
-- ============================================================================

DO $$
DECLARE
    rec RECORD;
    affected_count INT;
BEGIN
    -- 統計更新數量
    SELECT COUNT(*) INTO affected_count
    FROM contracts
    WHERE status = 'expired'
      AND updated_at > NOW() - INTERVAL '1 minute';

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 088 完成 ===';
    RAISE NOTICE '✅ 已更新 % 筆合約為 expired', affected_count;

    -- 顯示仍為 active 但過期的（應該只剩有草稿的）
    RAISE NOTICE '';
    RAISE NOTICE '=== 仍為 active 的過期合約（有草稿）===';
    FOR rec IN
        SELECT c.id, c.contract_number, c.end_date,
               nc.contract_number AS draft_number, nc.status AS draft_status
        FROM contracts c
        JOIN contracts nc ON nc.renewed_from_id = c.id
            AND nc.status IN ('draft', 'pending_sign')
        WHERE c.status = 'active'
          AND c.end_date < CURRENT_DATE
        ORDER BY c.contract_number
    LOOP
        RAISE NOTICE '% | end=% | draft=% (%)',
            rec.contract_number, rec.end_date,
            rec.draft_number, rec.draft_status;
    END LOOP;
END $$;
