-- ============================================================================
-- Migration 097: 修復 deprecated fields trigger（移除 INSERT 觸發）
--
-- 問題：
-- - 095 將 tr_prevent_deprecated_renewal_fields 改為 BEFORE INSERT OR UPDATE
-- - 但 renewal_status 有預設值 'none'，導致所有 INSERT 都被阻擋
--
-- 修復：
-- - 恢復為只在 UPDATE 時觸發
-- - INSERT 操作應該允許使用預設值
--
-- Date: 2026-01-01
-- ============================================================================

DROP TRIGGER IF EXISTS tr_prevent_deprecated_renewal_fields ON contracts;

CREATE TRIGGER tr_prevent_deprecated_renewal_fields
BEFORE UPDATE ON contracts  -- ★ 修復：移除 INSERT，只保留 UPDATE
FOR EACH ROW
EXECUTE FUNCTION prevent_deprecated_renewal_fields();

COMMENT ON TRIGGER tr_prevent_deprecated_renewal_fields ON contracts IS
    '阻止更新已棄用的 renewal_* 欄位（不影響 INSERT）';

-- ============================================================================
-- 驗證
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 097 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '✅ tr_prevent_deprecated_renewal_fields 已修復為只在 UPDATE 時觸發';
    RAISE NOTICE '✅ INSERT 操作現在可以正常使用（允許 renewal_status 預設值）';
    RAISE NOTICE '';
END $$;
