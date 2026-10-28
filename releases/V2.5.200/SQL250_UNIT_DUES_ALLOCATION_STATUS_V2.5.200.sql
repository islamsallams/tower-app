/*
Tower App V2.5.200 - SQL_250.

___________________________
*/
BEGIN;
-- SQL250: match the canonical resident dues page: parent charge status determines inclusion.
-- Allocation status OPEN is real production data; do not require the unrelated ACTIVE value.
-- No stored amount, allocation, charge, receipt or financial engine is mutated.
-- One read-only statement over canonical obligations. Never adds service-card prices/estimates
-- or previously aggregated service balances to building balances (which can include the same service).
CREATE OR REPLACE FUNCTION public.tower_resident_unit_dues_summary_243(p_token text,p_unit_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $fn$
DECLARE actor public.tower_users;result jsonb;invalid_count bigint;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_unit_id IS NULL THEN RAISE EXCEPTION 'UNIT_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id
  WHERE m.user_id=actor.user_id AND m.unit_id=p_unit_id AND m.ended_at IS NULL AND u.status='ACTIVE') THEN
  RAISE EXCEPTION 'UNIT_ACCESS_DENIED';
 END IF;
 PERFORM public.tower_assert_unit_account_view_238(p_token,p_unit_id,NULL);
 WITH building AS (
  SELECT 'BUILDING' source,al.allocation_id record_id,
   CASE WHEN s.service_kind='ONE_TIME' THEN 'TASKS' WHEN s.service_id IS NOT NULL THEN 'SERVICES' ELSE 'UNION' END kind,
   al.amount amount,al.paid paid
  FROM public.tower_building_allocations al
  JOIN public.tower_building_charges c ON c.charge_id=al.charge_id
  LEFT JOIN public.tower_service_subscriptions sub ON sub.subscription_id=c.subscription_id
  LEFT JOIN public.tower_services s ON s.service_id=coalesce(c.service_id,sub.service_id)
  WHERE al.unit_id=p_unit_id AND c.status='ACTIVE'
 ), finance AS (
  SELECT 'FINANCE' source,d.due_id record_id,
   CASE WHEN s.service_kind='ONE_TIME' THEN 'TASKS' WHEN s.service_id IS NOT NULL THEN 'SERVICES' ELSE 'UNION' END kind,
   public.tower_task_due_amount_internal(d.due_id) amount,
   public.tower_task_due_paid_internal(d.due_id) paid
  FROM public.tower_finance_dues d
  JOIN public.tower_finance_accounts ac ON ac.account_id=d.account_id
  LEFT JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
  LEFT JOIN public.tower_services s ON s.service_id=coalesce(sub.service_id,ac.service_id)
  -- Inactive services/subscriptions/accounts may still carry a real unpaid posted debt.
  WHERE d.unit_id=p_unit_id AND d.status='OPEN'
 ), obligations AS (
  -- Each source's primary key is visited exactly once. Group membership is mutually exclusive.
  SELECT * FROM building UNION ALL SELECT * FROM finance
 ), grouped AS (
  SELECT kind,sum(greatest(0,amount-paid)) remaining,count(*) FILTER(WHERE amount-paid>0) open_count
  FROM obligations GROUP BY kind
 ), groups AS (
  SELECT k.kind,coalesce(g.remaining,0) remaining,coalesce(g.open_count,0) open_count
  FROM (VALUES('UNION'),('SERVICES'),('TASKS')) k(kind) LEFT JOIN grouped g ON g.kind=k.kind
 )
 SELECT jsonb_build_object('scope','RESIDENT_UNIT_DUES_SUMMARY','schemaVersion',1,'readOnly',true,
  'unitId',p_unit_id,'asOf',statement_timestamp(),'excludesTrips',true,
  'total',coalesce((SELECT sum(remaining) FROM groups),0),
  'groups',(SELECT jsonb_agg(jsonb_build_object('kind',kind,'remaining',remaining,'count',open_count) ORDER BY kind) FROM groups)),
  (SELECT count(*) FROM obligations WHERE amount IS NULL OR paid IS NULL)
 INTO result,invalid_count;
 IF invalid_count>0 THEN RAISE EXCEPTION 'INVALID_UNIT_DUES_SUMMARY'; END IF;
 RETURN result;
END $fn$;
REVOKE ALL ON FUNCTION public.tower_resident_unit_dues_summary_243(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_resident_unit_dues_summary_243(text,uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.200 - SQL_250.

Code End
*/
