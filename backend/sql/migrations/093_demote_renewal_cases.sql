-- 093_demote_renewal_cases.sql
-- 降級 renewal_cases 為歷史表
--
-- 原因：
-- V2 續約流程已移除，renewal_cases 表不再寫入新資料
-- 保留為歷史記錄，供查詢用
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 更新表註釋
-- ============================================================================

COMMENT ON TABLE renewal_cases IS '[歷史表 - 唯讀] 續約案件記錄。V2 續約流程已於 2025-12-31 移除，改用 V3 架構（intent_tools + renewal_tools_v3）。此表不再寫入新資料，保留供歷史查詢。';

-- ============================================================================
-- 2. 移除寫入權限（保留讀取）
-- ============================================================================

-- 撤銷 INSERT/UPDATE/DELETE
REVOKE INSERT, UPDATE, DELETE ON renewal_cases FROM anon;
REVOKE INSERT, UPDATE, DELETE ON renewal_cases FROM authenticated;

-- 保留 SELECT
GRANT SELECT ON renewal_cases TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    case_count INT;
    completed_count INT;
BEGIN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'completed')
    INTO case_count, completed_count
    FROM renewal_cases;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 093 完成 ===';
    RAISE NOTICE '✅ renewal_cases 已降級為歷史表';
    RAISE NOTICE '';
    RAISE NOTICE '歷史資料統計：';
    RAISE NOTICE '- 總案件數: %', case_count;
    RAISE NOTICE '- 已完成: %', completed_count;
    RAISE NOTICE '';
    RAISE NOTICE '權限變更：';
    RAISE NOTICE '- SELECT: 保留';
    RAISE NOTICE '- INSERT/UPDATE/DELETE: 已撤銷';
END $$;
