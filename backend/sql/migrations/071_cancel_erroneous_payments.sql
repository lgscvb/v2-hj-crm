-- 071_cancel_erroneous_payments.sql
-- 取消因期數計算錯誤產生的付款記錄
--
-- 背景：
-- Migration 069 修正了期數計算邏輯（CEIL → generate_series + 排除上界）
-- Migration 070 修正了付款生成邊界條件
-- 本 migration 清理已產生的錯誤資料
--
-- 受影響案例：
-- DZ-058 (contract_id=555)：
-- - 合約期間：2023-12-07 ~ 2025-12-07（半年繳）
-- - 正確期數：4 期（2023-12、2024-06、2024-12、2025-06）
-- - 錯誤：payment 373 (2025-12 期) 不應存在
--
-- Date: 2025-12-29

-- ============================================================================
-- 1. 識別受影響的付款（乾跑模式）
-- ============================================================================

DO $$
DECLARE
    v_count INT;
BEGIN
    -- 找出 due_date >= contract.end_date 的付款
    SELECT COUNT(*) INTO v_count
    FROM payments p
    JOIN contracts c ON p.contract_id = c.id
    WHERE p.payment_type = 'rent'
      AND p.payment_status NOT IN ('paid', 'cancelled', 'waived')
      AND c.end_date IS NOT NULL
      AND p.due_date >= c.end_date;

    RAISE NOTICE '找到 % 筆 due_date >= end_date 的待繳/逾期付款', v_count;
END $$;

-- 顯示受影響的付款明細
SELECT
    p.id AS payment_id,
    c.contract_number,
    cust.name AS customer_name,
    p.payment_period,
    p.due_date,
    c.end_date,
    p.amount,
    p.payment_status
FROM payments p
JOIN contracts c ON p.contract_id = c.id
LEFT JOIN customers cust ON c.customer_id = cust.id
WHERE p.payment_type = 'rent'
  AND p.payment_status NOT IN ('paid', 'cancelled', 'waived')
  AND c.end_date IS NOT NULL
  AND p.due_date >= c.end_date
ORDER BY p.id;

-- ============================================================================
-- 2. 取消錯誤付款
-- ============================================================================

UPDATE payments p
SET
    payment_status = 'cancelled',
    notes = COALESCE(notes, '') || E'\n[系統修正] ' || NOW()::DATE ||
            ' - 因期數計算邏輯錯誤取消（due_date >= contract.end_date）',
    updated_at = NOW()
FROM contracts c
WHERE p.contract_id = c.id
  AND p.payment_type = 'rent'
  AND p.payment_status NOT IN ('paid', 'cancelled', 'waived')
  AND c.end_date IS NOT NULL
  AND p.due_date >= c.end_date;

-- ============================================================================
-- 3. 驗證結果
-- ============================================================================

DO $$
DECLARE
    v_cancelled INT;
    v_remaining INT;
BEGIN
    -- 計算已取消的數量
    SELECT COUNT(*) INTO v_cancelled
    FROM payments
    WHERE notes LIKE '%期數計算邏輯錯誤取消%'
      AND updated_at >= CURRENT_DATE;

    -- 確認沒有遺漏
    SELECT COUNT(*) INTO v_remaining
    FROM payments p
    JOIN contracts c ON p.contract_id = c.id
    WHERE p.payment_type = 'rent'
      AND p.payment_status NOT IN ('paid', 'cancelled', 'waived')
      AND c.end_date IS NOT NULL
      AND p.due_date >= c.end_date;

    RAISE NOTICE '=== Migration 071 完成 ===';
    RAISE NOTICE '✅ 已取消 % 筆錯誤付款', v_cancelled;
    RAISE NOTICE '剩餘待處理: % 筆', v_remaining;
END $$;
