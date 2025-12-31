-- 091_integrity_guardrails.sql
-- 資料完整性護欄和告警機制
--
-- 包含：
-- 1. 禁止寫入已棄用欄位的 trigger
-- 2. 每日檢查函數
-- 3. 告警記錄表
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 告警記錄表
-- ============================================================================

CREATE TABLE IF NOT EXISTS data_integrity_alerts (
    id SERIAL PRIMARY KEY,
    issue_key VARCHAR(50) NOT NULL,
    severity VARCHAR(10) NOT NULL,  -- high, medium, low
    entity_type VARCHAR(30) NOT NULL,
    entity_id TEXT NOT NULL,
    contract_number VARCHAR(20),
    details JSONB,
    detected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolved_by TEXT,
    notes TEXT
);

CREATE INDEX IF NOT EXISTS idx_integrity_alerts_unresolved
ON data_integrity_alerts(detected_at DESC)
WHERE resolved_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_integrity_alerts_severity
ON data_integrity_alerts(severity, detected_at DESC)
WHERE resolved_at IS NULL;

COMMENT ON TABLE data_integrity_alerts IS '資料完整性告警記錄';
GRANT SELECT, INSERT, UPDATE ON data_integrity_alerts TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE data_integrity_alerts_id_seq TO anon, authenticated;

-- ============================================================================
-- 2. 禁止寫入已棄用欄位的 Trigger
-- ============================================================================

CREATE OR REPLACE FUNCTION prevent_deprecated_renewal_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- 檢查是否嘗試寫入已棄用欄位
    IF NEW.renewal_status IS NOT NULL OR
       NEW.renewal_paid_at IS NOT NULL OR
       NEW.renewal_invoiced_at IS NOT NULL OR
       NEW.renewal_signed_at IS NOT NULL THEN

        -- 如果是從 NULL 改為有值，阻擋
        IF (OLD.renewal_status IS NULL AND NEW.renewal_status IS NOT NULL) OR
           (OLD.renewal_paid_at IS NULL AND NEW.renewal_paid_at IS NOT NULL) OR
           (OLD.renewal_invoiced_at IS NULL AND NEW.renewal_invoiced_at IS NOT NULL) OR
           (OLD.renewal_signed_at IS NULL AND NEW.renewal_signed_at IS NOT NULL) THEN

            RAISE EXCEPTION '禁止寫入已棄用欄位 (renewal_status, renewal_*_at)。請使用 renewal_create_draft / renewal_activate 等 V3 工具。';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_prevent_deprecated_renewal_fields ON contracts;

CREATE TRIGGER tr_prevent_deprecated_renewal_fields
BEFORE UPDATE ON contracts
FOR EACH ROW
EXECUTE FUNCTION prevent_deprecated_renewal_fields();

COMMENT ON FUNCTION prevent_deprecated_renewal_fields IS '阻止寫入已棄用的 renewal_* 欄位';

-- ============================================================================
-- 3. 每日檢查函數
-- ============================================================================

CREATE OR REPLACE FUNCTION run_daily_integrity_check()
RETURNS TABLE (
    new_alerts INT,
    high_count INT,
    medium_count INT,
    low_count INT
) AS $$
DECLARE
    inserted_count INT := 0;
    v_high INT := 0;
    v_medium INT := 0;
    v_low INT := 0;
BEGIN
    -- 插入新發現的問題（排除已存在且未解決的）
    WITH new_issues AS (
        INSERT INTO data_integrity_alerts (
            issue_key, severity, entity_type, entity_id, contract_number, details, detected_at
        )
        SELECT
            dic.issue_key,
            dic.severity,
            dic.entity_type,
            dic.entity_id,
            dic.contract_number,
            dic.details,
            NOW()
        FROM data_integrity_check dic
        WHERE NOT EXISTS (
            SELECT 1 FROM data_integrity_alerts dia
            WHERE dia.issue_key = dic.issue_key
              AND dia.entity_id = dic.entity_id
              AND dia.resolved_at IS NULL
        )
        RETURNING severity
    )
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE severity = 'high'),
        COUNT(*) FILTER (WHERE severity = 'medium'),
        COUNT(*) FILTER (WHERE severity = 'low')
    INTO inserted_count, v_high, v_medium, v_low
    FROM new_issues;

    -- 自動解決已不存在的問題
    UPDATE data_integrity_alerts dia
    SET resolved_at = NOW(),
        resolved_by = 'system_auto'
    WHERE dia.resolved_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM data_integrity_check dic
        WHERE dic.issue_key = dia.issue_key
          AND dic.entity_id = dia.entity_id
      );

    RETURN QUERY SELECT inserted_count, v_high, v_medium, v_low;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION run_daily_integrity_check IS '每日執行資料完整性檢查，記錄新問題並自動解決已修復的問題';

-- ============================================================================
-- 4. 告警統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_integrity_alerts_summary CASCADE;

CREATE VIEW v_integrity_alerts_summary AS
SELECT
    severity,
    issue_key,
    COUNT(*) AS open_count,
    MIN(detected_at) AS oldest_detected,
    MAX(detected_at) AS newest_detected
FROM data_integrity_alerts
WHERE resolved_at IS NULL
GROUP BY severity, issue_key
ORDER BY
    CASE severity
        WHEN 'high' THEN 1
        WHEN 'medium' THEN 2
        WHEN 'low' THEN 3
    END,
    open_count DESC;

COMMENT ON VIEW v_integrity_alerts_summary IS '未解決的資料完整性告警摘要';
GRANT SELECT ON v_integrity_alerts_summary TO anon, authenticated;

-- ============================================================================
-- 5. 執行首次檢查
-- ============================================================================

SELECT * FROM run_daily_integrity_check();

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
DECLARE
    alert_count INT;
BEGIN
    SELECT COUNT(*) INTO alert_count
    FROM data_integrity_alerts
    WHERE resolved_at IS NULL;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 091 完成 ===';
    RAISE NOTICE '✅ data_integrity_alerts 表已建立';
    RAISE NOTICE '✅ tr_prevent_deprecated_renewal_fields trigger 已建立';
    RAISE NOTICE '✅ run_daily_integrity_check() 函數已建立';
    RAISE NOTICE '✅ v_integrity_alerts_summary 視圖已建立';
    RAISE NOTICE '';
    RAISE NOTICE '目前未解決的告警數: %', alert_count;
    RAISE NOTICE '';
    RAISE NOTICE '使用方式：';
    RAISE NOTICE '- 手動執行檢查：SELECT * FROM run_daily_integrity_check()';
    RAISE NOTICE '- 查看告警摘要：SELECT * FROM v_integrity_alerts_summary';
    RAISE NOTICE '- 解決告警：UPDATE data_integrity_alerts SET resolved_at=NOW(), resolved_by=''user'' WHERE id=X';
END $$;
