-- ============================================================================
-- 清理測試資料腳本
--
-- 刪除名稱包含「測試」「demo」「test」的客戶及其所有關聯資料
--
-- 使用前請先執行 DRY RUN 確認刪除範圍！
-- 日期：2026-01-02
-- ============================================================================

-- ============================================================================
-- 第一步：DRY RUN（只看不刪）
-- 執行這段來確認會刪除哪些資料
-- ============================================================================

DO $$
DECLARE
    v_customer_ids INT[];
    v_contract_ids INT[];
    v_payment_ids INT[];
    v_invoice_ids INT[];
    v_customer_count INT;
    v_contract_count INT;
    v_payment_count INT;
    v_invoice_count INT;
BEGIN
    -- 找出測試客戶
    SELECT ARRAY_AGG(id) INTO v_customer_ids
    FROM customers
    WHERE LOWER(company_name) LIKE '%test%'
       OR LOWER(company_name) LIKE '%demo%'
       OR company_name LIKE '%測試%'
       OR LOWER(name) LIKE '%test%'
       OR LOWER(name) LIKE '%demo%'
       OR name LIKE '%測試%';

    v_customer_count := COALESCE(array_length(v_customer_ids, 1), 0);

    IF v_customer_count = 0 THEN
        RAISE NOTICE '========================================';
        RAISE NOTICE '沒有找到測試客戶資料，無需清理';
        RAISE NOTICE '========================================';
        RETURN;
    END IF;

    -- 找出關聯合約
    SELECT ARRAY_AGG(id) INTO v_contract_ids
    FROM contracts
    WHERE customer_id = ANY(v_customer_ids);

    v_contract_count := COALESCE(array_length(v_contract_ids, 1), 0);

    -- 找出關聯付款
    SELECT ARRAY_AGG(id) INTO v_payment_ids
    FROM payments
    WHERE contract_id = ANY(v_contract_ids);

    v_payment_count := COALESCE(array_length(v_payment_ids, 1), 0);

    -- 找出關聯發票
    SELECT ARRAY_AGG(id) INTO v_invoice_ids
    FROM invoices
    WHERE payment_id = ANY(v_payment_ids);

    v_invoice_count := COALESCE(array_length(v_invoice_ids, 1), 0);

    -- 顯示統計
    RAISE NOTICE '========================================';
    RAISE NOTICE 'DRY RUN - 預計刪除的資料：';
    RAISE NOTICE '========================================';
    RAISE NOTICE '客戶數量: %', v_customer_count;
    RAISE NOTICE '合約數量: %', v_contract_count;
    RAISE NOTICE '付款數量: %', v_payment_count;
    RAISE NOTICE '發票數量: %', v_invoice_count;
    RAISE NOTICE '========================================';

    -- 列出客戶名稱
    RAISE NOTICE '';
    RAISE NOTICE '將刪除的客戶：';
    FOR i IN 1..v_customer_count LOOP
        PERFORM (
            SELECT RAISE(NOTICE, '  - ID: %, 公司: %, 姓名: %',
                c.id, COALESCE(c.company_name, '(無)'), COALESCE(c.name, '(無)'))
            FROM customers c
            WHERE c.id = v_customer_ids[i]
        );
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '如果確認要刪除，請執行下方的 ACTUAL DELETE 區塊';
    RAISE NOTICE '========================================';
END;
$$;


-- ============================================================================
-- 第二步：顯示詳細客戶清單
-- ============================================================================

SELECT
    id,
    company_name AS "公司名稱",
    name AS "客戶姓名",
    phone AS "電話",
    created_at AS "建立時間"
FROM customers
WHERE LOWER(company_name) LIKE '%test%'
   OR LOWER(company_name) LIKE '%demo%'
   OR company_name LIKE '%測試%'
   OR LOWER(name) LIKE '%test%'
   OR LOWER(name) LIKE '%demo%'
   OR name LIKE '%測試%'
ORDER BY id;


-- ============================================================================
-- 第三步：ACTUAL DELETE（真正刪除）
-- ⚠️ 警告：此操作不可逆！請確認上方 DRY RUN 結果後再執行！
-- ============================================================================

-- 取消下方註解來執行刪除

/*
DO $$
DECLARE
    v_customer_ids INT[];
    v_contract_ids INT[];
    v_payment_ids INT[];
    v_deleted_invoices INT;
    v_deleted_payments INT;
    v_deleted_contracts INT;
    v_deleted_customers INT;
    v_deleted_renewal_ops INT;
    v_deleted_commissions INT;
BEGIN
    -- 1. 找出測試客戶 ID
    SELECT ARRAY_AGG(id) INTO v_customer_ids
    FROM customers
    WHERE LOWER(company_name) LIKE '%test%'
       OR LOWER(company_name) LIKE '%demo%'
       OR company_name LIKE '%測試%'
       OR LOWER(name) LIKE '%test%'
       OR LOWER(name) LIKE '%demo%'
       OR name LIKE '%測試%';

    IF v_customer_ids IS NULL THEN
        RAISE NOTICE '沒有找到測試客戶資料';
        RETURN;
    END IF;

    -- 2. 找出關聯合約 ID
    SELECT ARRAY_AGG(id) INTO v_contract_ids
    FROM contracts
    WHERE customer_id = ANY(v_customer_ids);

    -- 3. 找出關聯付款 ID
    SELECT ARRAY_AGG(id) INTO v_payment_ids
    FROM payments
    WHERE contract_id = ANY(v_contract_ids);

    -- 4. 按順序刪除（遵守 FK 約束）

    -- 4.1 刪除發票
    DELETE FROM invoices WHERE payment_id = ANY(v_payment_ids);
    GET DIAGNOSTICS v_deleted_invoices = ROW_COUNT;

    -- 4.2 刪除佣金記錄
    DELETE FROM commission_records WHERE contract_id = ANY(v_contract_ids);
    GET DIAGNOSTICS v_deleted_commissions = ROW_COUNT;

    -- 4.3 刪除續約操作記錄
    DELETE FROM renewal_operations WHERE old_contract_id = ANY(v_contract_ids) OR new_contract_id = ANY(v_contract_ids);
    GET DIAGNOSTICS v_deleted_renewal_ops = ROW_COUNT;

    -- 4.4 刪除付款
    DELETE FROM payments WHERE contract_id = ANY(v_contract_ids);
    GET DIAGNOSTICS v_deleted_payments = ROW_COUNT;

    -- 4.5 清除合約的 renewed_from_id（避免 FK 衝突）
    UPDATE contracts SET renewed_from_id = NULL WHERE renewed_from_id = ANY(v_contract_ids);

    -- 4.6 刪除合約
    DELETE FROM contracts WHERE customer_id = ANY(v_customer_ids);
    GET DIAGNOSTICS v_deleted_contracts = ROW_COUNT;

    -- 4.7 刪除客戶
    DELETE FROM customers WHERE id = ANY(v_customer_ids);
    GET DIAGNOSTICS v_deleted_customers = ROW_COUNT;

    -- 5. 顯示結果
    RAISE NOTICE '========================================';
    RAISE NOTICE '清理完成！已刪除：';
    RAISE NOTICE '========================================';
    RAISE NOTICE '發票: % 筆', v_deleted_invoices;
    RAISE NOTICE '佣金記錄: % 筆', v_deleted_commissions;
    RAISE NOTICE '續約記錄: % 筆', v_deleted_renewal_ops;
    RAISE NOTICE '付款: % 筆', v_deleted_payments;
    RAISE NOTICE '合約: % 筆', v_deleted_contracts;
    RAISE NOTICE '客戶: % 筆', v_deleted_customers;
    RAISE NOTICE '========================================';
END;
$$;
*/

SELECT '請先執行 DRY RUN 確認刪除範圍，再取消 ACTUAL DELETE 區塊的註解' AS "提醒";
