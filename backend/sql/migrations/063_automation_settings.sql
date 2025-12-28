-- 063_automation_settings.sql
-- 自動化設定（催簽、催繳、自動開票等）
-- Date: 2025-12-28

-- ============================================================================
-- 1. 更新系統設定
-- ============================================================================

-- 更新 renewal 設定，加入催簽相關參數
UPDATE system_settings
SET value = value || '{
    "sign_reminder_days": 7,
    "sign_reminder_throttle_days": 3,
    "auto_sign_reminder": false
}'::jsonb
WHERE key = 'renewal';

-- 更新 payment 設定，加入催繳相關參數
UPDATE system_settings
SET value = value || '{
    "payment_reminder_throttle_days": 7,
    "auto_payment_reminder": false,
    "overdue_reminder_days": [1, 7, 14, 30]
}'::jsonb
WHERE key = 'payment';

-- 更新 invoice 設定，加入自動開票參數
UPDATE system_settings
SET value = value || '{
    "auto_invoice_after_payment": false,
    "invoice_delay_days": 0
}'::jsonb
WHERE key = 'invoice';

-- ============================================================================
-- 2. 新增 automation 分類設定
-- ============================================================================

INSERT INTO system_settings (key, value, description, category)
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
    }'::jsonb,
    '自動化設定（催簽、催繳、自動開票、優先級升級）',
    'automation'
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
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
