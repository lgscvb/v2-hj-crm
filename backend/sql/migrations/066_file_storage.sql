-- 066_file_storage.sql
-- 文件存儲與存取記錄
-- Date: 2025-12-29
--
-- 用途：
-- - 記錄所有文件的存取歷史（上傳/下載/刪除）
-- - 支援 Cloudflare R2 文件存儲
-- - 合約 PDF、報價單等文件的審計追蹤

-- ============================================================================
-- 1. 文件存取記錄表
-- ============================================================================

CREATE TABLE IF NOT EXISTS file_access_logs (
    id SERIAL PRIMARY KEY,

    -- 文件資訊
    file_path VARCHAR(500) NOT NULL,           -- R2 上的路徑，如 contracts/123/contract.pdf
    file_name VARCHAR(255),                     -- 原始文件名
    file_type VARCHAR(50),                      -- 文件類型：contract_pdf, quote, invoice, attachment
    file_size BIGINT,                           -- 文件大小（bytes）
    content_type VARCHAR(100),                  -- MIME 類型

    -- 關聯實體
    entity_type VARCHAR(50),                    -- 關聯類型：contract, quote, customer
    entity_id INT,                              -- 關聯 ID

    -- 操作資訊
    action VARCHAR(20) NOT NULL,                -- 操作類型：upload, download, delete, view

    -- 操作者資訊
    user_id INT,                                -- 用戶 ID（如有）
    user_name VARCHAR(100),                     -- 用戶名稱
    user_type VARCHAR(20) DEFAULT 'staff',      -- 用戶類型：staff, customer, system

    -- 存取來源
    ip_address VARCHAR(45),                     -- IP 位址（支援 IPv6）
    user_agent TEXT,                            -- 瀏覽器資訊

    -- 額外資訊
    metadata JSONB DEFAULT '{}',                -- 額外資訊（如：簽名 URL 過期時間）

    -- 時間戳
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_file_logs_entity ON file_access_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_file_logs_file_path ON file_access_logs(file_path);
CREATE INDEX IF NOT EXISTS idx_file_logs_action ON file_access_logs(action);
CREATE INDEX IF NOT EXISTS idx_file_logs_created ON file_access_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_file_logs_user ON file_access_logs(user_id);

COMMENT ON TABLE file_access_logs IS '文件存取記錄（審計追蹤）';

-- ============================================================================
-- 2. 文件索引表（可選，用於快速查詢文件）
-- ============================================================================

CREATE TABLE IF NOT EXISTS files (
    id SERIAL PRIMARY KEY,

    -- 文件資訊
    file_path VARCHAR(500) NOT NULL UNIQUE,     -- R2 上的完整路徑
    file_name VARCHAR(255) NOT NULL,            -- 原始文件名
    file_type VARCHAR(50) NOT NULL,             -- 文件類型
    file_size BIGINT,                           -- 文件大小（bytes）
    content_type VARCHAR(100),                  -- MIME 類型

    -- 關聯實體
    entity_type VARCHAR(50),                    -- 關聯類型
    entity_id INT,                              -- 關聯 ID

    -- 存儲資訊
    storage_provider VARCHAR(20) DEFAULT 'r2',  -- 存儲提供者：r2, gcs, local
    public_url VARCHAR(500),                    -- 公開 URL（如有）

    -- 狀態
    status VARCHAR(20) DEFAULT 'active',        -- 狀態：active, deleted, archived

    -- 上傳者
    uploaded_by_id INT,
    uploaded_by_name VARCHAR(100),

    -- 時間戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ                      -- 軟刪除
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_files_entity ON files(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_files_type ON files(file_type);
CREATE INDEX IF NOT EXISTS idx_files_status ON files(status);

COMMENT ON TABLE files IS '文件索引表';

-- ============================================================================
-- 3. 授權
-- ============================================================================

GRANT SELECT, INSERT ON file_access_logs TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON files TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE file_access_logs_id_seq TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE files_id_seq TO anon, authenticated;

-- ============================================================================
-- 4. 文件統計視圖
-- ============================================================================

CREATE OR REPLACE VIEW v_file_stats AS
SELECT
    entity_type,
    entity_id,
    COUNT(*) AS file_count,
    SUM(file_size) AS total_size,
    MAX(created_at) AS last_upload_at,
    array_agg(DISTINCT file_type) AS file_types
FROM files
WHERE status = 'active'
GROUP BY entity_type, entity_id;

COMMENT ON VIEW v_file_stats IS '文件統計視圖';

GRANT SELECT ON v_file_stats TO anon, authenticated;

-- ============================================================================
-- 5. 最近存取記錄視圖
-- ============================================================================

CREATE OR REPLACE VIEW v_recent_file_access AS
SELECT
    fal.id,
    fal.file_path,
    fal.file_name,
    fal.file_type,
    fal.entity_type,
    fal.entity_id,
    fal.action,
    fal.user_name,
    fal.user_type,
    fal.ip_address,
    fal.created_at,
    -- 關聯資訊
    CASE
        WHEN fal.entity_type = 'contract' THEN c.contract_number
        ELSE NULL
    END AS contract_number,
    CASE
        WHEN fal.entity_type = 'contract' THEN c.company_name
        ELSE NULL
    END AS company_name
FROM file_access_logs fal
LEFT JOIN contracts c ON fal.entity_type = 'contract' AND fal.entity_id = c.id
ORDER BY fal.created_at DESC;

COMMENT ON VIEW v_recent_file_access IS '最近文件存取記錄';

GRANT SELECT ON v_recent_file_access TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 066 完成 ===';
    RAISE NOTICE '✅ file_access_logs 表已建立';
    RAISE NOTICE '✅ files 表已建立';
    RAISE NOTICE '✅ v_file_stats 視圖已建立';
    RAISE NOTICE '✅ v_recent_file_access 視圖已建立';
END $$;
