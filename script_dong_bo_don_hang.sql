-- *Master sa_order
INSERT INTO general_order (order_id, order_no, channel_id, channel_name, ecom_order_no, order_status, partner_order_status, create_time,
prepare_due_time, total_item_amount, total_fee, delivery_fee, total_revenue, total_amount, deposit_amount, cod_amount, payment_method,
shipping_partner_id, shipping_partner_code, shipping_partner_name, delivery_code, partner_object_id, partner_object_name, created_date, created_by,
modified_date, modified_by, cancel_order_sla_time, priority, stock_id, stock_name, recipient_tel, recipient_name, email, receiver_name, buyer_legal_name,
buyer_tax_code, buyer_address, ref_date, publish_status, einvoice_id, einvoice_status, is_apply_tax, tax_amount, is_tax_reduction, tax_reduction_amount,
is_invoice_required, total_item_amount_before_tax, total_item_discount_amount_before_tax, discount_amount_before_tax, unit_price_type, total_quantity, buyer_legal_tel,
buyer_object_type, buyer_name, is_send_message, customer_id, customer_code, customer_name, customer_tel, customer_email, partner_user_id, partner_user_name, is_only_return,
branch_id, ref_type, ref_id, ref_no, shipping_partner_type, employee_id, employee_name, order_id_return, recipient_address, is_mapped_stock, is_mapped_product, invoice_type,
update_time, add_point, used_point, used_point_amount, used_point_amount_before_tax, coupon_discount_amount, coupon_discount_amount_before_tax, expected_issue_date,
is_apply_tax_for_shipping_fee, ta_career_group_code, ta_career_group_int_id, personal_tax_rate, identify_number, budget_item_code, passport_number, create_platform, shipping_date, complete_date, is_fully_returned_not_published , has_tax_reduction_amount_edited, cashier_id,
sale_channel_id, sale_channel_name, shipping_partner_amount, is_not_calculate_tax, service_tax_rate, delivery_amount_before_tax, delivery_tax_amount, delivery_tax_reduction_amount, is_customer_debt, is_cod_paid, customer_tax_code, customer_identify_number, cancel_date, is_sign )
SELECT so.order_id, so.ref_no, so.channel_id, CASE so.channel_id WHEN 90 THEN 'Cửa hàng' WHEN 20 THEN 'Shopee' WHEN 70 THEN 'TikTok Shop' WHEN 5 THEN 'Facebook' ELSE '' END AS channel_name,
NULL, so.order_status, '', so.order_date, NULL, so.total_item_amount,so.delivery_amount, so.delivery_amount, so.total_amount, so.total_amount, so.deposit_amount, so.remain_amount,
vsop.payment_type, so.shipping_partner_id, so.shipping_partner_code, so.shipping_partner_name,so.delivery_code, so.page_id, so.page_name,now(),'sync script', so.modified_date,
so.modified_by, NULL, 20, so.stock_id, so.stock_name, so.recipient_tel, so.recipient_name, so.inv_email, NULL, so.inv_buyer_legal_name, so.inv_buyer_tax_code, so.inv_buyer_address, so.ref_date, 0, UUID(), NULL, IFNULL(so.is_apply_tax, 0),
so.tax_amount, so.is_tax_reduction, so.tax_reduction_amount, so.is_invoice_required, so.total_item_amount_before_tax, so.total_item_discount_amount_before_tax, so.discount_amount_before_tax,
so.unit_price_type, so.total_item_quantity, so.inv_buyer_legal_tel, so.inv_buyer_object_type, so.inv_buyer_name, FALSE, so.customer_id, so.customer_code, so.customer_name, so.customer_tel, so.customer_email, so.partner_user_id,
so.conversation_channel_name, 0,so.branch_id, so.ref_type, so.order_id, so.ref_no, so.shipping_partner_type, so.employee_id, so.employee_name, so.order_id_return, so.recipient_address,
0, 0, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, so.ref_date,
so.is_apply_tax_for_shipping_fee, so.ta_career_group_code, so.ta_career_group_int_id, so.personal_tax_rate, so.inv_identify_number, so.inv_budget_item_code, so.inv_passport_number, so.create_platform, so.shipping_date , so.completed_date, so.is_fully_returned_not_published  , so.has_tax_reduction_amount_edited, so.cashier_id,
so.sale_channel_id, so.sale_channel_name, so.shipping_partner_amount, so.is_not_calculate_tax, so.service_tax_rate, so.delivery_amount_before_tax, so.delivery_tax_amount, so.delivery_tax_reduction_amount, so.is_customer_debt, so.is_cod_paid, so.customer_tax_code, so.customer_identify_number, so.cancel_date, so.is_sign
FROM sa_order so
LEFT JOIN view_sa_order_payment vsop ON so.order_id = vsop.order_id
LEFT JOIN general_order go ON so.order_id = go.order_id
WHERE go.order_id IS NULL;

-- -- *Detail sa_order_detail
INSERT INTO general_order_detail (order_id, order_detail_id, image, url_image, item_id_eshop, item_name_eshop, item_id_partner, item_name_partner, quantity, stock_id, stock_name, unit_id, unit_name, unit_price, created_date, created_by, modified_date, modified_by, detail_parent_id, item_sku_partner, parent_id_partner, parent_sku_partner, parent_name_partner, inventory_item_type, sku_code_eshop, unit_price_before_tax, discount_amount, origin_amount, amount_before_tax, tax_rate, tax_amount, amount_after_tax, tax_reduction_amount, tax_reduction_rate, discount_amount_before_tax, allocation_amount_before_tax, is_e_invoice_component, promotion_id, is_return, pre_unit_price_before_discount, pre_amount_before_discount, unit_price_eshop, allocation_point_amount, allocation_point_amount_before_tax, allocation_coupon_amount, allocation_coupon_amount_before_tax, inventory_item_name_invoice , is_tax_reduction, ta_career_group_int_id, personal_tax_rate, original_tax_reduction_amount,
sort_order, description, origin_quantity, lot_no, expired_date, allocation_amount, amount_after_discount, is_tax_reduction_amount_edited, allocation_used_point, is_drug, drug_dosage)
SELECT a.order_id, a.order_detail_id, a.file_name, NULL, a.inventory_item_id, a.inventory_item_name, NULL, NULL, a.quantity, IFNULL(b.stock_id, '00000000-0000-0000-0000-000000000000'), IFNULL(b.stock_name, '') ,a.unit_id,a.unit_name, a.unit_price, NOW(), '', NOW(), '', a.ref_detail_parent_id, NULL , NULL, NULL, NULL, a.inventory_item_type, a.sku_code, a.unit_price_before_tax, a.discount_amount , a.amount, a.amount_before_tax, a.tax_rate, a.tax_amount, a.amount_after_tax, a.tax_reduction_amount, a.tax_reduction_rate, a.discount_amount_before_tax, a.allocation_amount_before_tax, a.is_e_invoice_component, a.promotion_id, a.is_return, a.pre_unit_price_before_discount, a.pre_amount_before_discount, a.unit_price, NULL, NULL, NULL, NULL, a.inventory_item_name_invoice, a.is_tax_reduction, a.ta_career_group_int_id, a.personal_tax_rate , a.original_tax_reduction_amount,
a.sort_order, a.description, a.origin_quantity, a.lot_no, a.expired_date, a.allocation_amount, a.amount_after_discount, a.is_tax_reduction_amount_edited, IFNULL(a.allocation_used_point, 0), a.is_drug, a.drug_dosage
FROM sa_order_detail a
INNER JOIN sa_order b ON a.order_id = b.order_id
LEFT JOIN general_order_detail c ON c.order_detail_id = a.order_detail_id
WHERE c.order_id IS NULL OR c.order_detail_id IS NULL;

-- Cập nhật 1 số thông tin cơ bản của genneral_order
UPDATE general_order go
INNER JOIN sa_order so
ON so.order_id = go.order_id
SET go.order_status = so.order_status,
go.order_no = so.ref_no,
go.ref_no = so.ref_no,
go.ref_type = so.ref_type,
go.ref_date = so.ref_date,
go.shipping_date = so.shipping_date,
go.complete_date = so.completed_date,
go.cancel_date = so.cancel_date,
go.delivery_code = so.delivery_code,
go.is_customer_debt = so.is_customer_debt,
go.is_cod_paid = so.is_cod_paid,
-- go.expected_issue_date = CASE WHEN so.order_status IN (50, 60, 80) THEN NOW() -- PICK_UP_DONE / SHIPPED / COMPLETED
-- ELSE go.expected_issue_date END,
go.modified_date = so.modified_date,
go.modified_by = 'MISA_SP'
WHERE go.order_id = so.order_id
AND (go.ref_no != so.ref_no
OR go.order_status != so.order_status);

-- Xóa phiếu xuất kho với đơn hàng đã bị xóa
-- Xuất kho khi hủy đơn
DELETE  o FROM outward o 
INNER JOIN voucher_reference vr ON o.ref_id = vr.ref_id1 
INNER  JOIN sa_order so ON vr.ref_id2 = so.order_id 
WHERE so.order_status = 90;
 
-- Xóa phiếu thu với đơn hàng đã bị xóa
-- Thu/Chi khi hủy đơn
DELETE  cr FROM ca_receipt cr 
INNER JOIN voucher_reference vr ON cr.ref_id = vr.ref_id1 
INNER  JOIN sa_order so ON vr.ref_id2 = so.order_id 
WHERE so.order_status = 90;
 
-- Xóa refer của các đơn đã xóa
DELETE  vr FROM voucher_reference vr 
INNER  JOIN sa_order so ON vr.ref_id2 = so.order_id 
WHERE so.order_status = 90;
