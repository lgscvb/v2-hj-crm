-- 063_automation_settings.sql
-- 自動化設定（催簽、催繳、自動開票等）
-- Date: 2025-12-28
--
-- 注意：system_settings 表結構：
--   setting_key (varchar), setting_value (text), setting_type (varchar), description (text)

-- ============================================================================
-- 1. 新增 automation 設定
-- ============================================================================

INSERT INTO system_settings (setting_key, setting_value, setting_type, description)
VALUES (
    'automation',
    '{
        "enabled": false,
        "sign_reminder": {
            "enabled": false,
            "trigger_days": 7,
            "throttle_days": 3,
            "max_reminders": 3
        },
        "payment_reminder": {
            "enabled": false,
            "trigger_days": [1, 7, 14, 30],
            "throttle_days": 7,
            "max_reminders": 5
        },
        "auto_invoice": {
            "enabled": false,
            "delay_minutes": 0,
            "require_tax_id": false
        },
        "priority_escalation": {
            "enabled": false,
            "medium_to_high_days": 7,
            "high_to_urgent_days": 14
        }
    }',
    'json',
    '自動化設定（催簽、催繳、自動開票、優先級升級）'
)
ON CONFLICT (setting_key) DO UPDATE
SET setting_value = EXCLUDED.setting_value,
    description = EXCLUDED.description,
    updated_at = NOW();

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 063 完成 ===';
    RAISE NOTICE '新增 automation 設定項目：';
    RAISE NOTICE '- sign_reminder: 催簽設定';
    RAISE NOTICE '- payment_reminder: 催繳設定';
    RAISE NOTICE '- auto_invoice: 自動開票設定';
    RAISE NOTICE '- priority_escalation: 優先級升級設定';
END $$;
