-- ============================================================================
-- Hour Jungle CRM - 修復平面圖視圖 Join 條件
-- Migration: 035_fix_floor_positions_view.sql
--
-- 問題：原 view 缺少 branch_id 的 join 條件，導致不同分館的合約
--       會錯誤顯示在其他分館的平面圖上
-- ============================================================================

CREATE OR REPLACE VIEW v_floor_positions AS
SELECT
    fp.id AS floor_plan_id,
    fp.branch_id,
    fp.name AS floor_plan_name,
    fp.image_filename,
    fp.width AS plan_width,
    fp.height AS plan_height,
    pos.position_number,
    pos.x,
    pos.y,
    pos.width AS box_width,
    pos.height AS box_height,
    c.id AS contract_id,
    c.status AS contract_status,
    c.monthly_rent,
    c.start_date,
    c.end_date,
    cu.id AS customer_id,
    cu.company_name,
    cu.name AS contact_name,
    cu.phone AS contact_phone
FROM floor_plans fp
JOIN floor_positions pos ON pos.floor_plan_id = fp.id
LEFT JOIN contracts c ON c.position_number = pos.position_number
    AND c.branch_id = fp.branch_id
    AND c.status = 'active'
LEFT JOIN customers cu ON cu.id = c.customer_id
ORDER BY pos.position_number;
