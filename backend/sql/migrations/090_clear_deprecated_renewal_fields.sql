-- 090_clear_deprecated_renewal_fields.sql
-- 清除已棄用的 renewal_* 欄位
--
-- 原因：
-- 這些欄位是舊流程殘留，與新架構（renewal_cases + renewed_from_id）不一致
-- 清除後統一使用新的 SSOT 架構
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 查看將被清除的資料
-- ============================================================================

DO $$
DECLARE
    rec RECORD;
BEGIN
    RAISE NOTICE '=== 將被清除的 renewal_* 欄位 ===';
    FOR rec IN
        SELECT contract_number, renewal_status, renewal_paid_at, renewal_signed_at
        FROM contracts
        WHERE (renewal_status IS NOT NULL AND renewal_status <> 'none')
           OR renewal_paid_at IS NOT NULL
           OR renewal_invoiced_at IS NOT NULL
           OR renewal_signed_at IS NOT NULL
        ORDER BY contract_number
    LOOP
        RAISE NOTICE '% | status=% | paid=% | signed=%',
            rec.contract_number,
            COALESCE(rec.renewal_status, '-'),
            COALESCE(rec.renewal_paid_at::TEXT, '-'),
            COALESCE(rec.renewal_signed_at::TEXT, '-');
    END LOOP;
END $$;

-- ============================================================================
-- 2. 清除 renewal_* 欄位
-- ============================================================================

UPDATE contracts
SET renewal_status = NULL,
    renewal_paid_at = NULL,
    renewal_invoiced_at = NULL,
    renewal_signed_at = NULL,
    updated_at = NOW()
WHERE (renewal_status IS NOT NULL AND renewal_status <> 'none')
   OR renewal_paid_at IS NOT NULL
   OR renewal_invoiced_at IS NOT NULL
   OR renewal_signed_at IS NOT NULL;

-- ============================================================================
-- 3. 同時清除 renewal_status = 'none'（預設值也清掉）
-- ============================================================================

UPDATE contracts
SET renewal_status = NULL,
    updated_at = NOW()
WHERE renewal_status = 'none';

-- ============================================================================
-- 4. 驗證
-- ============================================================================

DO $$
DECLARE
    remaining INT;
BEGIN
    SELECT COUNT(*) INTO remaining
    FROM contracts
    WHERE renewal_status IS NOT NULL
       OR renewal_paid_at IS NOT NULL
       OR renewal_invoiced_at IS NOT NULL
       OR renewal_signed_at IS NOT NULL;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 090 完成 ===';
    RAISE NOTICE '✅ 已清除所有 renewal_* 欄位';
    RAISE NOTICE '剩餘有值的合約數: %', remaining;

    IF remaining = 0 THEN
        RAISE NOTICE '✅ 所有 renewal_* 欄位已清空';
    ELSE
        RAISE NOTICE '⚠️ 仍有 % 筆合約有 renewal_* 值', remaining;
    END IF;
END $$;
