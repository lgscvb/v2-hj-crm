-- ============================================================================
-- Migration 046: 會議室預約防重疊約束
--
-- 問題：競態條件 - 兩個使用者可同時預約同一時段
-- 解法：使用 PostgreSQL Exclusion Constraint 在資料庫層級防止重疊
--
-- 技術說明：
-- - 使用 btree_gist 擴展支援時間範圍排除
-- - Exclusion Constraint 比應用層檢查更可靠（原子性保證）
-- ============================================================================

-- 1. 啟用 btree_gist 擴展（用於 Exclusion Constraint）
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 2. 建立防止時段重疊的約束
-- 只對 status = 'confirmed' 的預約生效（已取消/已完成的不影響）
ALTER TABLE meeting_room_bookings
ADD CONSTRAINT no_overlapping_bookings
EXCLUDE USING gist (
    meeting_room_id WITH =,
    booking_date WITH =,
    tsrange(
        booking_date + start_time,
        booking_date + end_time
    ) WITH &&
) WHERE (status = 'confirmed');

-- 3. 建立索引加速時段查詢
CREATE INDEX IF NOT EXISTS idx_bookings_room_date_time
ON meeting_room_bookings (meeting_room_id, booking_date, start_time, end_time)
WHERE status = 'confirmed';

-- 4. 新增 google_sync_status 欄位追蹤同步狀態
ALTER TABLE meeting_room_bookings
ADD COLUMN IF NOT EXISTS google_sync_status VARCHAR(20) DEFAULT 'pending';

COMMENT ON COLUMN meeting_room_bookings.google_sync_status IS
'Google Calendar 同步狀態: pending(待同步), synced(已同步), failed(同步失敗), not_required(不需同步)';

-- 5. 新增 sync_error_message 欄位記錄錯誤
ALTER TABLE meeting_room_bookings
ADD COLUMN IF NOT EXISTS sync_error_message TEXT;

-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 046 completed: Added booking overlap constraint and sync tracking' AS status;
