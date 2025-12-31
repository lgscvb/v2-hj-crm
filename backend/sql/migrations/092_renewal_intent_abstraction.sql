-- 092_renewal_intent_abstraction.sql
-- 續約意願線抽象層
--
-- 目的：
-- 1. 建立 v_renewal_intent View，包裝 contracts 表的意願欄位
-- 2. 為未來可能的 renewal_intent 獨立表預留空間
-- 3. 前端/流程看板統一從 View 讀取，不直接讀 contracts
--
-- 意願線 vs 交易線：
-- - 意願線：renewal_notified_at, renewal_confirmed_at（本 View 管理）
-- - 交易線：payment/invoice/signing 狀態（由 SSOT v_contract_workspace 管理）
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 續約意願視圖
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_intent CASCADE;

CREATE VIEW v_renewal_intent AS
SELECT
    c.id AS contract_id,
    c.contract_number,
    c.customer_id,
    cu.name AS customer_name,

    -- 意願 flag（布林）
    (c.renewal_notified_at IS NOT NULL) AS is_notified,
    (c.renewal_confirmed_at IS NOT NULL) AS is_confirmed,

    -- 意願時間戳（詳細資訊）
    c.renewal_notified_at,
    c.renewal_confirmed_at,

    -- 備註
    c.renewal_notes,

    -- 合約基本資訊（方便 join）
    c.status AS contract_status,
    c.start_date,
    c.end_date,
    (c.end_date - CURRENT_DATE) AS days_until_expiry,

    -- 是否為需要續約處理的合約
    CASE
        WHEN c.status IN ('active', 'pending_termination')
             AND c.end_date >= CURRENT_DATE - INTERVAL '30 days'
        THEN TRUE
        ELSE FALSE
    END AS is_renewable,

    -- 更新時間
    c.updated_at

FROM contracts c
LEFT JOIN customers cu ON cu.id = c.customer_id;

COMMENT ON VIEW v_renewal_intent IS '續約意願線視圖 - 包裝 contracts 表的 renewal_notified_at, renewal_confirmed_at 欄位';
COMMENT ON COLUMN v_renewal_intent.is_notified IS '是否已發送續約通知';
COMMENT ON COLUMN v_renewal_intent.is_confirmed IS '是否已確認續約意願';
COMMENT ON COLUMN v_renewal_intent.is_renewable IS '是否為可處理續約的合約（active/pending_termination 且未過期超過 30 天）';

GRANT SELECT ON v_renewal_intent TO anon, authenticated;

-- ============================================================================
-- 2. 意願記錄歷史表（可選，未來擴展用）
-- ============================================================================

-- 如果未來需要追蹤意願變更歷史，可啟用此表
-- CREATE TABLE IF NOT EXISTS renewal_intent_logs (
--     id SERIAL PRIMARY KEY,
--     contract_id INT NOT NULL REFERENCES contracts(id),
--     action VARCHAR(20) NOT NULL,  -- 'notify', 'confirm', 'clear_notify', 'clear_confirm'
--     performed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
--     performed_by TEXT,
--     notes TEXT
-- );

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    view_count INT;
    notified_count INT;
    confirmed_count INT;
BEGIN
    -- 確認 View 可查詢
    SELECT COUNT(*) INTO view_count FROM v_renewal_intent;

    -- 統計現有意願狀態
    SELECT
        COUNT(*) FILTER (WHERE is_notified),
        COUNT(*) FILTER (WHERE is_confirmed)
    INTO notified_count, confirmed_count
    FROM v_renewal_intent
    WHERE is_renewable;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 092 完成 ===';
    RAISE NOTICE '✅ v_renewal_intent 視圖已建立';
    RAISE NOTICE '';
    RAISE NOTICE '可續約合約統計：';
    RAISE NOTICE '- 已通知: %', notified_count;
    RAISE NOTICE '- 已確認: %', confirmed_count;
    RAISE NOTICE '';
    RAISE NOTICE '使用方式：';
    RAISE NOTICE '- 讀取意願：SELECT * FROM v_renewal_intent WHERE contract_id = X';
    RAISE NOTICE '- 設定意願：使用 set_renewal_intent Tool（不要直接 UPDATE contracts）';
END $$;
