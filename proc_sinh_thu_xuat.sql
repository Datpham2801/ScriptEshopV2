-- ============================================================
-- Proc_GenMissingVouchers
-- Sinh chứng từ thiếu (phiếu thu + phiếu xuất kho) cho đơn hàng đã hoàn thành.
-- Bao gói nguyên script đã thử nghiệm, giữ nguyên logic cốt lõi.
-- Mỗi lần gọi xử lý tối đa v_batch_orders đơn (cũ nhất trước), không lọc theo thời gian.
-- Không COMMIT/ROLLBACK: transaction do caller (VoucherBackfillService) quản lý.
-- Idempotent: đơn đã có chứng từ thì không sinh lại.
-- ============================================================

DROP PROCEDURE IF EXISTS Proc_GenMissingVouchers;

DELIMITER $$

CREATE
PROCEDURE Proc_GenMissingVouchers()
BEGIN
    DECLARE v_batch_orders INT DEFAULT 1000;

    -- ============================================================
    -- PHẦN 1: SINH PHIẾU THU
    -- ============================================================

    DROP TEMPORARY TABLE IF EXISTS tmpTargetOrder;
    CREATE TEMPORARY TABLE tmpTargetOrder (order_id CHAR(36) NOT NULL PRIMARY KEY);
    INSERT INTO tmpTargetOrder (order_id)
    SELECT so.order_id
    FROM sa_order so
    LEFT JOIN voucher_reference vr
    ON vr.ref_id2 = so.order_id
    AND vr.ref_type1 = 2900
    WHERE so.order_status IN (80, 85) AND so.ref_type = 549
    AND vr.ref_id2 IS NULL AND so.order_id IN (
    SELECT DISTINCT
    so.order_id
    FROM sa_order so
    LEFT JOIN sa_order_detail sod ON so.order_id = sod.order_id
    LEFT JOIN voucher_reference vr ON vr.ref_id2 = so.order_id AND vr.ref_type1 = 2900 AND vr.ref_type2 = 549
    WHERE so.order_status IN (80, 85) AND vr.ref_id2 IS NULL AND sod.inventory_item_type = 1)
    LIMIT v_batch_orders;

    -- BƯỚC 0: Gom 3 nguồn đơn hàng cần sinh phiếu thu vào 1 bảng tạm
    DROP TEMPORARY TABLE IF EXISTS tmpOrderNotReceipt;
    CREATE TEMPORARY TABLE tmpOrderNotReceipt AS
    SELECT u.*,
    ROW_NUMBER() OVER (ORDER BY u.branch_id, u.ref_date, u.ref_no) AS rowNum
    FROM (
        -- NGUỒN 1: Đơn thường chưa có phiếu thu
        SELECT so.*, p.payment_type, p.amount, p.bank_account_id, p.account_number,
        CASE WHEN p.payment_type = 16 THEN 55044 WHEN p.payment_type IN (5, 18, 20, 21) THEN 1012 ELSE 55042 END AS receipt_ref_type,
        p.amount AS receipt_amount,
        1 AS receipt_is_cash_sale,
        p.amount AS receipt_remain_amount
        FROM sa_order so
        INNER JOIN sa_order_payment p ON p.order_id = so.order_id AND p.payment_type NOT IN (7, 8, 11, 12, 13, 15) AND p.amount > 0
        LEFT JOIN voucher_reference vr ON vr.ref_id2 = so.order_id AND vr.ref_type1 IN (1012, 55042, 55044)
        WHERE so.order_status IN (80, 85) AND so.ref_type = 549
        AND so.receive_amount > 0
        AND NOT (so.is_cod_paid = 1 AND so.channel_id <> 90)
        AND NOT (so.channel_id = 90 AND so.debt_payment_amount > 0)
        AND vr.ref_id2 IS NULL

        UNION ALL

        -- NGUỒN 2 (CASE 1): đơn nguồn khác (channel_id <> 90) đã thu COD
        SELECT so.*, p.payment_type, p.amount, p.bank_account_id, p.account_number,
        CASE WHEN p.payment_type IN (5, 18, 20, 21) THEN 1012 ELSE 55042 END,
        so.remain_amount,
        1,
        so.remain_amount
        FROM sa_order so
        INNER JOIN sa_order_payment p ON p.order_id = so.order_id AND p.payment_type NOT IN (7, 8, 11, 12, 13, 15) AND p.amount > 0
        WHERE so.order_status IN (80, 85)
        AND so.ref_type = 549
        AND so.is_cod_paid = 1
        AND so.channel_id <> 90
        AND so.remain_amount > 0
        AND NOT EXISTS (
            SELECT 1
            FROM voucher_reference vr
            WHERE vr.ref_id2 = so.order_id
              AND vr.ref_type1 IN (55200, 55210, 55042, 1012)
        )

        UNION ALL

        -- NGUỒN 3 (CASE 2): đơn channel_id = 90 có trả nợ
        SELECT so.*, p.payment_type, p.amount, p.bank_account_id, p.account_number,
        CASE WHEN p.payment_type = 15 THEN 1011 ELSE 55041 END,
        so.debt_payment_amount,
        0,
        COALESCE(closing.separate_debt_amount, 0)
        FROM sa_order so
        INNER JOIN sa_order_payment p ON p.order_id = so.order_id AND p.payment_type IN (11, 12, 13, 15) AND p.amount > 0
        LEFT JOIN (
            SELECT account_object_id, branch_id, MAX(separate_debt_amount) AS separate_debt_amount
            FROM led_account_object_closing
            GROUP BY account_object_id, branch_id
        ) closing ON closing.account_object_id = so.customer_id AND closing.branch_id = so.branch_id
        WHERE so.order_status IN (80, 85)
        AND so.ref_type = 549
        AND so.receive_amount > 0
        AND so.channel_id = 90
        AND so.debt_payment_amount > 0
        AND NOT EXISTS (
            SELECT 1
            FROM voucher_reference vr
            WHERE vr.ref_id2 = so.order_id
              AND vr.ref_type1 IN (1011, 55041)
        )
    ) u
    INNER JOIN tmpTargetOrder tgt ON tgt.order_id = u.order_id;

    DROP TEMPORARY TABLE IF EXISTS tmpObjRefReceipt;
    CREATE TEMPORARY TABLE tmpObjRefReceipt (primary_object_type INT, primary_object_id CHAR(36), reference_object_type INT, used_count DECIMAL(21, 6));

    -- BƯỚC 1: Build danh sách phiếu thu kèm ref_no
    DROP TEMPORARY TABLE IF EXISTS tmpReceiptByOrder;
    CREATE TEMPORARY TABLE tmpReceiptByOrder AS
    SELECT
    UUID() AS ref_id,
    ono.receipt_ref_type AS ref_type,
    CONCAT(IF(d.option_value IS NULL, '' , CONCAT(d.option_value, '-')), IFNULL(rs.prefix, ''), LPAD(IFNULL(rs.value, 0) + ono.rowNum, rs.length_of_value, '0')) AS ref_no,
    COALESCE(ono.completed_date, ono.ref_date, ono.order_date) AS ref_date,
    ono.branch_id,
    COALESCE(NULLIF(ono.cashier_name, ''), ono.employee_name) AS employee_name,
    COALESCE(ono.cashier_id, ono.employee_id) AS employee_id,
    ono.employee_code,
    CASE WHEN ono.receipt_ref_type IN (1011, 55041) THEN CONCAT('Thu tiền bán hàng từ ', ono.customer_name)
         WHEN ono.payment_type = 16 THEN CONCAT('Thu đặt cọc/trả trước đơn hàng ', ono.ref_no)
         ELSE CONCAT('Thu tiền bán hàng đơn hàng ', ono.ref_no) END AS description,
    ono.receipt_amount AS total_amount,
    CASE WHEN ono.payment_type IN (5, 18, 20, 21, 15) THEN 1 ELSE 2 END AS cash_type,
    ono.receipt_is_cash_sale AS is_cash_sale,
    ono.channel_id,
    ono.bank_account_id AS to_bank_account_id,
    ono.account_number AS to_bank_account_number,
    CASE WHEN ono.payment_type IN (2, 3, 12, 13) THEN FALSE ELSE TRUE END AS is_reconciled,
    ono.customer_id AS object_id,
    ono.customer_code AS object_code,
    ono.customer_name AS object_name,
    CASE WHEN ono.customer_id IS NOT NULL THEN 1 END AS object_type,
    ono.receipt_remain_amount,
    ono.order_id,
    ono.ref_no AS order_no,
    ono.ref_date AS order_date,
    ono.ref_type AS order_ref_type,
    rs.category_ref_type_id,
    rs.prefix,
    rs.length_of_value,
    rs.use_branch_prefix,
    rs.branch_prefix,
    rs.suffix,
    rs.value,
    rs.value + ono.rowNum AS currentRefNoValue
    FROM tmpOrderNotReceipt ono
    INNER JOIN refno_state rs ON ono.branch_id = rs.branch_id AND rs.category_ref_type_id = 1010
    LEFT JOIN dboption d ON rs.branch_id = d.branch_id AND option_id = 'StoreRefNo';
-- BƯỚC 2: Gom object_reference cho khách hàng
    INSERT tmpObjRefReceipt (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT 115, rbo.object_id, rbo.ref_type, COUNT(rbo.object_id)
    FROM tmpReceiptByOrder rbo
    WHERE rbo.object_id IS NOT NULL
    GROUP BY rbo.object_id, rbo.ref_type;

    -- BƯỚC 3: Insert ca_receipt master
    INSERT ca_receipt (ref_id, ref_type, ref_no, ref_date, branch_id, employee_name, employee_id, employee_code, description, total_amount, cash_type, channel_id, to_bank_account_id, to_bank_account_number, is_reconciled, object_id, object_code, object_name, object_type, is_auto_generate, is_cash_sale, approved_type, created_date, created_by, modified_date, modified_by)
    SELECT
    rbo.ref_id, rbo.ref_type, rbo.ref_no, rbo.ref_date, rbo.branch_id,
    rbo.employee_name, rbo.employee_id, rbo.employee_code, rbo.description,
    rbo.total_amount, rbo.cash_type, rbo.channel_id,
    rbo.to_bank_account_id, rbo.to_bank_account_number, rbo.is_reconciled,
    rbo.object_id, rbo.object_code, rbo.object_name, rbo.object_type,
    TRUE AS is_auto_generate,
    rbo.is_cash_sale,
    3 AS approved_type,
    CURRENT_TIMESTAMP(), 'script', CURRENT_TIMESTAMP(), NULL
    FROM tmpReceiptByOrder rbo;

    -- BƯỚC 4: Insert ca_receipt_detail
    INSERT ca_receipt_detail (ref_detail_id, ref_id, ref_type, description, amount, remain_amount, sort_order, budget_item_id, budget_item_code, budget_item_name, order_id, created_date, created_by, modified_date, modified_by)
    SELECT
    UUID() AS ref_detail_id,
    rbo.ref_id,
    rbo.ref_type,
    rbo.description,
    rbo.total_amount AS amount,
    rbo.receipt_remain_amount AS remain_amount,
    1 AS sort_order,
    '0d321ffd-14fa-11f0-9deb-005056b332bc' AS budget_item_id,
    'TTBH' AS budget_item_code,
    'Thu từ bán hàng' AS budget_item_name,
    rbo.order_id,
    CURRENT_TIMESTAMP(), 'script', CURRENT_TIMESTAMP(), NULL
    FROM tmpReceiptByOrder rbo;

    -- BƯỚC 5: object_reference cho tài khoản ngân hàng nhận
    INSERT tmpObjRefReceipt (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT 113, rbo.to_bank_account_id, rbo.ref_type, COUNT(rbo.to_bank_account_id)
    FROM tmpReceiptByOrder rbo
    WHERE rbo.to_bank_account_id IS NOT NULL
    GROUP BY rbo.to_bank_account_id, rbo.ref_type;

    -- BƯỚC 6: object_reference cho nhân viên
    INSERT tmpObjRefReceipt (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT 2, rbo.employee_id, rbo.ref_type, COUNT(rbo.employee_id)
    FROM tmpReceiptByOrder rbo
    WHERE rbo.employee_id IS NOT NULL
    GROUP BY rbo.employee_id, rbo.ref_type;

    -- BƯỚC 7: Insert voucher_reference liên kết phiếu thu với đơn hàng
    INSERT voucher_reference (reference_id, ref_id1, ref_id2, ref_type1, ref_type2, ref_no_finance1, ref_no_finance2, ref_date1, ref_date2, sort_order, created_date, created_by, modified_date, modified_by)
    SELECT
    UUID() AS reference_id,
    rbo.ref_id AS ref_id1,
    rbo.order_id AS ref_id2,
    rbo.ref_type AS ref_type1,
    rbo.order_ref_type AS ref_type2,
    rbo.ref_no AS ref_no_finance1,
    rbo.order_no AS ref_no_finance2,
    rbo.ref_date AS ref_date1,
    rbo.order_date AS ref_date2,
    0 AS sort_order,
    CURRENT_TIMESTAMP(), 'script', CURRENT_TIMESTAMP(), NULL
    FROM tmpReceiptByOrder rbo;

    -- BƯỚC 8: Insert refno_management
    INSERT refno_management (refno_management_id, id, state_key, branch_id, reftype_category, reftype, refno, refid, table_name, use_branch_prefix, branch_prefix, prefix, suffix, length_of_value, value, auto_increment, created_date, created_by, modified_date, modified_by)
    SELECT
    UUID() AS refno_management_id,
    CONCAT(rbo.branch_id, '|', rbo.category_ref_type_id, '|', rbo.ref_no) AS id,
    CONCAT(rbo.branch_id, '|', rbo.category_ref_type_id, '|', IFNULL(rbo.prefix, ''), '|', rbo.length_of_value) AS state_key,
    rbo.branch_id,
    rbo.category_ref_type_id AS reftype_category,
    rbo.ref_type,
    rbo.ref_no,
    rbo.ref_id,
    'ca_receipt' AS table_name,
    rbo.use_branch_prefix,
    rbo.branch_prefix,
    rbo.prefix,
    rbo.suffix,
    rbo.length_of_value,
    rbo.value,
    1 AS auto_increment,
    CURRENT_TIMESTAMP(), 'script', CURRENT_TIMESTAMP(), NULL
    FROM tmpReceiptByOrder rbo;

    -- BƯỚC 9: Cập nhật refno_state
    UPDATE refno_state rs
    LEFT JOIN (
        SELECT
            rm.branch_id,
            rm.reftype_category,
            MAX(CAST(REGEXP_SUBSTR(refno, '[0-9]+$') AS UNSIGNED)) AS value
        FROM refno_management rm
        WHERE rm.reftype_category = 1010
          AND refno REGEXP '[0-9]+$'
        GROUP BY rm.branch_id, rm.reftype_category
    ) trm ON rs.branch_id = trm.branch_id AND rs.category_ref_type_id = trm.reftype_category
    SET rs.value = trm.value,
        rs.max_value = trm.value
    WHERE rs.category_ref_type_id = 1010;

    -- BƯỚC 10: Insert object_reference mới
    INSERT object_reference (object_reference_id, primary_object_type, primary_object_id, reference_object_type, used_count, created_date, modified_date)
    SELECT UUID(), `or`.primary_object_type, `or`.primary_object_id, `or`.reference_object_type, `or`.used_count, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM tmpObjRefReceipt `or`
    LEFT JOIN object_reference or1 ON `or`.primary_object_id = or1.primary_object_id AND `or`.primary_object_type = or1.primary_object_type AND `or`.reference_object_type = or1.reference_object_type
    WHERE or1.primary_object_id IS NULL;

    -- BƯỚC 11: Cộng dồn used_count
    UPDATE object_reference or1
    INNER JOIN tmpObjRefReceipt `or` ON `or`.primary_object_id = or1.primary_object_id AND `or`.primary_object_type = or1.primary_object_type AND `or`.reference_object_type = or1.reference_object_type
    SET or1.used_count = or1.used_count + `or`.used_count, or1.modified_date = CURRENT_TIMESTAMP() WHERE 1 = 1;

    DROP TEMPORARY TABLE IF EXISTS tmpTargetOrder;
    DROP TEMPORARY TABLE IF EXISTS tmpOrderNotReceipt;
    DROP TEMPORARY TABLE IF EXISTS tmpReceiptByOrder;
    DROP TEMPORARY TABLE IF EXISTS tmpObjRefReceipt;

    -- ============================================================
    -- PHẦN 2: SINH PHIẾU XUẤT KHO
    -- ============================================================

    DROP TEMPORARY TABLE IF EXISTS tmpOrderNotOutward;
    CREATE TEMPORARY TABLE tmpOrderNotOutward AS
    SELECT
    so.*,
    ROW_NUMBER() OVER (
    ORDER BY so.branch_id, so.ref_date, so.ref_no) rowNum
    FROM sa_order so
    LEFT JOIN voucher_reference vr
    ON vr.ref_id2 = so.order_id
    AND vr.ref_type1 = 2900
    WHERE so.order_status IN (80, 85) AND so.ref_type = 549
    AND vr.ref_id2 IS NULL AND so.order_id IN (
    SELECT DISTINCT
    so.order_id
    FROM sa_order so
    LEFT JOIN sa_order_detail sod ON so.order_id = sod.order_id
    LEFT JOIN voucher_reference vr ON vr.ref_id2 = so.order_id AND vr.ref_type1 = 2900 AND vr.ref_type2 = 549
    WHERE so.order_status IN (80, 85) AND vr.ref_id2 IS NULL AND sod.inventory_item_type = 1)
    LIMIT v_batch_orders;

    DROP TEMPORARY TABLE IF EXISTS tmpObjRef;
    CREATE TEMPORARY TABLE tmpObjRef (
    primary_object_type int,
    primary_object_id char(36),
    reference_object_type int,
    used_count decimal(21, 6)
    );

    DROP TEMPORARY TABLE IF EXISTS tmpOutwardByOrder;
    CREATE TEMPORARY TABLE tmpOutwardByOrder AS
    SELECT
    UUID() ref_id,
    2900 AS ref_type,
    CONCAT(IF(d.option_value IS NULL, '' , CONCAT(d.option_value, '-')), IFNULL(rs.prefix, ''), LPAD(IFNULL(rs.value, 0) + ono.rowNum, rs.length_of_value, '0')) AS ref_no,
    ono.ref_date,
    ono.branch_id,
    'Tự động sinh' AS employee_name,
    CONCAT('Xuất kho bán hàng theo đơn hàng số ', ono.ref_no) journal_memo,
    0 AS total_amount,
    ono.customer_id account_object_id,
    ono.customer_code account_object_code,
    ono.customer_name AS account_object_name,
    0 AS payment_type,
    NULL attachment_list,
    CURRENT_TIMESTAMP() AS created_date,
    NULL created_by,
    CURRENT_TIMESTAMP() modified_date,
    NULL modified_by,
    NULL employee_id,
    ono.channel_id,
    NULL AS employee_code,
    1 object_type,
    ono.stock_id,
    ono.order_id,
    ono.ref_no AS order_no,
    ono.ref_date AS order_date,
    ono.ref_type AS order_ref_type,
    rs.category_ref_type_id,
    rs.prefix,
    rs.length_of_value,
    rs.use_branch_prefix,
    rs.branch_prefix,
    rs.suffix,
    rs.value,
    rs.value + ono.rowNum AS currentRefNoValue
    FROM tmpOrderNotOutward ono
    INNER JOIN refno_state rs
    ON ono.branch_id = rs.branch_id
    AND rs.category_ref_type_id = 2091
    LEFT JOIN dboption d ON rs.branch_id = d.branch_id AND option_id = 'StoreRefNo';

    INSERT tmpObjRef (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT
    115 AS primary_object_type,
    obo.account_object_id,
    2091,
    COUNT(obo.account_object_id)
    FROM tmpOutwardByOrder obo
    WHERE obo.account_object_id IS NOT NULL
    GROUP BY obo.account_object_id;

    INSERT INTO outward (ref_id, ref_type, ref_no, ref_date, branch_id, employee_name, journal_memo, total_amount,
      account_object_id, account_object_code, account_object_name, payment_type, attachment_list, created_date, created_by,
      modified_date, modified_by, employee_id, channel_id, employee_code, object_type)
    SELECT
          obo.ref_id,
          obo.ref_type,
          obo.ref_no,
          obo.ref_date,
          obo.branch_id,
          obo.employee_name,
          obo.journal_memo,
          obo.total_amount,
          CASE WHEN obo.account_object_id IS NULL
                OR obo.account_object_id IN ('', '00000000-0000-0000-0000-000000000000')
              THEN 'c560be89-d30b-11ef-b6d5-005056b332bc'
              ELSE obo.account_object_id
          END,
          CASE WHEN obo.account_object_id IS NULL
                OR obo.account_object_id IN ('', '00000000-0000-0000-0000-000000000000')
              THEN 'Mã khách lẻ'
              ELSE obo.account_object_code
          END,
          CASE WHEN obo.account_object_id IS NULL
                OR obo.account_object_id IN ('', '00000000-0000-0000-0000-000000000000')
              THEN 'Khách lẻ'
              ELSE obo.account_object_name
          END,
          obo.payment_type,
          obo.attachment_list,
          obo.created_date,
          obo.created_by,
          obo.modified_date,
          'MISA_SP',
          obo.employee_id,
          obo.channel_id,
          obo.employee_code,
          obo.object_type
    FROM tmpOutwardByOrder obo;
DROP TEMPORARY TABLE IF EXISTS tmpOutwardDetail;
    CREATE TEMPORARY TABLE tmpOutwardDetail AS
    SELECT
    UUID() AS ref_detail_id,
    ono.ref_id AS ref_id,
    sod.inventory_item_id,
    sod.sku_code,
    sod.inventory_item_name,
    ono.stock_id,
    s.stock_name,
    sod.unit_id,
    sod.quantity,
    sod.unit_name,
    0 AS unit_price,
    0 AS amount,
    NULL stock_location_id,
    NULL stock_location_name,
    sod.sort_order,
    NULL inward_ref_id,
    NULL inward_ref_detail_id,
    ii.unit_list,
    CURRENT_TIMESTAMP() created_date,
    NULL created_by,
    CURRENT_TIMESTAMP() modified_date,
    NULL modified_by,
    s.stock_code,
    ii.inventory_item_type,
    sod.lot_no,
    sod.expired_date,
    NULL drug_code,
    NULL production_date,
    NULL registration_no,
    NULL drug_unit_id,
    NULL drug_quantity,
    NULL drug_price,
    NULL drug_unit_name,
    sod.order_detail_id,
    sod.ref_detail_parent_id
    FROM sa_order_detail sod
    INNER JOIN tmpOutwardByOrder ono
    ON ono.order_id = sod.order_id
    INNER JOIN stock s
    ON ono.stock_id = s.stock_id
    INNER JOIN inventory_item ii
    ON sod.inventory_item_id = ii.inventory_item_id
    WHERE ii.inventory_item_type = 1
    AND IFNULL(sod.is_return, 0) = 0;

    INSERT outward_detail (ref_detail_id, ref_id, inventory_item_id, sku_code, inventory_item_name, stock_id, stock_name, unit_id, quantity, unit_name, unit_price, amount, stock_location_id, stock_location_name, sort_order, inward_ref_id, inward_ref_detail_id, unit_list, created_date, created_by, modified_date, modified_by, stock_code, inventory_item_type, lot_no, expired_date, drug_code, production_date, registration_no, drug_unit_id, drug_quantity, drug_price, drug_unit_name, order_detail_id, detail_parent_id)
    SELECT
    od.ref_detail_id,
    od.ref_id,
    od.inventory_item_id,
    od.sku_code,
    od.inventory_item_name,
    od.stock_id,
    od.stock_name,
    od.unit_id,
    od.quantity,
    od.unit_name,
    od.unit_price,
    od.amount,
    od.stock_location_id,
    od.stock_location_name,
    od.sort_order,
    od.inward_ref_id,
    od.inward_ref_detail_id,
    od.unit_list,
    od.created_date,
    od.created_by,
    od.modified_date,
    od.modified_by,
    od.stock_code,
    od.inventory_item_type,
    od.lot_no,
    od.expired_date,
    od.drug_code,
    od.production_date,
    od.registration_no,
    od.drug_unit_id,
    od.drug_quantity,
    od.drug_price,
    od.drug_unit_name,
    od.order_detail_id,
    od.ref_detail_parent_id
    FROM tmpOutwardDetail od;

    DROP TEMPORARY TABLE IF EXISTS tmpClosing;
    CREATE TEMPORARY TABLE tmpClosing AS
    SELECT
    liil.inventory_item_id,
    liil.stock_id,
    liil.ref_date,
    SUM(IFNULL(liil.main_inward_quantity, 0) - IFNULL(liil.main_outward_quantity, 0)) AS closingQuantity,
    SUM(IFNULL(liil.inward_amount, 0) - IFNULL(liil.outward_amount, 0)) AS closingAmount
    FROM led_inventory_item_ledger liil
    INNER JOIN (SELECT
    od.inventory_item_id,
    od.stock_id,
    obo.ref_date
    FROM tmpOutwardDetail od
    INNER JOIN tmpOutwardByOrder obo
    ON od.ref_id = obo.ref_id
    GROUP BY od.inventory_item_id,
    od.stock_id,
    obo.ref_date) AS o
    ON liil.inventory_item_id = o.inventory_item_id
    AND liil.stock_id = o.stock_id
    AND liil.ref_date < o.ref_date
    GROUP BY liil.inventory_item_id,
    liil.stock_id,
    liil.ref_date;

    UPDATE outward_detail od
    INNER JOIN tmpOutwardDetail od1
    ON od.ref_detail_id = od1.ref_detail_id
    INNER JOIN tmpOutwardByOrder obo
    ON od.ref_id = obo.ref_id
    INNER JOIN inventory_item ii
    ON od.inventory_item_id = ii.inventory_item_id
    INNER JOIN tmpClosing c
    ON od.inventory_item_id = c.inventory_item_id
    AND od.stock_id = c.stock_id
    AND obo.ref_date = c.ref_date
    LEFT JOIN unit_convert uc
    ON uc.inventory_item_id = IFNULL(ii.parent_id, ii.inventory_item_id)
    AND od.unit_id = uc.unit_id
    SET od.unit_price = CAST(ABS(CASE WHEN od.quantity * IFNULL(uc.convert_rate, 1) >= c.closingQuantity THEN (c.closingAmount * IFNULL(uc.convert_rate, 1)) / (od.quantity * IFNULL(uc.convert_rate, 1)) WHEN c.closingQuantity > 0 THEN (c.closingAmount * IFNULL(uc.convert_rate, 1)) / c.closingQuantity ELSE 0 END) AS decimal(21, 0)),
    od.amount = CAST(ABS(CASE WHEN od.quantity * IFNULL(uc.convert_rate, 1) >= c.closingQuantity THEN c.closingAmount WHEN c.closingQuantity > 0 THEN (c.closingAmount * IFNULL(uc.convert_rate, 1)) / c.closingQuantity ELSE 0 END) AS decimal(21, 0))
    WHERE od.ref_detail_id IS NOT NULL;

    UPDATE outward o
    INNER JOIN tmpOutwardByOrder obo
    ON o.ref_id = obo.ref_id
    INNER JOIN (SELECT
    od1.ref_id,
    SUM(od1.amount) AS totalAmount
    FROM outward_detail od1
    GROUP BY od1.ref_id) od
    ON o.ref_id = od.ref_id
    SET o.total_amount = od.totalAmount
    WHERE 1 = 1;

    DROP TEMPORARY TABLE IF EXISTS tmpClosing;

    INSERT tmpObjRef (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT
    100,
    od.inventory_item_id,
    2091,
    COUNT(od.inventory_item_id)
    FROM tmpOutwardDetail od
    GROUP BY od.inventory_item_id;

    INSERT tmpObjRef (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT
    104,
    od.stock_id,
    2091,
    COUNT(od.stock_id)
    FROM tmpOutwardDetail od
    WHERE od.stock_id IS NOT NULL
    GROUP BY od.stock_id;

    INSERT tmpObjRef (primary_object_type, primary_object_id, reference_object_type, used_count)
    SELECT
    105,
    od.stock_location_id,
    2091,
    COUNT(od.stock_location_id)
    FROM tmpOutwardDetail od
    WHERE od.stock_location_id IS NOT NULL
    GROUP BY od.stock_location_id;

    INSERT voucher_reference (reference_id, ref_id1, ref_id2, ref_type1, ref_type2, ref_no_finance1, ref_no_finance2, ref_date1, ref_date2, sort_order, created_date, created_by, modified_date, modified_by)
    SELECT
    UUID() reference_id,
    obo.ref_id ref_id1,
    obo.order_id AS ref_id2,
    obo.ref_type ref_type1,
    obo.order_ref_type ref_type2,
    obo.ref_no ref_no_finance1,
    obo.order_no ref_no_finance2,
    obo.ref_date AS ref_date1,
    obo.order_date ref_date2,
    0 sort_order,
    CURRENT_TIMESTAMP() created_date,
    NULL created_by,
    CURRENT_TIMESTAMP() modified_date,
    'MISA_SP' modified_by
    FROM tmpOutwardByOrder obo;

    INSERT refno_management (refno_management_id, id, state_key, branch_id, reftype_category, reftype, refno, refid, table_name, use_branch_prefix, branch_prefix, prefix, suffix, length_of_value, value, auto_increment, created_date, created_by, modified_date, modified_by)
    SELECT
    UUID() AS refno_management_id,
    CONCAT(obo.branch_id, '|', obo.category_ref_type_id, '|', obo.ref_no) id,
    CONCAT(obo.branch_id, '|', obo.category_ref_type_id, '|', obo.prefix, '|', obo.length_of_value) AS state_key,
    obo.branch_id,
    obo.category_ref_type_id AS reftype_category,
    obo.ref_type,
    obo.ref_no,
    obo.ref_id,
    'outward' table_name,
    obo.use_branch_prefix,
    obo.branch_prefix,
    obo.prefix,
    obo.suffix,
    obo.length_of_value,
    obo.value,
    1 AS auto_increment,
    CURRENT_TIMESTAMP() created_date,
    NULL created_by,
    CURRENT_TIMESTAMP() modified_date,
    'MISA_SP' modified_by
    FROM tmpOutwardByOrder obo;

    UPDATE refno_state rs
    LEFT JOIN (
        SELECT
            rm.branch_id,
            rm.reftype_category,
            MAX(CAST(REGEXP_SUBSTR(refno, '[0-9]+$') AS UNSIGNED)) AS value
        FROM refno_management rm
        WHERE rm.reftype_category = 2091
          AND refno REGEXP '[0-9]+$'
        GROUP BY rm.branch_id, rm.reftype_category
    ) trm ON rs.branch_id = trm.branch_id AND rs.category_ref_type_id = trm.reftype_category
    SET rs.value = trm.value,
        rs.max_value = trm.value
    WHERE rs.category_ref_type_id = 2091;

    INSERT object_reference (object_reference_id, primary_object_type, primary_object_id, reference_object_type, used_count, created_date, modified_date)
    SELECT
    UUID() object_reference_id,
    `or`.primary_object_type,
    `or`.primary_object_id,
    `or`.reference_object_type,
    `or`.used_count,
    CURRENT_TIMESTAMP() AS created_date,
    CURRENT_TIMESTAMP() AS modified_date
    FROM tmpObjRef `or`
    LEFT JOIN object_reference or1
    ON `or`.primary_object_id = or1.primary_object_id
    AND `or`.primary_object_type = or1.primary_object_type
    AND `or`.reference_object_type = or1.reference_object_type
    WHERE or1.primary_object_id IS NULL;

    UPDATE object_reference or1
    INNER JOIN tmpObjRef `or`
    ON `or`.primary_object_id = or1.primary_object_id
    AND `or`.primary_object_type = or1.primary_object_type
    AND `or`.reference_object_type = or1.reference_object_type
    SET or1.used_count = or1.used_count + `or`.used_count,
    or1.modified_date = CURRENT_TIMESTAMP() WHERE 1 = 1;

    DROP TEMPORARY TABLE IF EXISTS tmpOrderNotOutward;
    DROP TEMPORARY TABLE IF EXISTS tmpOutwardByOrder;
    DROP TEMPORARY TABLE IF EXISTS tmpObjRef;
    DROP TEMPORARY TABLE IF EXISTS tmpOutwardDetail;

    -- ============================================================
    -- PHẦN 3: CẬP NHẬT REFERENCE DISPLAY
    -- ============================================================

    DROP TEMPORARY TABLE IF EXISTS tmpBatchRefId2;
    CREATE TEMPORARY TABLE tmpBatchRefId2 (ref_id2 CHAR(36) NOT NULL PRIMARY KEY);
    INSERT INTO tmpBatchRefId2 (ref_id2)
    SELECT DISTINCT ref_id2
    FROM voucher_reference
    WHERE created_by = 'script' AND ref_id2 IS NOT NULL;

    BEGIN
        DECLARE done INT DEFAULT FALSE;
        DECLARE v_ref_id2 CHAR(36);
        DECLARE cur CURSOR FOR SELECT ref_id2 FROM tmpBatchRefId2;
        DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

        OPEN cur;
        read_loop: LOOP
            FETCH cur INTO v_ref_id2;
            IF done THEN
                LEAVE read_loop;
            END IF;
            CALL Proc_Reference_UpdateReferenceDisplay(v_ref_id2, 1);
        END LOOP;
        CLOSE cur;
    END;

    DROP TEMPORARY TABLE IF EXISTS tmpBatchRefId2;
END
$$

DELIMITER ;

CALL Proc_CheckProcedureExists('Proc_GenMissingVouchers');
