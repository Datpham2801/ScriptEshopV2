
SELECT
    discrepancy_type,
    ref_type,
    ref_id,
    ref_detail_id,
    ref_date,
    branch_id,
    stock_id,
    inventory_item_id,
    lot_no,
    expired_date,
    ledger_value,
    compare_value,
    note
FROM (

    -- ============================================================
    -- NHÓM 1: NGUỒN GHI SỔ (chứng từ chưa có trong led_inventory_item_ledger)
    -- ============================================================

    -- #1 Tồn đầu kỳ không có trong sổ nhật ký
    SELECT
        'OPENING_LEDGER_MISMATCH'      AS discrepancy_type,
        oie.ref_type,
        oie.ref_id,
        NULL                            AS ref_detail_id,
        oie.ref_date                    AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế của opening_inventory_entry nếu khác
        oie.branch_id,
        oie.stock_id,
        oie.inventory_item_id,
        oie.lot_no,
        oie.expired_date,
        NULL AS ledger_value,
        NULL AS compare_value,
        'Tồn đầu kỳ chưa được ghi nhận vào sổ nhật ký (led_inventory_item_ledger)' AS note
    FROM opening_inventory_entry oie
    LEFT JOIN led_inventory_item_ledger l
        ON  l.ref_id             = oie.ref_id
        AND l.ref_type           = oie.ref_type
        AND l.inventory_item_id  = oie.inventory_item_id
        AND l.stock_id           = oie.stock_id
        AND l.branch_id          = oie.branch_id
        AND IFNULL(l.expired_date, '1900-01-01') = IFNULL(oie.expired_date, '1900-01-01')
        AND IFNULL(l.lot_no, '') = IFNULL(oie.lot_no, '')
    WHERE l.inventory_item_ledger_id IS NULL

    UNION ALL

    -- #2 Nhập kho không có trong sổ nhật ký
    SELECT
        'INWARD_LEDGER_MISMATCH',
        i.ref_type,
        i.ref_id,
        d.ref_detail_id,
        i.ref_date                      AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế của inward nếu khác (VD: inward_date)
        i.branch_id,
        d.stock_id,
        d.inventory_item_id,
        d.lot_no,
        d.expired_date,
        NULL, NULL,
        'Phiếu nhập kho chưa được ghi nhận vào sổ nhật ký'
    FROM inward i
    JOIN inward_detail d ON i.ref_id = d.ref_id
    LEFT JOIN led_inventory_item_ledger l
        ON  l.ref_id             = i.ref_id
        AND l.ref_detail_id      = d.ref_detail_id
        AND l.ref_type           = i.ref_type
        AND l.inventory_item_id  = d.inventory_item_id
        AND l.branch_id          = i.branch_id
        AND IFNULL(d.lot_no, '') = IFNULL(l.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l.expired_date, '1900-01-01')
    WHERE l.inventory_item_ledger_id IS NULL
      AND d.inventory_item_type = 1

    UNION ALL

    -- #3 Xuất kho không có trong sổ nhật ký
    SELECT
        'OUTWARD_LEDGER_MISMATCH',
        o.ref_type,
        o.ref_id,
        d.ref_detail_id,
        o.ref_date                      AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế của outward nếu khác
        o.branch_id,
        d.stock_id,
        d.inventory_item_id,
        d.lot_no,
        d.expired_date,
        NULL, NULL,
        'Phiếu xuất kho chưa được ghi nhận vào sổ nhật ký'
    FROM outward o
    JOIN outward_detail d ON o.ref_id = d.ref_id
    LEFT JOIN led_inventory_item_ledger l
        ON  l.ref_id             = o.ref_id
        AND l.ref_detail_id      = d.ref_detail_id
        AND l.ref_type           = o.ref_type
        AND l.inventory_item_id  = d.inventory_item_id
        AND l.branch_id          = o.branch_id
        AND IFNULL(d.lot_no, '') = IFNULL(l.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l.expired_date, '1900-01-01')
    WHERE l.inventory_item_ledger_id IS NULL

    UNION ALL

    -- #4 Chuyển kho (dòng xuất - from_stock_id) không có trong sổ nhật ký
    SELECT
        'TRANSFER_OUT_LEDGER_MISMATCH',
        t.ref_type,
        t.ref_id,
        d.ref_detail_id,
        t.ref_date                      AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế của transfer_stock nếu khác
        t.branch_id,
        d.from_stock_id                 AS stock_id,
        d.inventory_item_id,
        d.lot_no,
        d.expired_date,
        NULL, NULL,
        'Dòng xuất của phiếu chuyển kho chưa được ghi nhận vào sổ nhật ký'
    FROM transfer_stock t
    JOIN transfer_stock_detail d ON t.ref_id = d.ref_id
    LEFT JOIN led_inventory_item_ledger l
        ON  l.ref_id                  = t.ref_id
        AND l.ref_detail_id           = d.ref_detail_id
        AND l.ref_type                = t.ref_type
        AND l.inventory_item_id       = d.inventory_item_id
        AND l.stock_id                = d.from_stock_id
        AND IFNULL(d.lot_no, '')      = IFNULL(l.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l.expired_date, '1900-01-01')
        AND l.main_outward_quantity   > 0
    WHERE l.inventory_item_ledger_id IS NULL

    UNION ALL

    -- #5 Chuyển kho (dòng nhập - to_stock_id) không có trong sổ nhật ký
    SELECT
        'TRANSFER_IN_LEDGER_MISMATCH',
        t.ref_type,
        t.ref_id,
        d.ref_detail_id,
        t.ref_date                      AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế nếu khác
        t.branch_id,
        d.to_stock_id                   AS stock_id,
        d.inventory_item_id,
        d.lot_no,
        d.expired_date,
        NULL, NULL,
        'Dòng nhập của phiếu chuyển kho chưa được ghi nhận vào sổ nhật ký'
    FROM transfer_stock t
    JOIN transfer_stock_detail d ON t.ref_id = d.ref_id
    LEFT JOIN led_inventory_item_ledger l
        ON  l.ref_id                 = t.ref_id
        AND l.ref_detail_id          = d.ref_detail_id
        AND l.ref_type               = t.ref_type
        AND l.inventory_item_id      = d.inventory_item_id
        AND l.stock_id               = d.to_stock_id
        AND IFNULL(d.lot_no, '')     = IFNULL(l.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l.expired_date, '1900-01-01')
        AND l.main_inward_quantity   > 0
    WHERE l.inventory_item_ledger_id IS NULL

    UNION ALL

    -- #6 Phiếu điều chuyển (ref_type 2909/2910) không có trong sổ nhật ký (kiểm tra cả 2 chiều)
    SELECT
        'TRANSFER_INOUT_LEDGER_MISMATCH',
        t.ref_type,
        t.ref_id,
        d.ref_detail_id,
        t.ref_date                      AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế nếu khác
        t.branch_id,
        CASE WHEN l_out.inventory_item_ledger_id IS NULL THEN d.from_stock_id ELSE d.to_stock_id END AS stock_id,
        d.inventory_item_id,
        d.lot_no,
        d.expired_date,
        NULL, NULL,
        CASE
            WHEN l_out.inventory_item_ledger_id IS NULL AND l_in.inventory_item_ledger_id IS NULL
                THEN 'Thiếu cả dòng xuất và dòng nhập trong sổ nhật ký'
            WHEN l_out.inventory_item_ledger_id IS NULL
                THEN 'Thiếu dòng xuất (from_stock_id) trong sổ nhật ký'
            ELSE 'Thiếu dòng nhập (to_stock_id) trong sổ nhật ký'
        END AS note
    FROM transfer_stock t
    JOIN transfer_stock_detail d ON t.ref_id = d.ref_id
    LEFT JOIN led_inventory_item_ledger l_out
        ON  l_out.ref_id                = t.ref_id
        AND l_out.ref_detail_id         = d.ref_detail_id
        AND l_out.ref_type              = t.ref_type
        AND l_out.inventory_item_id     = d.inventory_item_id
        AND l_out.stock_id              = d.from_stock_id
        AND IFNULL(d.lot_no, '')        = IFNULL(l_out.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l_out.expired_date, '1900-01-01')
    LEFT JOIN led_inventory_item_ledger l_in
        ON  l_in.ref_id                 = t.ref_id
        AND l_in.ref_detail_id          = d.ref_detail_id
        AND l_in.ref_type               = t.ref_type
        AND l_in.inventory_item_id      = d.inventory_item_id
        AND l_in.stock_id               = d.to_stock_id
        AND IFNULL(d.lot_no, '')        = IFNULL(l_in.lot_no, '')
        AND IFNULL(d.expired_date, '1900-01-01') = IFNULL(l_in.expired_date, '1900-01-01')
    WHERE t.ref_type IN (2909, 2910)
      AND (l_out.inventory_item_ledger_id IS NULL
           OR l_in.inventory_item_ledger_id IS NULL)

    UNION ALL

    -- ============================================================
    -- NHÓM 2: SỔ NHẬT KÝ VS SỔ CÂN ĐỐI THEO NGÀY
    -- (Lệch tổng hợp theo ngày/item/kho, không gắn 1 chứng từ đơn lẻ)
    -- ============================================================

    -- #7 Sổ nhật ký vs sổ cân đối
    SELECT
        'LEDGER_BALANCE_MISMATCH',
        NULL AS ref_type,
        NULL AS ref_id,
        NULL AS ref_detail_id,
        ledger_sum.ref_date,
        NULL AS branch_id,
        ledger_sum.stock_id,
        ledger_sum.inventory_item_id,
        NULL AS lot_no,
        NULL AS expired_date,
        CONCAT('NhậpSL=', ledger_sum.inward_qty, ' | XuấtSL=', ledger_sum.outward_qty) AS ledger_value,
        CONCAT('NhậpSL=', IFNULL(b.inward_quantity,0), ' | XuấtSL=', IFNULL(b.outward_quantity,0)) AS compare_value,
        'Số liệu sổ nhật ký không khớp sổ cân đối ngày' AS note
    FROM (
        SELECT
            inventory_item_id, branch_id, stock_id,
            DATE(ref_date)          AS ref_date,
            SUM(main_inward_quantity)  AS inward_qty,
            SUM(inward_amount)         AS inward_amt,
            SUM(main_outward_quantity) AS outward_qty,
            SUM(outward_amount)        AS outward_amt
        FROM led_inventory_item_ledger
        GROUP BY inventory_item_id, branch_id, stock_id, DATE(ref_date)
    ) ledger_sum
    LEFT JOIN led_inventory_item_balance b
        ON  ledger_sum.inventory_item_id = b.inventory_item_id
        AND ledger_sum.branch_id         = b.branch_id
        AND ledger_sum.stock_id          = b.stock_id
        AND ledger_sum.ref_date          = b.ref_date
    WHERE b.inventory_item_balance_id IS NULL
       OR ABS(ledger_sum.inward_qty  - IFNULL(b.inward_quantity, 0))  > 0
       OR ABS(ledger_sum.inward_amt  - IFNULL(b.inward_amount, 0))    > 0
       OR ABS(ledger_sum.outward_qty - IFNULL(b.outward_quantity, 0)) > 0
       OR ABS(ledger_sum.outward_amt - IFNULL(b.outward_amount, 0))   > 0

    UNION ALL

    -- #8 Sổ nhật ký vs sổ cân đối lô
    SELECT
        'LEDGER_BALANCE_LOT_MISMATCH',
        NULL, NULL, NULL,
        ledger_sum.ref_date,
        NULL,
        ledger_sum.stock_id,
        ledger_sum.inventory_item_id,
        ledger_sum.lot_no,
        ledger_sum.expired_date,
        CONCAT('NhậpSL=', ledger_sum.inward_qty, ' | XuấtSL=', ledger_sum.outward_qty),
        CONCAT('NhậpSL=', IFNULL(b.inward_quantity,0), ' | XuấtSL=', IFNULL(b.outward_quantity,0)),
        'Số liệu sổ nhật ký không khớp sổ cân đối lô ngày'
    FROM (
        SELECT
            inventory_item_id, branch_id, stock_id,
            IFNULL(lot_no, '') AS lot_no,
            expired_date,
            DATE(ref_date)          AS ref_date,
            SUM(main_inward_quantity)  AS inward_qty,
            SUM(inward_amount)         AS inward_amt,
            SUM(main_outward_quantity) AS outward_qty,
            SUM(outward_amount)        AS outward_amt
        FROM led_inventory_item_ledger
        WHERE lot_no IS NOT NULL
        GROUP BY inventory_item_id, branch_id, stock_id, lot_no, expired_date, DATE(ref_date)
    ) ledger_sum
    LEFT JOIN led_inventory_item_balance_lot b
        ON  ledger_sum.inventory_item_id = b.inventory_item_id
        AND ledger_sum.branch_id         = b.branch_id
        AND ledger_sum.stock_id          = b.stock_id
        AND ledger_sum.lot_no            = b.lot_no
        AND IFNULL(ledger_sum.expired_date, '1900-01-01') = IFNULL(b.expired_date, '1900-01-01')
        AND ledger_sum.ref_date          = b.ref_date
    WHERE b.inventory_item_balance_lot_id IS NULL
       OR ABS(ledger_sum.inward_qty  - IFNULL(b.inward_quantity, 0))  > 0
       OR ABS(ledger_sum.inward_amt  - IFNULL(b.inward_amount, 0))    > 0
       OR ABS(ledger_sum.outward_qty - IFNULL(b.outward_quantity, 0)) > 0
       OR ABS(ledger_sum.outward_amt - IFNULL(b.outward_amount, 0))   > 0

    UNION ALL

    -- #9 Sổ nhật ký vs sổ cân đối theo vị trí kho
    SELECT
        'LEDGER_BALANCE_STOCK_LOCATION_MISMATCH',
        NULL, NULL, NULL,
        ledger_sum.ref_date,
        NULL,
        ledger_sum.stock_id,
        ledger_sum.inventory_item_id,
        NULL,
        NULL,
        CONCAT('NhậpSL=', ledger_sum.inward_qty, ' | XuấtSL=', ledger_sum.outward_qty),
        CONCAT('NhậpSL=', IFNULL(b.inward_quantity,0), ' | XuấtSL=', IFNULL(b.outward_quantity,0)),
        CONCAT('Lệch tại vị trí kho: ', ledger_sum.stock_location_id)
    FROM (
        SELECT
            inventory_item_id, branch_id, stock_id,
            IFNULL(stock_location_id, '00000000-0000-0000-0000-000000000000') AS stock_location_id,
            DATE(ref_date)          AS ref_date,
            SUM(main_inward_quantity)  AS inward_qty,
            SUM(inward_amount)         AS inward_amt,
            SUM(main_outward_quantity) AS outward_qty,
            SUM(outward_amount)        AS outward_amt
        FROM led_inventory_item_ledger
        WHERE stock_location_id IS NOT NULL
        GROUP BY inventory_item_id, branch_id, stock_id, stock_location_id, DATE(ref_date)
    ) ledger_sum
    LEFT JOIN led_inventory_item_balance_stock_location b
        ON  ledger_sum.inventory_item_id  = b.inventory_item_id
        AND ledger_sum.branch_id          = b.branch_id
        AND ledger_sum.stock_id           = b.stock_id
        AND ledger_sum.stock_location_id  = b.stock_location_id
        AND ledger_sum.ref_date           = b.ref_date
    WHERE b.inventory_item_balance_stock_location_id IS NULL
       OR ABS(ledger_sum.inward_qty  - IFNULL(b.inward_quantity, 0))  > 0
       OR ABS(ledger_sum.inward_amt  - IFNULL(b.inward_amount, 0))    > 0
       OR ABS(ledger_sum.outward_qty - IFNULL(b.outward_quantity, 0)) > 0
       OR ABS(ledger_sum.outward_amt - IFNULL(b.outward_amount, 0))   > 0

    UNION ALL

    -- ============================================================
    -- NHÓM 3: SỔ NHẬT KÝ VS SỔ TỒN CUỐI
    -- (Không phát sinh theo ngày - là tồn lũy kế nên trả kèm ngày phát sinh gần nhất để tham chiếu)
    -- ============================================================

    -- #10 Sổ nhật ký vs sổ tồn cuối
    SELECT
        'LEDGER_CLOSING_MISMATCH',
        NULL, NULL, NULL,
        ledger_sum.last_ref_date        AS ref_date,
        NULL,
        ledger_sum.stock_id,
        ledger_sum.inventory_item_id,
        NULL, NULL,
        CONCAT('SL lũy kế theo sổ NK=', ledger_sum.net_qty),
        CONCAT('SL sổ tồn cuối=', IFNULL(c.quantity, 0)),
        'Tồn lũy kế sổ nhật ký không khớp sổ tồn cuối'
    FROM (
        SELECT
            inventory_item_id, stock_id,
            MAX(ref_date) AS last_ref_date,
            SUM(main_inward_quantity - main_outward_quantity) AS net_qty,
            SUM(inward_amount - outward_amount)               AS net_amt
        FROM led_inventory_item_ledger
        GROUP BY inventory_item_id, stock_id
    ) ledger_sum
    LEFT JOIN led_inventory_item_closing c
        ON  ledger_sum.inventory_item_id = c.inventory_item_id
        AND ledger_sum.stock_id          = c.stock_id
    WHERE (c.inventory_item_closing_id IS NULL AND ABS(ledger_sum.net_qty) != 0)
       OR (c.inventory_item_closing_id IS NOT NULL AND (
            ABS(ledger_sum.net_qty - IFNULL(c.quantity, 0)) > 0
         OR ABS(ledger_sum.net_amt - IFNULL(c.amount, 0))   > 0
       ))

    UNION ALL

    -- #11 Sổ nhật ký vs sổ tồn cuối lô
    SELECT
        'LEDGER_CLOSING_LOT_MISMATCH',
        NULL, NULL, NULL,
        ledger_sum.last_ref_date,
        NULL,
        ledger_sum.stock_id,
        ledger_sum.inventory_item_id,
        ledger_sum.lot_no,
        ledger_sum.expired_date,
        CONCAT('SL lũy kế theo sổ NK=', ledger_sum.net_qty),
        CONCAT('SL sổ tồn cuối lô=', IFNULL(c.quantity, 0)),
        'Tồn lũy kế lô sổ nhật ký không khớp sổ tồn cuối lô'
    FROM (
        SELECT
            inventory_item_id, branch_id, stock_id,
            IFNULL(lot_no, '') AS lot_no,
            expired_date,
            MAX(ref_date) AS last_ref_date,
            SUM(main_inward_quantity - main_outward_quantity) AS net_qty,
            SUM(inward_amount - outward_amount)               AS net_amt
        FROM led_inventory_item_ledger
        WHERE lot_no IS NOT NULL
        GROUP BY inventory_item_id, branch_id, stock_id, lot_no, expired_date
    ) ledger_sum
    LEFT JOIN led_inventory_item_closing_lot c
        ON  ledger_sum.inventory_item_id = c.inventory_item_id
        AND ledger_sum.branch_id         = c.branch_id
        AND ledger_sum.stock_id          = c.stock_id
        AND ledger_sum.lot_no            = c.lot_no
        AND IFNULL(ledger_sum.expired_date, '1900-01-01') = IFNULL(c.expired_date, '1900-01-01')
    WHERE (c.inventory_item_closing_lot_id IS NULL AND ABS(ledger_sum.net_qty) != 0)
       OR (c.inventory_item_closing_lot_id IS NOT NULL AND (
            ABS(ledger_sum.net_qty - IFNULL(c.quantity, 0)) > 0
         OR ABS(ledger_sum.net_amt - IFNULL(c.amount, 0))   > 0
       ))

   
    UNION ALL

    -- ============================================================
    -- NHÓM 4: SỔ ĐƠN HÀNG
    -- ============================================================

    -- #13 Đơn hàng hợp lệ không có bản ghi trong led_order_item_ledger
    SELECT
        'ORDER_LEDGER_MISMATCH',
        NULL AS ref_type,
        o.order_id                      AS ref_id,
        d.order_detail_id               AS ref_detail_id,
        o.order_date                    AS ref_date,   -- ⚠️ đổi tên cột ngày thực tế của sa_order nếu khác
        NULL AS branch_id,
        NULL AS stock_id,
        d.inventory_item_id,
        NULL, NULL,
        NULL, NULL,
        'Đơn hàng hợp lệ chưa được ghi nhận vào sổ đơn hàng'
    FROM sa_order o
    JOIN sa_order_detail d ON o.order_id = d.order_id
    LEFT JOIN led_order_item_ledger l
        ON  l.order_id        = o.order_id
        AND l.order_detail_id = d.order_detail_id
    WHERE d.inventory_item_type = 1
      AND o.order_status > 5
      AND o.order_status < 50
      AND l.led_order_item_ledger_id IS NULL

    UNION ALL

    -- #14 order_quantity trong sổ tồn cuối lệch với thực tế từ led_order_item_ledger
    SELECT
        'ORDER_QUANTITY_CLOSING_MISMATCH',
        NULL, NULL, NULL,
        NULL AS ref_date,
        NULL,
        order_sum.stock_id,
        order_sum.inventory_item_id,
        NULL, NULL,
        CONCAT('SL đơn hàng theo sổ NK=', order_sum.total_order_qty),
        CONCAT('SL order_quantity sổ tồn cuối=', IFNULL(c.order_quantity, 0)),
        'SL đặt hàng trong sổ tồn cuối không khớp sổ đơn hàng'
    FROM (
        SELECT
            inventory_item_id, stock_id,
            SUM(main_quantity) AS total_order_qty
        FROM led_order_item_ledger
        GROUP BY inventory_item_id, stock_id
    ) order_sum
    LEFT JOIN led_inventory_item_closing c
        ON  order_sum.inventory_item_id = c.inventory_item_id
        AND order_sum.stock_id          = c.stock_id
    WHERE c.inventory_item_closing_id IS NULL
       OR ABS(order_sum.total_order_qty - IFNULL(c.order_quantity, 0)) > 0

) AS detail_result
ORDER BY discrepancy_type, ref_date, ref_id;
