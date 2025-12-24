-- Migration: 034_ai_learning
-- Description: AI 學習功能相關資料表（對話記錄、回饋、修正、訓練匯出）
-- Date: 2025-12-24

-- ============================================================================
-- 1. AI 對話記錄表 (ai_conversations)
-- 記錄每次 AI Chat 對話的完整上下文
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_conversations (
    id BIGSERIAL PRIMARY KEY,

    -- 對話識別
    session_id UUID DEFAULT gen_random_uuid(),  -- 對話 Session（同一次對話）

    -- 操作者資訊
    operator_name VARCHAR(100),                 -- 操作者姓名（可選）
    operator_email VARCHAR(200),                -- 操作者 Email（可選）

    -- 關聯的業務實體（可選）
    related_customer_id INTEGER REFERENCES customers(id) ON DELETE SET NULL,
    related_contract_id INTEGER REFERENCES contracts(id) ON DELETE SET NULL,
    related_payment_id INTEGER REFERENCES payments(id) ON DELETE SET NULL,

    -- 模型資訊
    model_used VARCHAR(100) NOT NULL,           -- 使用的模型 (claude-sonnet-4 等)

    -- 對話內容
    user_message TEXT NOT NULL,                 -- 用戶輸入
    assistant_message TEXT,                     -- AI 回覆
    tool_calls JSONB DEFAULT '[]',              -- 執行的工具列表

    -- RAG 資訊
    rag_context TEXT,                           -- RAG 搜尋到的知識
    rag_relevance_score NUMERIC(3,2),           -- RAG 相關性分數

    -- Token 統計
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,

    -- 狀態
    status VARCHAR(20) DEFAULT 'completed'
        CHECK (status IN ('pending', 'streaming', 'completed', 'error', 'cancelled')),
    error_message TEXT,

    -- 時間戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_ai_conv_session ON ai_conversations(session_id);
CREATE INDEX IF NOT EXISTS idx_ai_conv_operator ON ai_conversations(operator_email);
CREATE INDEX IF NOT EXISTS idx_ai_conv_customer ON ai_conversations(related_customer_id);
CREATE INDEX IF NOT EXISTS idx_ai_conv_created ON ai_conversations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_conv_model ON ai_conversations(model_used);
CREATE INDEX IF NOT EXISTS idx_ai_conv_status ON ai_conversations(status);

COMMENT ON TABLE ai_conversations IS 'AI 對話記錄';
COMMENT ON COLUMN ai_conversations.session_id IS '對話 Session UUID，同一對話串共用';
COMMENT ON COLUMN ai_conversations.tool_calls IS '執行的 MCP 工具列表 [{name, arguments, result}]';

-- ============================================================================
-- 2. AI 回覆回饋表 (ai_feedback)
-- 收集操作者對 AI 回覆的評價
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_feedback (
    id SERIAL PRIMARY KEY,

    -- 關聯對話
    conversation_id BIGINT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,

    -- 快速回饋
    is_good BOOLEAN,                            -- 👍 true / 👎 false

    -- 詳細評分 (1-5 星)
    rating INTEGER CHECK (rating >= 1 AND rating <= 5),

    -- 回饋原因/說明
    feedback_reason TEXT,                       -- 為什麼好/不好

    -- 改進標籤（多選）
    improvement_tags TEXT[] DEFAULT '{}',
    -- 可選標籤：
    -- 'tone_too_formal'     語氣太正式
    -- 'tone_too_casual'     語氣太隨便
    -- 'too_long'            回覆太長
    -- 'too_short'           回覆太短
    -- 'missing_info'        缺少資訊
    -- 'wrong_info'          資訊錯誤
    -- 'wrong_tool'          呼叫錯誤工具
    -- 'slow_response'       回應太慢
    -- 'not_helpful'         沒有幫助
    -- 'perfect'             完美
    -- 'other'               其他

    -- 操作者資訊
    submitted_by VARCHAR(100),

    -- 時間戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_ai_fb_conv ON ai_feedback(conversation_id);
CREATE INDEX IF NOT EXISTS idx_ai_fb_is_good ON ai_feedback(is_good);
CREATE INDEX IF NOT EXISTS idx_ai_fb_rating ON ai_feedback(rating);
CREATE INDEX IF NOT EXISTS idx_ai_fb_created ON ai_feedback(created_at DESC);

-- 唯一約束：每個對話只能有一個回饋
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_fb_conv_unique ON ai_feedback(conversation_id);

COMMENT ON TABLE ai_feedback IS 'AI 回覆回饋（👍/👎 + 評分）';
COMMENT ON COLUMN ai_feedback.improvement_tags IS '改進標籤陣列';

-- ============================================================================
-- 3. AI 回覆修正表 (ai_refinements)
-- 記錄多輪修正對話
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_refinements (
    id SERIAL PRIMARY KEY,

    -- 關聯對話
    conversation_id BIGINT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,

    -- 修正輪次
    round_number INTEGER NOT NULL DEFAULT 1,

    -- 修正內容
    instruction TEXT NOT NULL,                  -- 修正指令（如「語氣更親切」）
    original_content TEXT NOT NULL,             -- 修正前的內容
    refined_content TEXT,                       -- 修正後的內容

    -- AI 分析
    operator_intent VARCHAR(50),                -- refinement/decision/emotion/discussion/question
    modification_types TEXT[] DEFAULT '{}',     -- 修改類型（tone/accuracy/length 等）

    -- 知識偵測
    knowledge_detected BOOLEAN DEFAULT FALSE,
    knowledge_items JSONB DEFAULT '[]',         -- [{content, category, reason}]

    -- 模型資訊
    model_used VARCHAR(100),
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,

    -- 狀態
    is_accepted BOOLEAN,                        -- 用戶是否接受這個修正

    -- 時間戳
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_ai_ref_conv ON ai_refinements(conversation_id);
CREATE INDEX IF NOT EXISTS idx_ai_ref_round ON ai_refinements(conversation_id, round_number);
CREATE INDEX IF NOT EXISTS idx_ai_ref_accepted ON ai_refinements(is_accepted);
CREATE INDEX IF NOT EXISTS idx_ai_ref_knowledge ON ai_refinements(knowledge_detected) WHERE knowledge_detected = TRUE;

COMMENT ON TABLE ai_refinements IS 'AI 回覆多輪修正記錄';
COMMENT ON COLUMN ai_refinements.operator_intent IS '操作者意圖：refinement=修正, decision=決策, emotion=情緒, discussion=討論, question=提問';
COMMENT ON COLUMN ai_refinements.knowledge_items IS '偵測到的知識點 [{content, category, reason}]';

-- ============================================================================
-- 4. 訓練資料匯出歷史表 (ai_training_exports)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_training_exports (
    id SERIAL PRIMARY KEY,

    -- 匯出資訊
    export_type VARCHAR(20) NOT NULL            -- sft/rlhf/dpo
        CHECK (export_type IN ('sft', 'rlhf', 'dpo', 'preference', 'custom')),
    record_count INTEGER NOT NULL DEFAULT 0,

    -- 篩選條件
    filters JSONB DEFAULT '{}',                 -- 匯出時使用的篩選條件

    -- 匯出結果
    file_size_bytes BIGINT,
    export_url TEXT,                            -- GCS 或其他存儲位置（大檔案）

    -- 時間戳
    exported_by VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_export_type ON ai_training_exports(export_type);
CREATE INDEX IF NOT EXISTS idx_ai_export_created ON ai_training_exports(created_at DESC);

COMMENT ON TABLE ai_training_exports IS '訓練資料匯出歷史';

-- ============================================================================
-- 5. 學習模式表 (ai_learning_patterns)
-- 追蹤常見的修正模式，用於動態調整 prompt
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_learning_patterns (
    id SERIAL PRIMARY KEY,

    -- 模式識別
    pattern_type VARCHAR(50) NOT NULL,          -- 如 tone_adjustment, add_emoji 等
    pattern_description TEXT,                   -- 模式描述

    -- 統計
    occurrence_count INTEGER DEFAULT 1,         -- 出現次數
    success_rate NUMERIC(5,2),                  -- 成功率（修正被接受的比例）

    -- 建議的 prompt 調整
    suggested_prompt_addition TEXT,

    -- 範例
    example_instruction TEXT,                   -- 典型的修正指令
    example_before TEXT,                        -- 修正前範例
    example_after TEXT,                         -- 修正後範例

    -- 狀態
    is_active BOOLEAN DEFAULT TRUE,             -- 是否啟用

    -- 時間戳
    first_seen_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_lp_type ON ai_learning_patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_ai_lp_active ON ai_learning_patterns(is_active) WHERE is_active = TRUE;

COMMENT ON TABLE ai_learning_patterns IS '學習模式追蹤（用於動態 prompt 調整）';

-- ============================================================================
-- 6. 視圖：回饋統計
-- ============================================================================

CREATE OR REPLACE VIEW v_ai_feedback_stats AS
SELECT
    DATE_TRUNC('day', ai_feedback.created_at)::DATE as date,
    COUNT(*) as total_feedbacks,
    COUNT(*) FILTER (WHERE is_good = TRUE) as positive_count,
    COUNT(*) FILTER (WHERE is_good = FALSE) as negative_count,
    ROUND(
        COUNT(*) FILTER (WHERE is_good = TRUE)::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    ) as positive_rate,
    ROUND(AVG(rating), 2) as avg_rating,
    COUNT(*) FILTER (WHERE rating >= 4) as high_rating_count,
    COUNT(*) FILTER (WHERE rating <= 2) as low_rating_count
FROM ai_feedback
GROUP BY DATE_TRUNC('day', ai_feedback.created_at)
ORDER BY date DESC;

COMMENT ON VIEW v_ai_feedback_stats IS 'AI 回饋每日統計';

-- ============================================================================
-- 7. 視圖：對話統計
-- ============================================================================

CREATE OR REPLACE VIEW v_ai_conversation_stats AS
SELECT
    DATE_TRUNC('day', created_at)::DATE as date,
    model_used,
    COUNT(*) as conversation_count,
    SUM(input_tokens) as total_input_tokens,
    SUM(output_tokens) as total_output_tokens,
    SUM(input_tokens + output_tokens) as total_tokens,
    COUNT(*) FILTER (WHERE status = 'error') as error_count,
    COUNT(*) FILTER (WHERE status = 'completed') as success_count,
    ROUND(AVG(output_tokens), 0) as avg_output_tokens
FROM ai_conversations
GROUP BY DATE_TRUNC('day', created_at), model_used
ORDER BY date DESC, model_used;

COMMENT ON VIEW v_ai_conversation_stats IS 'AI 對話每日統計（按模型分組）';

-- ============================================================================
-- 8. 視圖：可匯出的訓練資料統計
-- ============================================================================

CREATE OR REPLACE VIEW v_ai_training_ready AS
SELECT
    'sft' as export_type,
    COUNT(*) as available_records,
    '高評分對話（rating >= 4）' as description
FROM ai_conversations c
JOIN ai_feedback f ON c.id = f.conversation_id
WHERE f.rating >= 4 OR f.is_good = TRUE

UNION ALL

SELECT
    'rlhf' as export_type,
    COUNT(*) as available_records,
    '有修正且被接受的對話' as description
FROM ai_refinements
WHERE is_accepted = TRUE

UNION ALL

SELECT
    'dpo' as export_type,
    COUNT(*) as available_records,
    '有評分差異的修正對（rating >= 4 vs <= 2）' as description
FROM ai_conversations c
JOIN ai_feedback f ON c.id = f.conversation_id
WHERE f.rating IS NOT NULL;

COMMENT ON VIEW v_ai_training_ready IS '可匯出的訓練資料統計';

-- ============================================================================
-- 觸發器：自動更新 updated_at
-- ============================================================================

CREATE OR REPLACE FUNCTION update_ai_feedback_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_ai_feedback_timestamp ON ai_feedback;
CREATE TRIGGER trigger_update_ai_feedback_timestamp
    BEFORE UPDATE ON ai_feedback
    FOR EACH ROW
    EXECUTE FUNCTION update_ai_feedback_timestamp();

-- ============================================================================
-- 權限
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON ai_conversations TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON ai_feedback TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON ai_refinements TO anon, authenticated;
GRANT SELECT, INSERT ON ai_training_exports TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON ai_learning_patterns TO anon, authenticated;

GRANT SELECT ON v_ai_feedback_stats TO anon, authenticated;
GRANT SELECT ON v_ai_conversation_stats TO anon, authenticated;
GRANT SELECT ON v_ai_training_ready TO anon, authenticated;

GRANT USAGE, SELECT ON SEQUENCE ai_conversations_id_seq TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE ai_feedback_id_seq TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE ai_refinements_id_seq TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE ai_training_exports_id_seq TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE ai_learning_patterns_id_seq TO anon, authenticated;
