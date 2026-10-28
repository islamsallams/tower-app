/*
Tower App V2.5.200 - SQL_249.
___________________________
*/
-- Read only: one JSON result. No login, PIN, token, phone or personal-name data.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
WITH units AS (
 SELECT unit_id,unit_number,status FROM public.tower_units
 WHERE translate(btrim(unit_number::text),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789') ~ '^0*26$'
), allocations AS (
 SELECT al.allocation_id,al.unit_id,al.charge_id,al.amount,al.paid,al.status allocation_status,
 c.title,c.status charge_status,c.service_id,c.subscription_id,
 greatest(0,al.amount-al.paid) remaining,
 (al.status='ACTIVE' AND c.status='ACTIVE') included_by_summary243,
 CASE WHEN al.status IS DISTINCT FROM 'ACTIVE' THEN 'allocation_status_not_ACTIVE'
 WHEN c.charge_id IS NULL THEN 'missing_charge'
 WHEN c.status IS DISTINCT FROM 'ACTIVE' THEN 'charge_status_not_ACTIVE'
 WHEN al.amount IS NULL OR al.paid IS NULL THEN 'null_amount_or_paid'
 WHEN al.amount<=al.paid THEN 'no_remaining' ELSE 'included' END summary_reason
 FROM public.tower_building_allocations al JOIN units u ON u.unit_id=al.unit_id
 LEFT JOIN public.tower_building_charges c ON c.charge_id=al.charge_id
), dues AS (
 SELECT d.due_id,d.unit_id,d.account_id,d.subscription_id,d.status,
 to_jsonb(d)->>'title' title,to_jsonb(d)->>'amount' stored_amount,
 public.tower_task_due_amount_internal(d.due_id) calculated_amount,
 public.tower_task_due_paid_internal(d.due_id) calculated_paid,
 (d.status='OPEN' AND ac.account_id IS NOT NULL) included_by_summary243,
 ac.service_id account_service_id,sub.service_id subscription_service_id
 FROM public.tower_finance_dues d JOIN units u ON u.unit_id=d.unit_id
 LEFT JOIN public.tower_finance_accounts ac ON ac.account_id=d.account_id
 LEFT JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
), functions AS (
 SELECT p.proname name,pg_get_function_identity_arguments(p.oid) arguments,pg_get_functiondef(p.oid) definition
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f' AND p.proname IN
 ('tower_resident_unit_dues_summary_243','tower_resident_dues_page_for_unit','tower_resident_dues_page',
 'tower_task_due_amount_internal','tower_task_due_paid_internal')
)
SELECT jsonb_build_object('scope','READ_ONLY_UNIT26_DUES','units',(SELECT coalesce(jsonb_agg(to_jsonb(u)),'[]'::jsonb) FROM units u),
 'buildingAllocations',(SELECT coalesce(jsonb_agg(to_jsonb(a)),'[]'::jsonb) FROM allocations a),
 'financeDues',(SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]'::jsonb) FROM dues d),
 'functions',(SELECT coalesce(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM functions f)) report;
COMMIT;
/*
___________________________
Tower App V2.5.200 - SQL_249.
Code End
*/
