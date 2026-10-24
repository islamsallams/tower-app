/* Tower App V2.5.170 — STAGING80 / Original SQL227.
   Adds a read-only RPC. No ledger data, grants on tables, or existing RPCs changed.
   SQL226 was diagnostic only. Run this file once before deploying V2.5.170. */
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_unit_task_balances_read_for_unit(p_token text, p_unit_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE a public.tower_users; v_rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status <> 'ACTIVE' OR a.must_change_pin THEN
  RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role <> 'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_unit_id IS NULL THEN RAISE EXCEPTION 'UNIT_REQUIRED'; END IF;
 IF NOT EXISTS (
  SELECT 1 FROM public.tower_members m
  JOIN public.tower_units u ON u.unit_id=m.unit_id
  WHERE m.user_id=a.user_id AND m.unit_id=p_unit_id
    AND m.ended_at IS NULL AND u.status='ACTIVE'
 ) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 -- One SQL snapshot. Only applications to this unit's OPEN dues count as paid;
 -- unapplied advances, reversed receipts and fund contributions are excluded.
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'serviceId',q.service_id,'due',q.due,'paid',q.paid,
   'remaining',q.due-q.paid,'dueCount',q.due_count
 ) ORDER BY q.service_id),'[]'::jsonb) INTO v_rows
 FROM (
  SELECT sub.service_id, sum(d.amount) AS due, sum(p.paid) AS paid, count(*) AS due_count
  FROM public.tower_finance_dues d
  JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
    AND sub.unit_id=d.unit_id
  JOIN public.tower_services s ON s.service_id=sub.service_id
  CROSS JOIN LATERAL (
   SELECT coalesce(sum(ap.amount),0) AS paid
   FROM public.tower_finance_applications ap
   JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
     AND rp.account_id=d.account_id
   JOIN public.tower_finance_receipts rec ON rec.receipt_id=rp.receipt_id
     AND rec.unit_id=d.unit_id AND rec.receipt_status='POSTED'
   WHERE ap.due_id=d.due_id AND ap.application_kind='DUE'
  ) p
  WHERE d.unit_id=p_unit_id AND d.status='OPEN'
    AND s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL'
    AND s.enrollment_status='FINALIZED'
  GROUP BY sub.service_id
 ) q;
 RETURN jsonb_build_object('unitId',p_unit_id,'scope','UNIT_TASK_DUES','readOnly',true,'rows',v_rows);
END $function$;
REVOKE ALL ON FUNCTION public.tower_unit_task_balances_read_for_unit(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_unit_task_balances_read_for_unit(text,uuid) TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
/*__________________________________ End of code...*/
