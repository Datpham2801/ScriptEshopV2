-- =====================================================================
-- CÁC CHECK BỔ SUNG CÔNG NỢ (NCC + KH) - dùng chung schema output với Check 1
-- Check 1 = query expected_rows vs led_account_object_ledger (giữ nguyên)
-- Cột output: business_key, business_code, ref_id, ref_type, account_object_id,
--             branch_id, expected_amount, actual_amount,
--             expected_pay_amount, actual_pay_amount
-- Mỗi check chạy độc lập (1 rule / 1 query), đều có LIMIT @max_findings_plus_one
-- business_key đã chứa mã check => không trùng khoá giữa các check.
-- =====================================================================


-- ---------------------------------------------------------------------
-- CHECK 2: LEDGER_ORPHAN - Trong sổ có nhưng chứng từ gốc không có
--   NCC: ledger 1021/55051 không có ca_payment
--   KH : ledger 1011/55041 không có ca_receipt
-- ---------------------------------------------------------------------
SELECT SHA2(CONCAT_WS('|','LEDGER_ORPHAN',x.ref_id,x.ref_type,COALESCE(x.account_object_id,''),COALESCE(x.branch_id,'')),256) business_key,
       CONCAT('check=LEDGER_ORPHAN;ref=',x.ref_id,';type=',x.ref_type) business_code,
       x.ref_id, x.ref_type, x.account_object_id, x.branch_id,
       CAST(0 AS DECIMAL(21,6)) expected_amount, x.amount actual_amount,
       CAST(0 AS DECIMAL(21,6)) expected_pay_amount, x.pay_amount actual_pay_amount
FROM (
    SELECT CAST(led.ref_id AS CHAR(36)) ref_id, led.ref_type,
           CAST(led.account_object_id AS CHAR(36)) account_object_id,
           CAST(led.branch_id AS CHAR(36)) branch_id,
           SUM(COALESCE(led.amount,0)) amount, SUM(COALESCE(led.pay_amount,0)) pay_amount
    FROM led_account_object_ledger led
    WHERE (led.ref_type IN (55051,1021)
           AND NOT EXISTS (SELECT 1 FROM ca_payment ca WHERE ca.ref_id = led.ref_id))
       OR (led.ref_type IN (1011,55041)
           AND NOT EXISTS (SELECT 1 FROM ca_receipt ca WHERE ca.ref_id = led.ref_id))
    GROUP BY led.ref_id, led.ref_type, led.account_object_id, led.branch_id
) x
LIMIT @max_findings_plus_one;


-- ---------------------------------------------------------------------
-- CHECK 3: OVER_ALLOCATED - Nợ gốc bị phân bổ trả THỪA
--   NCC: vendor_payment gộp theo (NCC, phiếu nhập debt_ref_id)
--   KH : customer_receipt gộp theo (KH, phiếu nợ debt_ref_id)
--   expected_amount = nợ gốc (debt_amount), actual_amount = tổng đã phân bổ trả
--   ref_type = 301 cho NCC; 0 cho KH (debt_ref có thể là đơn hàng 5501 hoặc số dư đầu kỳ)
--   -> nếu bảng có cột loại chứng từ nợ, thay literal bằng cột đó.
-- ---------------------------------------------------------------------
WITH over_alloc AS (
    SELECT 'VENDOR' src, CAST(vp.debt_ref_id AS CHAR(36)) ref_id, 301 ref_type,
           CAST(vp.account_object_id AS CHAR(36)) account_object_id,
           CAST(MAX(vp.branch_id) AS CHAR(36)) branch_id,
           MAX(vp.debt_ref_no) debt_ref_no,
           MAX(vp.debt_amount) debt_amount, SUM(vp.pay_amount) total_paid
    FROM vendor_payment vp
    WHERE vp.debt_ref_id IS NOT NULL AND vp.pay_amount > 0
    GROUP BY vp.account_object_id, vp.debt_ref_id
    HAVING MAX(vp.debt_amount) - SUM(vp.pay_amount) < -0.0001

    UNION ALL

    SELECT 'CUSTOMER', CAST(cr.debt_ref_id AS CHAR(36)), 0,
           CAST(cr.account_object_id AS CHAR(36)),
           CAST(MAX(cr.branch_id) AS CHAR(36)),
           MAX(cr.debt_ref_no),
           MAX(cr.debt_amount), SUM(cr.pay_amount)
    FROM customer_receipt cr
    WHERE cr.debt_ref_id IS NOT NULL AND cr.pay_amount > 0
    GROUP BY cr.account_object_id, cr.debt_ref_id
    HAVING MAX(cr.debt_amount) - SUM(cr.pay_amount) < -0.0001
)
SELECT SHA2(CONCAT_WS('|','OVER_ALLOCATED',o.src,o.ref_id,COALESCE(o.account_object_id,'')),256) business_key,
       CONCAT('check=OVER_ALLOCATED;src=',o.src,';debt_ref=',o.ref_id,';no=',COALESCE(o.debt_ref_no,'')) business_code,
       o.ref_id, o.ref_type, o.account_object_id, o.branch_id,
       o.debt_amount expected_amount, o.total_paid actual_amount,
       CAST(0 AS DECIMAL(21,6)) expected_pay_amount, CAST(0 AS DECIMAL(21,6)) actual_pay_amount
FROM over_alloc o
LIMIT @max_findings_plus_one;


-- ---------------------------------------------------------------------
-- CHECK 4: ALLOC_VS_LEDGER - Phiếu trả nợ: tổng phân bổ lệch với sổ (cả chưa phân bổ hết)
--   Gộp 2 check cũ "chưa phân bổ hết" + "lệch phân bổ với sổ chính".
--   expected_pay_amount = tổng phân bổ (vendor_payment / customer_receipt)
--   actual_pay_amount   = pay_amount trên ledger
--   Ledger được gộp trước theo (ref_id, ref_type, account_object_id, branch_id)
--   và join theo account_object_id để tránh nhân dòng.
--   Lưu ý: 5513 (trả nợ trên đơn hàng) - bỏ khỏi danh sách nếu không phân bổ qua customer_receipt.
-- ---------------------------------------------------------------------
WITH led AS (
    SELECT l.ref_id, l.ref_type, l.account_object_id, l.branch_id,
           SUM(COALESCE(l.pay_amount,0)) pay_amount
    FROM led_account_object_ledger l
    WHERE l.pay_amount > 0
      AND l.ref_type IN (1021,55051,304,1011,55041,5513)
    GROUP BY l.ref_id, l.ref_type, l.account_object_id, l.branch_id
), alloc AS (
    SELECT ref_id, account_object_id, SUM(pay_amount) pay_amount
    FROM (
        SELECT vp.ref_id, vp.account_object_id, vp.pay_amount FROM vendor_payment vp
        UNION ALL
        SELECT cr.ref_id, cr.account_object_id, cr.pay_amount FROM customer_receipt cr
    ) u
    GROUP BY ref_id, account_object_id
)
SELECT SHA2(CONCAT_WS('|','ALLOC_VS_LEDGER',CAST(l.ref_id AS CHAR(36)),l.ref_type,COALESCE(CAST(l.account_object_id AS CHAR(36)),''),COALESCE(CAST(l.branch_id AS CHAR(36)),'')),256) business_key,
       CONCAT('check=ALLOC_VS_LEDGER;ref=',CAST(l.ref_id AS CHAR(36)),';type=',l.ref_type,
              CASE WHEN a.ref_id IS NULL THEN ';not_allocated'
                   WHEN a.pay_amount < l.pay_amount THEN ';under_allocated'
                   ELSE ';over_allocated' END) business_code,
       CAST(l.ref_id AS CHAR(36)) ref_id, l.ref_type,
       CAST(l.account_object_id AS CHAR(36)) account_object_id,
       CAST(l.branch_id AS CHAR(36)) branch_id,
       CAST(0 AS DECIMAL(21,6)) expected_amount, CAST(0 AS DECIMAL(21,6)) actual_amount,
       COALESCE(a.pay_amount,0) expected_pay_amount, l.pay_amount actual_pay_amount
FROM led l
LEFT JOIN alloc a ON a.ref_id = l.ref_id AND a.account_object_id <=> l.account_object_id
WHERE ABS(l.pay_amount - COALESCE(a.pay_amount,0)) > 0.0001
LIMIT @max_findings_plus_one;


-- ---------------------------------------------------------------------
-- CHECK 5: ALLOC_MISSING_LINK - Có phân bổ nhưng thiếu ledger hoặc chứng từ gốc
--   NCC: vendor_payment (1021,55051) thiếu ledger / ca_payment
--        (loại 304 trả hàng NCC vì 304 không bao giờ có trong ca_payment)
--   KH : customer_receipt (1011,55041) thiếu ledger / ca_receipt
-- ---------------------------------------------------------------------
SELECT SHA2(CONCAT_WS('|','ALLOC_MISSING_LINK',a.ref_id,a.ref_type,COALESCE(a.account_object_id,''),COALESCE(a.branch_id,'')),256) business_key,
       CONCAT('check=ALLOC_MISSING_LINK;ref=',a.ref_id,';type=',a.ref_type,';',
              CASE WHEN a.has_ledger = 0 AND a.has_source = 0 THEN 'missing_ledger_and_source'
                   WHEN a.has_ledger = 0 THEN 'missing_ledger'
                   ELSE 'missing_source' END) business_code,
       a.ref_id, a.ref_type, a.account_object_id, a.branch_id,
       CAST(0 AS DECIMAL(21,6)) expected_amount, CAST(0 AS DECIMAL(21,6)) actual_amount,
       a.pay_amount expected_pay_amount,
       COALESCE((SELECT SUM(l.pay_amount) FROM led_account_object_ledger l
                 WHERE CAST(l.ref_id AS CHAR(36)) = a.ref_id),0) actual_pay_amount
FROM (
    SELECT CAST(vp.ref_id AS CHAR(36)) ref_id, vp.ref_type,
           CAST(vp.account_object_id AS CHAR(36)) account_object_id,
           CAST(vp.branch_id AS CHAR(36)) branch_id,
           SUM(vp.pay_amount) pay_amount,
           EXISTS(SELECT 1 FROM led_account_object_ledger l WHERE l.ref_id = vp.ref_id) has_ledger,
           EXISTS(SELECT 1 FROM ca_payment c WHERE c.ref_id = vp.ref_id) has_source
    FROM vendor_payment vp
    WHERE vp.ref_type IN (1021,55051)
    GROUP BY vp.ref_id, vp.ref_type, vp.account_object_id, vp.branch_id

    UNION ALL

    SELECT CAST(cr.ref_id AS CHAR(36)), cr.ref_type,
           CAST(cr.account_object_id AS CHAR(36)),
           CAST(cr.branch_id AS CHAR(36)),
           SUM(cr.pay_amount),
           EXISTS(SELECT 1 FROM led_account_object_ledger l WHERE l.ref_id = cr.ref_id),
           EXISTS(SELECT 1 FROM ca_receipt c WHERE c.ref_id = cr.ref_id)
    FROM customer_receipt cr
    WHERE cr.ref_type IN (1011,55041)
    GROUP BY cr.ref_id, cr.ref_type, cr.account_object_id, cr.branch_id
) a
WHERE a.has_ledger = 0 OR a.has_source = 0
LIMIT @max_findings_plus_one;
