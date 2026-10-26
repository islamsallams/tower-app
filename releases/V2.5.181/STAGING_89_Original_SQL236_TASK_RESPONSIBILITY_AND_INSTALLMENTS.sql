/*
Tower App V2.5.181 - SQL_236.

___________________________
*/
BEGIN;
DO $check$ BEGIN IF to_regprocedure('public.tower_task_controls_235(text,uuid,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'SQL235_REQUIRED'; END IF; END $check$;
-- No global role changes. Account-row locks serialize delegation with reassignment.
CREATE OR REPLACE FUNCTION public.tower_task_responsible_236(p_user uuid,p_service uuid)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.tower_finance_accounts ac JOIN public.tower_users u ON u.user_id=ac.beneficiary_user_id WHERE ac.service_id=p_service AND ac.account_kind='PERSONAL_SERVICE' AND ac.status='ACTIVE' AND ac.beneficiary_user_id=p_user AND u.status='ACTIVE') THEN RETURN false; END IF;
 PERFORM 1 FROM public.tower_services WHERE service_id=p_service FOR UPDATE;
 PERFORM ac.account_id FROM public.tower_finance_accounts ac JOIN public.tower_services s ON s.service_id=ac.service_id JOIN public.tower_users u ON u.user_id=ac.beneficiary_user_id
 WHERE ac.service_id=p_service AND ac.account_kind='PERSONAL_SERVICE' AND ac.status='ACTIVE' AND ac.beneficiary_user_id=p_user AND u.status='ACTIVE'
 AND s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL' AND s.status='ACTIVE'
 AND (SELECT count(*) FROM public.tower_finance_accounts x WHERE x.service_id=p_service AND x.account_kind='PERSONAL_SERVICE' AND x.status='ACTIVE')=1 FOR UPDATE OF ac;
 RETURN FOUND;
END $f$;
REVOKE ALL ON FUNCTION public.tower_task_responsible_236(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;


CREATE OR REPLACE FUNCTION public.tower_task_project_read_229(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;admin boolean;account uuid;rows jsonb;exp jsonb;adjustments jsonb;own_interest boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 admin:=a.role IN ('ADMIN','UNION') OR public.tower_task_responsible_236(a.user_id,p_service);
 IF NOT admin AND a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL';
 IF NOT FOUND OR (NOT admin AND s.status<>'ACTIVE') THEN RAISE EXCEPTION 'TASK_NOT_FOUND'; END IF;
 IF NOT admin THEN
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE'
    WHERE m.unit_id=p_unit AND m.user_id=a.user_id AND m.ended_at IS NULL) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 END IF;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=p_service;
 SELECT account_id INTO account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE';
 IF (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN account:=NULL; END IF;
 SELECT interested INTO own_interest FROM public.tower_task_interests WHERE service_id=p_service AND unit_id=p_unit;
 SELECT coalesce(jsonb_agg(jsonb_build_object('subscriptionId',sub.subscription_id,'unitId',sub.unit_id,'unitNumber',u.unit_number,
  'status',sub.status,'agreement',CASE WHEN admin THEN (SELECT to_jsonb(ag) FROM public.tower_task_agreements ag WHERE ag.subscription_id=sub.subscription_id) ELSE NULL END,
  'balance',public.tower_task_subscription_balance_internal(sub.subscription_id)) ORDER BY u.unit_number),'[]') INTO rows
 FROM public.tower_service_subscriptions sub JOIN public.tower_units u ON u.unit_id=sub.unit_id
 WHERE sub.service_id=p_service AND (admin OR sub.unit_id=p_unit);
 SELECT coalesce(jsonb_agg(CASE WHEN admin THEN to_jsonb(e)||jsonb_build_object('disbursed',EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements ed WHERE ed.expense_id=e.expense_id)) ELSE jsonb_build_object('description',e.description,'amount',e.amount,'state',e.state) END ORDER BY e.created_at DESC),'[]') INTO exp FROM public.tower_task_expenses e
 WHERE e.service_id=p_service AND (admin OR e.state='APPROVED');
 SELECT coalesce(jsonb_agg(jsonb_build_object('adjustmentId',ad.adjustment_id,'amount',ad.amount,'reason',ad.reason,'state',ad.state,
 'createdAt',ad.created_at,'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object('subscriptionId',l.subscription_id,'unitNumber',u.unit_number,'amount',l.amount)),'[]')
 FROM public.tower_task_adjustment_lines l JOIN public.tower_service_subscriptions sub ON sub.subscription_id=l.subscription_id
 JOIN public.tower_units u ON u.unit_id=sub.unit_id WHERE l.adjustment_id=ad.adjustment_id AND (admin OR sub.unit_id=p_unit))) ORDER BY ad.created_at DESC),'[]') INTO adjustments
 FROM public.tower_task_adjustments ad WHERE ad.service_id=p_service AND (admin OR ad.state='APPROVED');
 RETURN jsonb_build_object('serviceId',p_service,'name',s.name,'totalBudget',s.total_budget,'enrollment',s.enrollment_status,
 'project',CASE WHEN p.service_id IS NULL THEN jsonb_build_object('phase','PARTICIPATION','version',1,'distribution','EQUAL') WHEN admin THEN to_jsonb(p) ELSE to_jsonb(p)-'agreed_amounts'-'creation_reference'-'creation_payload'-'updated_by'-'target_units' END,
 'eligible',admin OR coalesce(cardinality(p.target_units),0)=0 OR p_unit=ANY(p.target_units),
 'availableUnits',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',u.unit_id,'unitNumber',u.unit_number,'floor',u.floor) ORDER BY u.unit_number),'[]') FROM public.tower_units u WHERE u.status='ACTIVE') ELSE '[]'::jsonb END,
 'interested',coalesce(own_interest,false),'interestCount',(SELECT count(*) FROM public.tower_task_interests WHERE service_id=p_service AND interested AND (coalesce(cardinality(p.target_units),0)=0 OR unit_id=ANY(p.target_units))),
 'subscriptions',rows,'expenses',exp,'adjustments',adjustments,'canManage',admin,'canApproveCredit',a.role IN ('ADMIN','UNION'),'canAdminister',a.role IN ('ADMIN','UNION'),'isTaskResponsible',public.tower_task_responsible_236(a.user_id,p_service),'canCollectTask',admin,
 'hasPersonalAccount',account IS NOT NULL,'holderAvailable',CASE WHEN admin AND account IS NOT NULL THEN public.tower_finance_holder_available_internal(account,a.user_id) ELSE NULL END,
 'refundAuthorizations',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('authorizationId',ra.refund_authorization_id,'subscriptionId',ra.subscription_id,'source',cr.refund_source,'amount',ra.max_amount-coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=ra.refund_authorization_id AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')),0))), '[]') FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=ra.refund_authorization_id WHERE cr.service_id=p_service AND ra.authorization_status='APPROVED') ELSE '[]'::jsonb END,
 'pendingSentRefunds',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('movementId',m.movement_id,'amount',m.amount)), '[]') FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE cr.service_id=p_service AND m.sender_user_id=a.user_id AND m.movement_status='PENDING') ELSE '[]'::jsonb END,
 'pendingRefunds',CASE WHEN a.role='RESIDENT' THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('movementId',m.movement_id,'amount',m.amount,'canConfirm',m.recipient_user_id=a.user_id)), '[]') FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE cr.service_id=p_service AND m.unit_id=p_unit AND m.movement_status='PENDING' AND m.recipient_user_id=a.user_id) ELSE '[]'::jsonb END,
 'execution',(SELECT jsonb_build_object('stage',w.stage,'percent',w.execution_percent,'date',w.execution_date) FROM public.tower_task_workflow w WHERE w.service_id=p_service),
 'donationTotal',(SELECT coalesce(sum(dn.amount-coalesce((SELECT sum(dr.amount) FROM public.tower_task_donation_returns dr WHERE dr.donation_id=dn.donation_id AND dr.state='CONFIRMED'),0)),0) FROM public.tower_task_donations dn JOIN public.tower_finance_receipts rr ON rr.receipt_id=dn.receipt_id AND rr.receipt_status='POSTED' WHERE dn.service_id=p_service),
 'donations',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('donationId',dn.donation_id,'unitNumber',un.unit_number,'amount',dn.amount,'available',dn.amount-coalesce((SELECT sum(dr.amount) FROM public.tower_task_donation_returns dr WHERE dr.donation_id=dn.donation_id AND dr.state IN ('PENDING','CONFIRMED')),0),'canReturn',dn.received_by=a.user_id)),'[]') FROM public.tower_task_donations dn JOIN public.tower_units un ON un.unit_id=dn.unit_id WHERE dn.service_id=p_service) ELSE '[]'::jsonb END,
 'donationReturns',(SELECT coalesce(jsonb_agg(jsonb_build_object('returnId',dr.return_id,'amount',dr.amount,'canConfirm',dr.recipient_id=a.user_id AND a.role='RESIDENT','canCancel',dr.sender_id=a.user_id AND admin)),'[]') FROM public.tower_task_donation_returns dr JOIN public.tower_task_donations dn ON dn.donation_id=dr.donation_id WHERE dn.service_id=p_service AND dr.state='PENDING' AND ((NOT admin AND dr.unit_id=p_unit AND dr.recipient_id=a.user_id) OR (admin AND dr.sender_id=a.user_id))),
 'actualExpenseTotal',(SELECT coalesce(sum(amount),0) FROM public.tower_task_expenses WHERE service_id=p_service AND state='APPROVED'),
 'unitId',CASE WHEN admin THEN NULL ELSE p_unit END);
END $f$;

CREATE OR REPLACE FUNCTION public.tower_service_shared_allocation_action(p_token text, p_action text, p_service_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users;
 v_service public.tower_services;
 v_account uuid;
 v_accounts int;
 v_units int;
 v_total_cents bigint;
 v_base_cents bigint;
 v_remainder bigint;
 v_existing int;
 v_result jsonb;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status <> 'ACTIVE' OR v_actor.must_change_pin THEN
   RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION') AND NOT (p_action='preview' AND public.tower_task_responsible_236(v_actor.user_id,p_service_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('preview','finalize') THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF p_service_id IS NULL THEN RAISE EXCEPTION 'INVALID_SERVICE_ID'; END IF;
 SELECT * INTO v_service FROM public.tower_services WHERE service_id=p_service_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
 IF v_service.service_kind <> 'ONE_TIME' OR v_service.pricing_mode <> 'SHARED_TOTAL' THEN
   RAISE EXCEPTION 'NOT_SHARED_COST_SERVICE'; END IF;
 IF v_service.status <> 'ACTIVE' THEN RAISE EXCEPTION 'SERVICE_NOT_ACTIVE'; END IF;
 IF v_service.enrollment_status NOT IN ('OPEN','CLOSED','FINALIZED') THEN
   RAISE EXCEPTION 'INVALID_ENROLLMENT_STATE'; END IF;
 SELECT count(DISTINCT unit_id), count(*) INTO v_units,v_existing
 FROM public.tower_service_subscriptions
 WHERE service_id=p_service_id AND status='ACTIVE';
 IF v_existing <> v_units THEN RAISE EXCEPTION 'MULTIPLE_ACTIVE_SUBSCRIPTIONS_PER_UNIT'; END IF;
 IF v_units=0 THEN RAISE EXCEPTION 'NO_ACTIVE_SUBSCRIBERS'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions
           WHERE service_id=p_service_id AND status='PENDING') THEN
   RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions
           WHERE service_id=p_service_id AND status='ACTIVE' AND quantity<>1) THEN
   RAISE EXCEPTION 'SHARED_COST_REQUIRES_UNIT_QUANTITY_ONE'; END IF;
 -- If a service has any historical personal account, never fall back to FUND.
 IF EXISTS(SELECT 1 FROM public.tower_finance_accounts
           WHERE service_id=p_service_id AND account_kind='PERSONAL_SERVICE') THEN
   SELECT count(*),min(account_id::text)::uuid INTO v_accounts,v_account
   FROM public.tower_finance_accounts
   WHERE service_id=p_service_id AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE';
 ELSE
   SELECT count(*),min(account_id::text)::uuid INTO v_accounts,v_account
   FROM public.tower_finance_accounts WHERE account_kind='FUND' AND status='ACTIVE';
 END IF;
 IF v_accounts<>1 THEN RAISE EXCEPTION 'EXACTLY_ONE_ACTIVE_FINANCE_ACCOUNT_REQUIRED'; END IF;
 v_total_cents := round((v_service.total_budget - coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service_id),0))*100)::bigint;
 IF v_total_cents<=0 THEN RAISE EXCEPTION 'INVALID_TOTAL_BUDGET'; END IF;
 v_base_cents := v_total_cents/v_units;
 v_remainder := v_total_cents%v_units;
 -- Stable allocation order by unit_id; integer cents sum exactly to budget.
 SELECT jsonb_agg(jsonb_build_object('unitId', t.unit_id,'subscriptionId',t.subscription_id,
     'amount', (v_base_cents + CASE WHEN t.rn<=v_remainder THEN 1 ELSE 0 END)::numeric/100)
     ORDER BY t.unit_id) INTO v_result
 FROM (SELECT unit_id,subscription_id,row_number() OVER(ORDER BY unit_id) rn
       FROM public.tower_service_subscriptions
       WHERE service_id=p_service_id AND status='ACTIVE') t;
 IF p_action='preview' THEN
   RETURN jsonb_build_object('status',v_service.enrollment_status,'accountId',v_account,
    'subscriberCount',v_units,'totalBudget',v_service.total_budget,'allocations',v_result);
 END IF;
 IF v_service.enrollment_status='FINALIZED' THEN
   IF (SELECT count(*) FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id) <> v_units THEN
      RAISE EXCEPTION 'FINALIZED_ALLOCATION_INTEGRITY_FAILURE'; END IF;
   RETURN jsonb_build_object('status','FINALIZED','replay',true,'subscriberCount',v_units,
      'totalBudget',v_service.total_budget,'allocations',v_result);
 END IF;
 IF v_service.enrollment_status <> 'CLOSED' THEN RAISE EXCEPTION 'ENROLLMENT_MUST_BE_CLOSED'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_finance_dues d
           JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id
           WHERE s.service_id=p_service_id) THEN
   RAISE EXCEPTION 'SERVICE_ALREADY_HAS_DUES'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_building_charges WHERE service_id=p_service_id) THEN
   RAISE EXCEPTION 'SERVICE_ALREADY_HAS_CHARGES'; END IF;
 -- The row is locked above: concurrent finalize requests serialize.
 INSERT INTO public.tower_finance_dues(unit_id,account_id,subscription_id,due_date,amount,status)
 SELECT t.unit_id,v_account,t.subscription_id,current_date,
        (v_base_cents + CASE WHEN t.rn<=v_remainder THEN 1 ELSE 0 END)::numeric/100,'OPEN'
 FROM (SELECT unit_id,subscription_id,row_number() OVER(ORDER BY unit_id) rn
       FROM public.tower_service_subscriptions
       WHERE service_id=p_service_id AND status='ACTIVE') t;
 UPDATE public.tower_services SET enrollment_status='FINALIZED',updated_at=now()
 WHERE service_id=p_service_id;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id)
 VALUES(v_actor.user_id,'FINALIZE_SHARED_SERVICE_ALLOCATION','SERVICE',p_service_id::text);
 RETURN jsonb_build_object('status','FINALIZED','replay',false,
  'subscriberCount',v_units,'totalBudget',v_service.total_budget,'allocations',v_result);
END $function$
;
CREATE OR REPLACE FUNCTION public.tower_task_project_action_229(p_token text,p_action text,p_service uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;v_id uuid;v_sub uuid;v_unit uuid;v_account uuid;
 v_receipt uuid;v_portion uuid;v_app uuid;
 v_amount numeric;v_ref text;v_reason text;v_data jsonb;v_row record;v_total numeric;v_remaining numeric;v_take numeric;v_due uuid;
 v_deferred_pay boolean:=false; e public.tower_task_expenses;ad public.tower_task_adjustments;v_current jsonb;v_authorization uuid;v_manager uuid;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action IN ('interest','confirm_refund','confirm_donation_return') THEN
  IF a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 ELSE IF a.role NOT IN ('ADMIN','UNION') THEN
 IF NOT public.tower_task_responsible_236(a.user_id,p_service) OR p_action NOT IN ('preview','expense_draft','expense_cancel','expense_pay','adjustment_draft','adjustment_cancel','collect') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='expense_cancel' AND NOT EXISTS(SELECT 1 FROM public.tower_task_expenses WHERE expense_id=(p_payload->>'expenseId')::uuid AND service_id=p_service AND recorded_by=a.user_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='adjustment_cancel' AND NOT EXISTS(SELECT 1 FROM public.tower_task_adjustments WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND service_id=p_service AND proposed_by=a.user_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 END IF; END IF;
 IF p_action='close_finalize' THEN
 IF EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=p_service AND enrollment_status='FINALIZED') THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
 PERFORM 1 FROM public.tower_services WHERE service_id=p_service FOR UPDATE;
 v_data:=public.tower_task_project_action_229(p_token,'preview',p_service,'{}');
 IF p_payload->'allocations' IS DISTINCT FROM v_data->'allocations' THEN RAISE EXCEPTION 'ALLOCATION_CHANGED_REFRESH'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=p_service AND enrollment_status='OPEN') THEN
 PERFORM public.tower_service_shared_enrollment_close(p_token,p_service);
 END IF;
 RETURN public.tower_task_project_action_229(p_token,'finalize',p_service,p_payload);
 END IF;
 IF p_action='create' THEN
  v_ref:=p_payload->>'reference';
  IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 THEN RAISE EXCEPTION 'REFERENCE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('task-create:'||v_ref,0));
  SELECT service_id,creation_payload,updated_by INTO v_id,v_data,v_unit FROM public.tower_task_projects WHERE creation_reference=v_ref;
  IF FOUND THEN IF v_data IS DISTINCT FROM (p_payload-'reference') OR v_unit<>a.user_id THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;RETURN jsonb_build_object('serviceId',v_id,'replayed',true); END IF;
  IF coalesce(p_payload->>'name','')='' OR coalesce(p_payload->>'totalBudget','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_TASK_FIELDS'; END IF;
  v_data:=public.tower_service_finance_action(p_token,'save',jsonb_build_object('name',p_payload->>'name','description',coalesce(p_payload->>'description',''),
   'price',0,'billingTiming','POSTPAID','allowQuantity',false,'cancelable',false,'revenueKind','PERSONAL_SERVICE',
   'beneficiaryUserId',p_payload->>'beneficiaryUserId','serviceKind','ONE_TIME','pricingMode','SHARED_TOTAL','totalBudget',p_payload->>'totalBudget'));
  v_id:=(v_data->>'serviceId')::uuid;
  INSERT INTO public.tower_task_projects(service_id,creation_reference,creation_payload,phase,scope_text,updated_by) VALUES(v_id,v_ref,p_payload-'reference','PARTICIPATION',coalesce(p_payload->>'scope',''),a.user_id);
  RETURN jsonb_build_object('serviceId',v_id);
 END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service FOR UPDATE;
 IF NOT FOUND OR s.service_kind<>'ONE_TIME' OR s.pricing_mode<>'SHARED_TOTAL' THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 INSERT INTO public.tower_task_projects(service_id,updated_by) VALUES(p_service,a.user_id) ON CONFLICT DO NOTHING;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=p_service FOR UPDATE;
 IF p.phase='FINANCIAL_CLOSED' AND p_action='close_financial' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
 IF p.phase IN ('CANCELLED','FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
 IF p_action='confirm_donation_return' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  PERFORM 1 FROM public.tower_task_donation_returns dr JOIN public.tower_task_donations dn ON dn.donation_id=dr.donation_id JOIN public.tower_members mb ON mb.unit_id=dr.unit_id AND mb.user_id=a.user_id AND mb.member_role='MANAGER' AND mb.ended_at IS NULL JOIN public.tower_units un ON un.unit_id=mb.unit_id AND un.status='ACTIVE'
   WHERE dr.return_id=(p_payload->>'returnId')::uuid AND dn.service_id=p_service AND dr.unit_id=v_unit AND dr.recipient_id=a.user_id AND dr.state IN ('PENDING','CONFIRMED') FOR UPDATE OF dr;
  IF NOT FOUND OR (SELECT count(*) FROM public.tower_members WHERE unit_id=v_unit AND member_role='MANAGER' AND ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'REFUND_ONLY_CURRENT_UNIT_MANAGER'; END IF;
  UPDATE public.tower_task_donation_returns SET state='CONFIRMED',confirmed_at=now() WHERE return_id=(p_payload->>'returnId')::uuid AND state='PENDING';
 ELSIF p_action='confirm_refund' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id JOIN public.tower_members mb ON mb.unit_id=m.unit_id AND mb.user_id=a.user_id AND mb.member_role='MANAGER' AND mb.ended_at IS NULL JOIN public.tower_units un ON un.unit_id=m.unit_id AND un.status='ACTIVE'
   WHERE cr.service_id=p_service AND m.unit_id=v_unit AND m.movement_id=(p_payload->>'movementId')::uuid AND m.recipient_user_id=a.user_id) THEN RAISE EXCEPTION 'REFUND_ONLY_CURRENT_UNIT_MANAGER'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_finance_cash_movements WHERE movement_id=(p_payload->>'movementId')::uuid AND movement_status='CONFIRMED') THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
  v_data:=public.tower_finance_refund_action(p_token,'confirm',jsonb_build_object('movementId',p_payload->>'movementId'));
 ELSIF p_action='interest' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  IF s.status<>'ACTIVE' OR p.phase<>'PROPOSAL' THEN RAISE EXCEPTION 'NOT_A_PROPOSAL'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE'
   WHERE m.user_id=a.user_id AND m.unit_id=v_unit AND m.ended_at IS NULL) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
  IF cardinality(p.target_units)>0 AND NOT v_unit=ANY(p.target_units) THEN RAISE EXCEPTION 'UNIT_OUTSIDE_TASK_SCOPE'; END IF;
  IF jsonb_typeof(p_payload->'interested')<>'boolean' THEN RAISE EXCEPTION 'INVALID_INTEREST'; END IF;
  INSERT INTO public.tower_task_interests(service_id,unit_id,interested,recorded_by) VALUES(p_service,v_unit,(p_payload->>'interested')::boolean,a.user_id)
   ON CONFLICT(service_id,unit_id) DO UPDATE SET interested=excluded.interested,recorded_by=a.user_id,recorded_at=now();
 ELSIF p_action IN ('terms','publish','cancel') THEN
  IF coalesce((p_payload->>'version')::bigint,-1)<>p.version THEN RAISE EXCEPTION 'TASK_CHANGED_REFRESH'; END IF;
  IF s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'TERMS_LOCKED'; END IF;
  IF p_action='terms' THEN
   IF coalesce(p_payload->>'distribution','') NOT IN ('EQUAL','CUSTOM') OR jsonb_typeof(p_payload->'agreedAmounts')<>'array' THEN RAISE EXCEPTION 'INVALID_DISTRIBUTION'; END IF;
   IF length(coalesce(p_payload->>'scope',''))>4000 OR length(coalesce(p_payload->>'policy',''))>4000 THEN RAISE EXCEPTION 'TEXT_TOO_LONG'; END IF;
   IF coalesce(p_payload->>'minimumStartAmount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_START_AMOUNT'; END IF;
   IF p_payload->>'distribution'='CUSTOM' AND (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN RAISE EXCEPTION 'DEDICATED_TASK_ACCOUNT_REQUIRED'; END IF;
   IF p_payload ? 'targetUnits' THEN
    IF jsonb_typeof(p_payload->'targetUnits')<>'array' THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_payload->'targetUnits') x(value) WHERE NOT EXISTS(SELECT 1 FROM public.tower_units u WHERE u.unit_id=x.value::uuid AND u.status='ACTIVE')) THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
    IF jsonb_array_length(p_payload->'targetUnits')>0 AND EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status IN ('ACTIVE','PENDING') AND NOT sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'targetUnits'))) THEN RAISE EXCEPTION 'EXISTING_PARTICIPANT_OUTSIDE_SCOPE'; END IF;
   END IF;
   UPDATE public.tower_task_projects SET target_units=CASE WHEN p_payload ? 'targetUnits' THEN ARRAY(SELECT DISTINCT value::uuid FROM jsonb_array_elements_text(p_payload->'targetUnits')) ELSE target_units END,scope_text=p_payload->>'scope',policy_text=p_payload->>'policy',deadline=nullif(p_payload->>'deadline','')::date,
    distribution=p_payload->>'distribution',agreed_amounts=p_payload->'agreedAmounts',minimum_start_amount=(p_payload->>'minimumStartAmount')::numeric WHERE service_id=p_service;
  ELSIF p_action='publish' THEN
   IF p.phase<>'PROPOSAL' OR btrim(p.scope_text)='' OR btrim(p.policy_text)='' THEN RAISE EXCEPTION 'TASK_TERMS_REQUIRED'; END IF;
   IF p.deadline IS NULL OR p.deadline<current_date THEN RAISE EXCEPTION 'VALID_DEADLINE_REQUIRED'; END IF;
   UPDATE public.tower_task_projects SET phase='PARTICIPATION' WHERE service_id=p_service;
  ELSE
   IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_finance_accounts ac JOIN public.tower_finance_receipt_portions rp ON rp.account_id=ac.account_id WHERE ac.service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_task_fund_contributions WHERE service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_task_expenses WHERE service_id=p_service AND state<>'CANCELLED')
   THEN RAISE EXCEPTION 'CANCELLATION_REQUIRES_FINANCIAL_SETTLEMENT'; END IF;
   UPDATE public.tower_task_projects SET phase='CANCELLED' WHERE service_id=p_service;
  END IF;
 ELSIF p_action='enroll' THEN
  IF p.phase<>'PARTICIPATION' OR s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'ENROLLMENT_CLOSED'; END IF;
  IF jsonb_typeof(p_payload->'unitIds')<>'array' OR jsonb_array_length(p_payload->'unitIds') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  IF coalesce(p_payload->>'source','') NOT IN ('WHATSAPP','MEETING','PHONE','OTHER','APP') OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_AGREEMENT'; END IF;
  IF (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_payload->'unitIds'))<>jsonb_array_length(p_payload->'unitIds') THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  v_data:=public.tower_add_service_subscribers(p_token,jsonb_build_object('serviceId',p_service,'unitIds',p_payload->'unitIds','quantity',1));
  FOR v_row IN SELECT sub.subscription_id FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status='ACTIVE' AND sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds')) LOOP
   INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(v_row.subscription_id,p_payload->>'source',coalesce(p_payload->>'note',''),a.user_id) ON CONFLICT DO NOTHING;
  END LOOP;
  IF (SELECT count(*) FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status='ACTIVE' AND sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds')))<>jsonb_array_length(p_payload->'unitIds') THEN RAISE EXCEPTION 'ENROLLMENT_RESULT_MISMATCH'; END IF;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_DIRECT_AGREEMENT','SERVICE',p_service::text);
  RETURN v_data;
 ELSIF p_action='preview' THEN
  IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
  v_total:=s.total_budget-coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0);
  IF s.enrollment_status='FINALIZED' AND EXISTS(SELECT 1 FROM public.tower_task_allocation_snapshots WHERE service_id=p_service) THEN
   SELECT jsonb_agg(jsonb_build_object('unitId',unit_id,'subscriptionId',subscription_id,'amount',original_amount) ORDER BY unit_id) INTO v_data FROM public.tower_task_allocation_snapshots WHERE service_id=p_service;
  ELSIF v_total=0 THEN
   SELECT jsonb_agg(jsonb_build_object('unitId',unit_id,'subscriptionId',subscription_id,'amount',0) ORDER BY unit_id) INTO v_data FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE';
  ELSIF p.distribution='CUSTOM' THEN
   IF jsonb_array_length(p.agreed_amounts)<>(SELECT count(*) FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE') OR (SELECT count(DISTINCT x->>'subscriptionId') FROM jsonb_array_elements(p.agreed_amounts) x)<>jsonb_array_length(p.agreed_amounts) THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(p.agreed_amounts) x WHERE coalesce(x->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.subscription_id=(x->>'subscriptionId')::uuid AND sub.service_id=p_service AND sub.status='ACTIVE')) THEN RAISE EXCEPTION 'INVALID_AGREED_AMOUNTS'; END IF;
   IF (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(p.agreed_amounts) x)<>v_total THEN RAISE EXCEPTION 'ALLOCATION_SUM_MISMATCH'; END IF;
   SELECT jsonb_agg(jsonb_build_object('unitId',sub.unit_id,'subscriptionId',sub.subscription_id,'amount',(x->>'amount')::numeric) ORDER BY sub.unit_id) INTO v_data FROM jsonb_array_elements(p.agreed_amounts) x JOIN public.tower_service_subscriptions sub ON sub.subscription_id=(x->>'subscriptionId')::uuid;
  ELSE RETURN public.tower_service_shared_allocation_action(p_token,'preview',p_service); END IF;
  IF v_data IS NULL THEN RAISE EXCEPTION 'NO_ACTIVE_SUBSCRIBERS'; END IF;
  RETURN jsonb_build_object('status',s.enrollment_status,'subscriberCount',jsonb_array_length(v_data),'totalBudget',s.total_budget,'allocations',v_data);
 ELSIF p_action='agreement' THEN
  IF p.phase<>'PARTICIPATION' OR s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'ENROLLMENT_CLOSED'; END IF;
  v_sub:=(p_payload->>'subscriptionId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE subscription_id=v_sub AND service_id=p_service AND status='ACTIVE') THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  IF coalesce(p_payload->>'source','') NOT IN ('APP','WHATSAPP','MEETING','PHONE','OTHER') OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_AGREEMENT'; END IF;
  INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(v_sub,p_payload->>'source',coalesce(p_payload->>'note',''),a.user_id)
   ON CONFLICT(subscription_id) DO UPDATE SET source=excluded.source,note=excluded.note,recorded_by=a.user_id,recorded_at=now();
 ELSE
  IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
  -- Serialize with receipts and transfers before changing debt/custody.
  PERFORM 1 FROM public.tower_units u WHERE u.unit_id IN (SELECT unit_id FROM public.tower_service_subscriptions WHERE service_id=p_service) ORDER BY u.unit_id FOR UPDATE;
  SELECT account_id INTO v_account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE' FOR UPDATE;
  IF v_account IS NULL AND p_action='finalize' AND p.distribution='EQUAL' THEN
   v_data:=public.tower_service_shared_allocation_action(p_token,'finalize',p_service);
   PERFORM public.tower_task_capture_snapshot_internal(p_service);RETURN v_data;
  END IF;
  IF NOT FOUND OR (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN RAISE EXCEPTION 'DEDICATED_TASK_ACCOUNT_REQUIRED'; END IF;
  IF p_action IN ('adjustment_draft','adjustment_approve') AND (p_action='adjustment_draft' OR EXISTS(SELECT 1 FROM public.tower_task_adjustments WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND state='DRAFT')) AND EXISTS(
   SELECT 1 FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=ra.refund_authorization_id
   WHERE cr.service_id=p_service AND ra.authorization_status='APPROVED' AND ra.max_amount>coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=ra.refund_authorization_id AND m.movement_status='CONFIRMED'),0)
  ) THEN RAISE EXCEPTION 'SETTLE_AUTHORIZED_REFUNDS_FIRST'; END IF;
  IF p_action='finalize' THEN
   IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
   IF s.enrollment_status='FINALIZED' THEN PERFORM public.tower_task_capture_snapshot_internal(p_service);RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF s.enrollment_status='CLOSED' AND s.total_budget=coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0) THEN
    IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
    UPDATE public.tower_services SET enrollment_status='FINALIZED',updated_at=now() WHERE service_id=p_service;
   ELSIF p.distribution='EQUAL' THEN
    v_data:=public.tower_service_shared_allocation_action(p_token,'finalize',p_service);
   ELSE
    IF s.enrollment_status<>'CLOSED' THEN RAISE EXCEPTION 'ENROLLMENT_MUST_BE_CLOSED'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service) THEN RAISE EXCEPTION 'SERVICE_ALREADY_HAS_DUES'; END IF;
    IF jsonb_array_length(p.agreed_amounts)=0 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p.agreed_amounts) x WHERE coalesce(x->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR (x->>'amount')::numeric<0) THEN RAISE EXCEPTION 'INVALID_AGREED_AMOUNTS'; END IF;
    IF (SELECT count(DISTINCT x->>'subscriptionId') FROM jsonb_array_elements(p.agreed_amounts) x)<>jsonb_array_length(p.agreed_amounts)
     OR jsonb_array_length(p.agreed_amounts)<>(SELECT count(*) FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE') THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
    v_total:=s.total_budget-coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0);
    IF (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(p.agreed_amounts) x)<>v_total THEN RAISE EXCEPTION 'ALLOCATION_SUM_MISMATCH'; END IF;
    FOR v_row IN SELECT value x FROM jsonb_array_elements(p.agreed_amounts) LOOP
     SELECT unit_id INTO v_unit FROM public.tower_service_subscriptions WHERE subscription_id=(v_row.x->>'subscriptionId')::uuid AND service_id=p_service AND status='ACTIVE';
     IF NOT FOUND THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
     IF (v_row.x->>'amount')::numeric>0 THEN INSERT INTO public.tower_finance_dues(unit_id,account_id,subscription_id,due_date,amount,status) VALUES(v_unit,v_account,(v_row.x->>'subscriptionId')::uuid,current_date,(v_row.x->>'amount')::numeric,'OPEN'); END IF;
    END LOOP;
    UPDATE public.tower_services SET enrollment_status='FINALIZED',updated_at=now() WHERE service_id=p_service;
   END IF;
   PERFORM public.tower_task_capture_snapshot_internal(p_service);
   FOR v_row IN SELECT DISTINCT unit_id FROM public.tower_task_allocation_snapshots WHERE service_id=p_service ORDER BY unit_id LOOP PERFORM public.tower_finance_apply_advances_internal(v_row.unit_id,v_account); END LOOP;
  ELSIF p_action='collect' THEN
   IF a.role NOT IN ('ADMIN','UNION') AND NOT public.tower_task_responsible_236(a.user_id,p_service) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
   v_unit:=(p_payload->>'unitId')::uuid;
   SELECT subscription_id INTO v_sub FROM public.tower_service_subscriptions WHERE service_id=p_service AND unit_id=v_unit AND status='ACTIVE';
   IF NOT FOUND THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE'; END IF;
   v_ref:=p_payload->>'reference';
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 80 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_RECEIPT_FIELDS'; END IF;
   v_data:=public.tower_finance_personal_receipt_action(p_token,jsonb_build_object('unitId',v_unit,'amount',p_payload->>'amount','portions',jsonb_build_array(jsonb_build_object('account_id',v_account,'amount',p_payload->>'amount')),'externalReference','task:'||p_service::text||':'||v_ref));
   v_receipt:=(v_data->>'receiptId')::uuid;
   FOR v_row IN SELECT ap.application_id,ap.amount FROM public.tower_finance_applications ap JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id WHERE rp.receipt_id=v_receipt AND ap.application_kind='ADVANCE' LOOP
    IF NOT EXISTS(SELECT 1 FROM public.tower_finance_advance_subscription_links WHERE advance_application_id=v_row.application_id AND subscription_id=v_sub) THEN
     INSERT INTO public.tower_finance_advance_subscription_links(advance_application_id,subscription_id,amount,linked_by) VALUES(v_row.application_id,v_sub,v_row.amount,a.user_id);
    END IF;
   END LOOP;
   PERFORM public.tower_finance_apply_advances_internal(v_unit,v_account);
  ELSIF p_action IN ('donation_return','cancel_donation_return') THEN
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   IF p_action='cancel_donation_return' THEN
    UPDATE public.tower_task_donation_returns dr SET state='CANCELLED' FROM public.tower_task_donations dn WHERE dr.return_id=(p_payload->>'returnId')::uuid AND dn.donation_id=dr.donation_id AND dn.service_id=p_service AND dr.sender_id=a.user_id AND dr.state='PENDING';
    IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_NOT_PENDING'; END IF;
   ELSE
    v_ref:=p_payload->>'reference';v_reason:=btrim(coalesce(p_payload->>'reason',''));
    IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR length(v_reason) NOT BETWEEN 1 AND 2000 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_DONATION_RETURN'; END IF;
    v_id:=(p_payload->>'donationId')::uuid;v_amount:=(p_payload->>'amount')::numeric;
    IF EXISTS(SELECT 1 FROM public.tower_task_donation_returns WHERE reference=v_ref AND donation_id=v_id AND amount=v_amount AND reason=v_reason AND sender_id=a.user_id) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
    SELECT dn.unit_id,dn.amount INTO v_unit,v_total FROM public.tower_task_donations dn JOIN public.tower_finance_receipts rr ON rr.receipt_id=dn.receipt_id AND rr.receipt_status='POSTED' WHERE dn.donation_id=v_id AND dn.service_id=p_service AND dn.received_by=a.user_id FOR UPDATE OF dn;
    IF NOT FOUND THEN RAISE EXCEPTION 'ONLY_DONATION_COLLECTOR_CAN_RETURN'; END IF;
    IF v_amount<=0 OR v_amount>v_total-coalesce((SELECT sum(amount) FROM public.tower_task_donation_returns WHERE donation_id=v_id AND state IN ('PENDING','CONFIRMED')),0) THEN RAISE EXCEPTION 'RETURN_EXCEEDS_DONATION'; END IF;
    IF (SELECT count(*) FROM public.tower_members mb JOIN public.tower_users us ON us.user_id=mb.user_id AND us.role='RESIDENT' AND us.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
   SELECT mb.user_id INTO v_manager FROM public.tower_members mb JOIN public.tower_users usr ON usr.user_id=mb.user_id AND usr.role='RESIDENT' AND usr.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL;
    IF v_manager IS NULL OR v_manager=a.user_id THEN RAISE EXCEPTION 'INDEPENDENT_UNIT_MANAGER_REQUIRED'; END IF;
    IF v_amount>public.tower_finance_holder_available_internal(v_account,a.user_id) THEN RAISE EXCEPTION 'INSUFFICIENT_HOLDER_BALANCE'; END IF;
    INSERT INTO public.tower_task_donation_returns(donation_id,account_id,unit_id,sender_id,recipient_id,amount,reason,reference) VALUES(v_id,v_account,v_unit,a.user_id,v_manager,v_amount,v_reason,v_ref);
   END IF;
  ELSIF p_action='donation' THEN
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   v_ref:=p_payload->>'reference';v_unit:=(p_payload->>'unitId')::uuid;
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_DONATION'; END IF;
   v_amount:=(p_payload->>'amount')::numeric;IF v_amount<=0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   SELECT donation_id,amount,unit_id,note INTO v_id,v_total,v_sub,v_reason FROM public.tower_task_donations WHERE service_id=p_service AND reference=v_ref;
   IF FOUND THEN
    IF (v_total,v_sub,v_reason) IS DISTINCT FROM (v_amount,v_unit,coalesce(p_payload->>'note','')) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
    RETURN jsonb_build_object('success',true,'replayed',true);
   END IF;
   PERFORM 1 FROM public.tower_units WHERE unit_id=v_unit AND status='ACTIVE' FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
   INSERT INTO public.tower_finance_receipts(unit_id,collector_id,amount,external_reference) VALUES(v_unit,a.user_id,v_amount,'task-donation:'||p_service::text||':'||v_ref) RETURNING receipt_id INTO v_receipt;
   INSERT INTO public.tower_finance_receipt_portions(receipt_id,account_id,amount) VALUES(v_receipt,v_account,v_amount) RETURNING portion_id INTO v_portion;
   INSERT INTO public.tower_finance_applications(portion_id,due_id,amount,application_kind) VALUES(v_portion,NULL,v_amount,'ADVANCE') RETURNING application_id INTO v_app;
   INSERT INTO public.tower_task_donations(service_id,receipt_id,application_id,unit_id,amount,reference,note,received_by) VALUES(p_service,v_receipt,v_app,v_unit,v_amount,v_ref,coalesce(p_payload->>'note',''),a.user_id);
  ELSIF p_action IN ('expense_draft','adjustment_draft') THEN
   v_ref:=p_payload->>'reference';v_reason:=btrim(coalesce(p_payload->>'description',p_payload->>'reason',''));
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR length(v_reason) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'REFERENCE_AND_REASON_REQUIRED'; END IF;
   IF coalesce(p_payload->>'amount','') !~ '^-?[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   v_amount:=(p_payload->>'amount')::numeric;
   IF v_amount=0 OR abs(v_amount)>999999999999.99 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   IF p_action='expense_draft' THEN
    IF v_amount<0 OR coalesce(p_payload->>'funding','') NOT IN ('UNPAID','PERSONAL','TASK') OR length(coalesce(p_payload->>'evidence',''))>2000 OR length(coalesce(p_payload->>'recipient',''))>500 THEN RAISE EXCEPTION 'INVALID_EXPENSE'; END IF;
    SELECT * INTO e FROM public.tower_task_expenses WHERE service_id=p_service AND reference=v_ref;
    IF FOUND THEN
     IF (e.amount,e.description,e.funding,e.recipient,e.evidence,e.recorded_by,e.expense_date) IS DISTINCT FROM (v_amount,v_reason,p_payload->>'funding',coalesce(p_payload->>'recipient',''),coalesce(p_payload->>'evidence',''),a.user_id,coalesce(nullif(p_payload->>'date','')::date,current_date)) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
     RETURN jsonb_build_object('expenseId',e.expense_id,'replayed',true);
    END IF;
    INSERT INTO public.tower_task_expenses(service_id,reference,amount,description,funding,recipient,evidence,recorded_by,expense_date)
     VALUES(p_service,v_ref,v_amount,v_reason,p_payload->>'funding',coalesce(p_payload->>'recipient',''),coalesce(p_payload->>'evidence',''),a.user_id,coalesce(nullif(p_payload->>'date','')::date,current_date)) RETURNING expense_id INTO v_id;
   ELSE
    IF s.enrollment_status<>'FINALIZED' THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
    PERFORM public.tower_task_capture_snapshot_internal(p_service);
    IF p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)=0 THEN RAISE EXCEPTION 'CUSTOM_ZERO_BASE_REQUIRES_NEW_AGREEMENT'; END IF;
    SELECT * INTO ad FROM public.tower_task_adjustments WHERE service_id=p_service AND reference=v_ref;
    IF FOUND THEN
     IF (ad.amount,ad.reason,ad.proposed_by) IS DISTINCT FROM (v_amount,v_reason,a.user_id) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
     RETURN jsonb_build_object('adjustmentId',ad.adjustment_id,'replayed',true);
    END IF;
    INSERT INTO public.tower_task_adjustments(service_id,reference,amount,reason,proposed_by) VALUES(p_service,v_ref,v_amount,v_reason,a.user_id) RETURNING adjustment_id INTO v_id;
    -- Largest-remainder apportionment in integer cents; stable tie-break by unit UUID.
    INSERT INTO public.tower_task_adjustment_lines(adjustment_id,subscription_id,amount)
    WITH weights AS (SELECT x.*,CASE WHEN p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)>0 THEN original_amount ELSE 1 END weight,sum(CASE WHEN p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)>0 THEN original_amount ELSE 1 END) OVER() total FROM public.tower_task_allocation_snapshots x WHERE service_id=p_service),
    raw AS (SELECT *,abs(v_amount)*100*weight/total exact_cents FROM weights),
    ranked AS (SELECT *,floor(exact_cents) base,row_number() OVER(ORDER BY exact_cents-floor(exact_cents) DESC,unit_id) rn,
       abs(v_amount)*100-sum(floor(exact_cents)) OVER() extras FROM raw)
    SELECT v_id,subscription_id,sign(v_amount)*(base+CASE WHEN rn<=extras THEN 1 ELSE 0 END)/100 FROM ranked
    WHERE base+CASE WHEN rn<=extras THEN 1 ELSE 0 END>0;
   END IF;
  ELSIF p_action IN ('expense_cancel','adjustment_cancel') THEN
   IF p_action='expense_cancel' THEN
    UPDATE public.tower_task_expenses SET state='CANCELLED' WHERE expense_id=(p_payload->>'expenseId')::uuid AND service_id=p_service AND state='DRAFT';
   ELSE
    UPDATE public.tower_task_adjustments SET state='CANCELLED' WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND service_id=p_service AND state='DRAFT';
   END IF;
   IF NOT FOUND THEN RAISE EXCEPTION 'ONLY_DRAFT_CAN_BE_CANCELLED'; END IF;
  ELSIF p_action IN ('expense_approve','expense_pay') THEN
   SELECT * INTO e FROM public.tower_task_expenses WHERE expense_id=(p_payload->>'expenseId')::uuid AND service_id=p_service FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
   IF p_action='expense_approve' AND e.state='APPROVED' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF p_action='expense_pay' AND EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements WHERE expense_id=e.expense_id) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF e.state='CANCELLED' THEN RAISE EXCEPTION 'EXPENSE_CANCELLED'; END IF;
   IF p_action='expense_pay' AND e.state<>'APPROVED' THEN RAISE EXCEPTION 'EXPENSE_NOT_APPROVED'; END IF;
   v_deferred_pay:=e.funding='TASK' AND p_action='expense_approve' AND e.recorded_by<>a.user_id AND EXISTS(SELECT 1 FROM public.tower_users WHERE user_id=e.recorded_by AND role NOT IN ('ADMIN','UNION'));
   IF p_action='expense_pay' AND e.funding='TASK' AND e.recorded_by<>a.user_id THEN RAISE EXCEPTION 'ONLY_RECORDED_HOLDER_CAN_CONFIRM_EXPENSE'; END IF;
   IF e.funding='TASK' AND p_action='expense_approve' AND e.recorded_by<>a.user_id AND NOT v_deferred_pay THEN RAISE EXCEPTION 'ONLY_RECORDED_HOLDER_CAN_CONFIRM_EXPENSE'; END IF;
   IF (e.funding='TASK' OR p_action='expense_pay') AND NOT v_deferred_pay THEN
    IF e.amount>public.tower_finance_holder_available_internal(v_account,a.user_id) THEN RAISE EXCEPTION 'INSUFFICIENT_HOLDER_BALANCE'; END IF;
    INSERT INTO public.tower_task_expense_disbursements(expense_id,account_id,holder_id,amount) VALUES(e.expense_id,v_account,a.user_id,e.amount);
   END IF;
   UPDATE public.tower_task_expenses SET state='APPROVED',approved_by=coalesce(approved_by,a.user_id),
    paid_by=CASE WHEN funding='PERSONAL' THEN recorded_by WHEN (funding='TASK' OR p_action='expense_pay') AND NOT v_deferred_pay THEN a.user_id ELSE NULL END,
    paid_at=CASE WHEN (funding IN ('PERSONAL','TASK') OR p_action='expense_pay') AND NOT v_deferred_pay THEN now() ELSE NULL END WHERE expense_id=e.expense_id;
  ELSIF p_action='adjustment_approve' THEN
   SELECT * INTO ad FROM public.tower_task_adjustments WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND service_id=p_service FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'ADJUSTMENT_NOT_FOUND'; END IF;
   IF ad.state='CANCELLED' THEN RAISE EXCEPTION 'ADJUSTMENT_CANCELLED'; END IF;
   IF ad.state='APPROVED' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF ad.amount<0 AND a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   FOR v_row IN SELECT l.*,sn.unit_id FROM public.tower_task_adjustment_lines l JOIN public.tower_task_allocation_snapshots sn ON sn.service_id=p_service AND sn.subscription_id=l.subscription_id WHERE l.adjustment_id=ad.adjustment_id ORDER BY sn.unit_id LOOP
    IF v_row.amount>0 THEN
     v_remaining:=v_row.amount;
     -- Consume outstanding credit before recreating any collectible debt.
     FOR v_data IN SELECT jsonb_build_object('dueId',d.due_id,'amount',least(d.amount-public.tower_task_due_amount_internal(d.due_id),greatest(0,public.tower_task_due_paid_internal(d.due_id)-public.tower_task_due_amount_internal(d.due_id))))
       FROM public.tower_finance_dues d WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date,due_id LOOP
      v_take:=least(v_remaining,(v_data->>'amount')::numeric);
      IF v_take>0 THEN INSERT INTO public.tower_task_credit_reversals(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take);v_remaining:=v_remaining-v_take; END IF;
      EXIT WHEN v_remaining=0;
     END LOOP;
     IF v_remaining>0 THEN
      FOR v_data IN SELECT jsonb_build_object('dueId',d.due_id,'amount',d.amount-public.tower_task_due_amount_internal(d.due_id)) FROM public.tower_finance_dues d WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date,due_id LOOP
       v_take:=least(v_remaining,(v_data->>'amount')::numeric);
       IF v_take>0 THEN INSERT INTO public.tower_task_credit_reversals(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take) ON CONFLICT(adjustment_id,due_id) DO UPDATE SET amount=tower_task_credit_reversals.amount+excluded.amount;v_remaining:=v_remaining-v_take; END IF;
       EXIT WHEN v_remaining=0;
      END LOOP;
     END IF;
     IF v_remaining>0 THEN
      INSERT INTO public.tower_finance_dues(unit_id,account_id,subscription_id,due_date,amount,status,task_adjustment_id) VALUES(v_row.unit_id,v_account,v_row.subscription_id,current_date,v_remaining,'OPEN',ad.adjustment_id) RETURNING due_id INTO v_due;
      UPDATE public.tower_task_adjustment_lines SET due_id=v_due WHERE adjustment_id=ad.adjustment_id AND subscription_id=v_row.subscription_id;
     END IF;
     -- Apply eligible advances through the existing attribution-aware internal routine.
     PERFORM public.tower_finance_apply_advances_internal(v_row.unit_id,v_account);
    ELSE
     v_remaining:=-v_row.amount;
     IF v_remaining>(SELECT coalesce(sum(public.tower_task_due_amount_internal(due_id)),0) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN') THEN RAISE EXCEPTION 'CREDIT_EXCEEDS_APPROVED_DUES'; END IF;
     -- First reduce unpaid debt, then record credit against amounts already paid.
     FOR v_data IN SELECT jsonb_build_object('dueId',due_id,'amount',greatest(0,public.tower_task_due_amount_internal(due_id)-public.tower_task_due_paid_internal(due_id))) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date DESC,due_id DESC LOOP
      v_take:=least(v_remaining,(v_data->>'amount')::numeric);
      IF v_take>0 THEN INSERT INTO public.tower_task_due_credits(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take);v_remaining:=v_remaining-v_take; END IF;
      EXIT WHEN v_remaining=0;
     END LOOP;
     IF v_remaining>0 THEN
      FOR v_data IN SELECT jsonb_build_object('dueId',due_id,'amount',public.tower_task_due_amount_internal(due_id)) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date DESC,due_id DESC LOOP
       v_take:=least(v_remaining,(v_data->>'amount')::numeric);
       IF v_take>0 THEN INSERT INTO public.tower_task_due_credits(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take) ON CONFLICT(adjustment_id,due_id) DO UPDATE SET amount=tower_task_due_credits.amount+excluded.amount;v_remaining:=v_remaining-v_take; END IF;
       EXIT WHEN v_remaining=0;
      END LOOP;
     END IF;
    END IF;
   END LOOP;
   UPDATE public.tower_task_adjustments SET state='APPROVED',approved_by=a.user_id,approved_at=now() WHERE adjustment_id=ad.adjustment_id;
  ELSIF p_action='refund_authorize' THEN
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   v_sub:=(p_payload->>'subscriptionId')::uuid;
   IF NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND subscription_id=v_sub) THEN RAISE EXCEPTION 'SUBSCRIPTION_SCOPE_MISMATCH'; END IF;
   v_current:=public.tower_task_subscription_balance_internal(v_sub);
   v_amount:=CASE WHEN coalesce(p_payload->>'source','DUE_CREDIT')='ADVANCE' THEN (v_current->>'advanceAvailable')::numeric ELSE (v_current->>'creditAvailable')::numeric END;
   IF v_amount<=0 OR EXISTS(SELECT 1 FROM public.tower_finance_refund_authorizations WHERE subscription_id=v_sub AND authorization_status='APPROVED' AND max_amount>coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=tower_finance_refund_authorizations.refund_authorization_id AND m.movement_status='CONFIRMED'),0)) THEN RAISE EXCEPTION 'REFUND_UNAVAILABLE_OR_ALREADY_AUTHORIZED'; END IF;
   SELECT unit_id INTO v_unit FROM public.tower_service_subscriptions WHERE subscription_id=v_sub;
   INSERT INTO public.tower_finance_refund_authorizations(unit_id,account_id,subscription_id,max_amount,approved_by,effective_date)
    VALUES(v_unit,v_account,v_sub,v_amount,a.user_id,current_date) RETURNING refund_authorization_id INTO v_authorization;
   IF coalesce(p_payload->>'source','DUE_CREDIT') NOT IN ('DUE_CREDIT','ADVANCE') THEN RAISE EXCEPTION 'INVALID_REFUND_SOURCE'; END IF;
   INSERT INTO public.tower_task_credit_refunds(authorization_id,service_id,refund_source) VALUES(v_authorization,p_service,coalesce(p_payload->>'source','DUE_CREDIT'));
   IF p_payload->>'source'='ADVANCE' THEN
    v_remaining:=v_amount;
    FOR v_row IN SELECT l.link_id,l.advance_application_id,l.amount-coalesce((SELECT sum(au.amount) FROM public.tower_finance_advance_use_subscriptions x JOIN public.tower_finance_advance_uses au ON au.use_id=x.use_id WHERE x.link_id=l.link_id),0)-coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.link_id=l.link_id),0) available
     FROM public.tower_finance_advance_subscription_links l JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id JOIN public.tower_finance_receipts rr ON rr.receipt_id=rp.receipt_id AND rr.receipt_status='POSTED' WHERE l.subscription_id=v_sub ORDER BY l.linked_at,l.link_id LOOP
     v_take:=least(v_remaining,greatest(0,v_row.available));
     IF v_take>0 THEN INSERT INTO public.tower_task_advance_refund_allocations(authorization_id,link_id,advance_application_id,amount) VALUES(v_authorization,v_row.link_id,v_row.advance_application_id,v_take);v_remaining:=v_remaining-v_take; END IF;
     EXIT WHEN v_remaining=0;
    END LOOP;
    IF v_remaining<>0 THEN RAISE EXCEPTION 'ADVANCE_REFUND_SCOPE_MISMATCH'; END IF;
   END IF;
  ELSIF p_action='refund_request' THEN
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   SELECT ra.refund_authorization_id,ra.unit_id,ra.subscription_id INTO v_authorization,v_unit,v_sub
    FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds tr ON tr.authorization_id=ra.refund_authorization_id
    WHERE tr.service_id=p_service AND ra.refund_authorization_id=(p_payload->>'authorizationId')::uuid AND ra.authorization_status='APPROVED';
   IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.sender_user_id=a.user_id AND m.movement_status IN ('PENDING','DISPUTED')) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF (SELECT count(*) FROM public.tower_members mb JOIN public.tower_users us ON us.user_id=mb.user_id AND us.role='RESIDENT' AND us.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
   SELECT mb.user_id INTO v_manager FROM public.tower_members mb JOIN public.tower_users usr ON usr.user_id=mb.user_id AND usr.role='RESIDENT' AND usr.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL;
   v_current:=public.tower_task_subscription_balance_internal(v_sub);
   v_amount:=least(CASE WHEN (SELECT refund_source FROM public.tower_task_credit_refunds WHERE authorization_id=v_authorization)='ADVANCE' THEN (SELECT max_amount FROM public.tower_finance_refund_authorizations WHERE refund_authorization_id=v_authorization) ELSE (v_current->>'creditAvailable')::numeric END,(SELECT max_amount FROM public.tower_finance_refund_authorizations WHERE refund_authorization_id=v_authorization)
     -coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')),0));
   PERFORM public.tower_finance_request_unit_refund_internal(v_authorization,a.user_id,v_manager,v_amount);
  ELSIF p_action IN ('cancel_refund','revoke_refund') THEN
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   IF p_action='cancel_refund' THEN
    IF NOT EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE rm.movement_id=(p_payload->>'movementId')::uuid AND cr.service_id=p_service) THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
    v_data:=public.tower_finance_refund_action(p_token,'cancel',jsonb_build_object('movementId',p_payload->>'movementId'));
   ELSE
    v_authorization:=(p_payload->>'authorizationId')::uuid;
    IF NOT EXISTS(SELECT 1 FROM public.tower_task_credit_refunds WHERE authorization_id=v_authorization AND service_id=p_service) THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')) THEN RAISE EXCEPTION 'REFUND_ALREADY_IN_PROGRESS'; END IF;
    UPDATE public.tower_finance_refund_authorizations SET authorization_status='REVOKED' WHERE refund_authorization_id=v_authorization;
   END IF;
  ELSIF p_action IN ('close_financial','cancel_settled') THEN
   IF p_action='cancel_settled' AND (a.role NOT IN ('ADMIN','UNION') OR length(btrim(coalesce(p_payload->>'reason','')))=0) THEN RAISE EXCEPTION 'UNION_CANCELLATION_REASON_REQUIRED'; END IF;
   IF p_action='close_financial' AND NOT EXISTS(SELECT 1 FROM public.tower_task_workflow WHERE service_id=p_service AND stage='COMPLETED') THEN RAISE EXCEPTION 'EXECUTION_NOT_COMPLETED'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_fund_contributions fc WHERE fc.service_id=p_service AND NOT EXISTS(SELECT 1 FROM public.tower_task_fund_receipts fr WHERE fr.service_id=fc.service_id AND fr.amount=fc.amount AND fr.account_id=v_account)) THEN RAISE EXCEPTION 'FUND_CONTRIBUTION_RECEIPT_PENDING'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND
     ((public.tower_task_subscription_balance_internal(sub.subscription_id)->>'remaining')::numeric>0 OR (public.tower_task_subscription_balance_internal(sub.subscription_id)->>'credit')::numeric>0)) THEN RAISE EXCEPTION 'UNSETTLED_UNIT_BALANCES'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_expenses ex WHERE ex.service_id=p_service AND ex.state<>'CANCELLED' AND (ex.state='DRAFT' OR NOT EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements d WHERE d.expense_id=ex.expense_id))) THEN RAISE EXCEPTION 'UNSETTLED_EXPENSES'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_donation_returns WHERE account_id=v_account AND state='PENDING') THEN RAISE EXCEPTION 'PENDING_DONATION_RETURN'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_finance_cash_movements WHERE account_id=v_account AND movement_status IN ('PENDING','DISPUTED')) THEN RAISE EXCEPTION 'PENDING_CASH_MOVEMENTS'; END IF;
   FOR v_row IN SELECT DISTINCT user_id FROM public.tower_users WHERE user_id IN (
    SELECT r.collector_id FROM public.tower_finance_receipts r JOIN public.tower_finance_receipt_portions rp ON rp.receipt_id=r.receipt_id WHERE rp.account_id=v_account
    UNION SELECT confirmed_by FROM public.tower_task_fund_receipts WHERE account_id=v_account
    UNION SELECT recipient_user_id FROM public.tower_finance_cash_movements WHERE account_id=v_account AND movement_status='CONFIRMED') LOOP
    IF public.tower_finance_holder_available_internal(v_account,v_row.user_id)<>0 THEN RAISE EXCEPTION 'UNSETTLED_CUSTODY'; END IF;
   END LOOP;
   IF EXISTS(SELECT 1 FROM public.tower_finance_applications ap JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id
     WHERE rp.account_id=v_account AND r.receipt_status='POSTED' AND ap.application_kind='ADVANCE' AND NOT EXISTS(SELECT 1 FROM public.tower_task_donations dn WHERE dn.application_id=ap.application_id) AND ap.amount>coalesce((SELECT sum(au.amount) FROM public.tower_finance_advance_uses au WHERE au.advance_application_id=ap.application_id),0)+coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id WHERE al.advance_application_id=ap.application_id AND ra.max_amount<=coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id AND m.movement_status='CONFIRMED' WHERE rm.refund_authorization_id=ra.refund_authorization_id),0)),0)) THEN RAISE EXCEPTION 'UNSETTLED_ADVANCES'; END IF;
   UPDATE public.tower_task_projects SET phase=CASE WHEN p_action='cancel_settled' THEN 'CANCELLED' ELSE 'FINANCIAL_CLOSED' END,closure_note=CASE WHEN p_action='cancel_settled' THEN left(p_payload->>'reason',4000) ELSE 'انتهاء التنفيذ وتسوية الحساب' END WHERE service_id=p_service;
  ELSE RAISE EXCEPTION 'INVALID_TASK_ACTION'; END IF;
 END IF;
 IF p_action IN ('adjustment_approve','finalize','terms') THEN PERFORM public.tower_task_recompute_ready_213(p_service); END IF;
 UPDATE public.tower_task_projects SET version=version+1,updated_by=a.user_id,updated_at=now() WHERE service_id=p_service;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_PROJECT_'||upper(p_action),'SERVICE',p_service::text);
 RETURN jsonb_build_object('success',true,'serviceId',p_service,'expenseId',CASE WHEN p_action='expense_draft' THEN v_id ELSE NULL END,'adjustmentId',CASE WHEN p_action='adjustment_draft' THEN v_id ELSE NULL END);
END $f$;

CREATE OR REPLACE FUNCTION public.tower_finance_personal_receipt_action(p_token text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users%ROWTYPE;
 v_unit uuid;
 v_amount numeric(16,2);
 v_ref text;
 v_portions jsonb;
 v_expected jsonb;
 v_existing jsonb;
 v_receipt public.tower_finance_receipts%ROWTYPE;
 v_id uuid;
 v_item jsonb;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin THEN
  RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN
 IF jsonb_typeof(p_payload->'portions')<>'array' OR jsonb_array_length(p_payload->'portions')<>1 THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_finance_accounts ac WHERE ac.account_id=(p_payload#>>'{portions,0,account_id}')::uuid AND public.tower_task_responsible_236(v_actor.user_id,ac.service_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
  RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_payload) AS k(key)
   WHERE k.key NOT IN ('unitId','amount','portions','externalReference')) THEN
  RAISE EXCEPTION 'INVALID_RECEIPT_FIELDS'; END IF;
 IF coalesce(p_payload->>'unitId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
  OR coalesce(p_payload->>'amount','') !~ '^([0-9]+)(\.[0-9]{1,2})?$'
  OR jsonb_typeof(p_payload->'portions')<>'array'
  OR jsonb_array_length(p_payload->'portions')=0
 THEN RAISE EXCEPTION 'INVALID_RECEIPT_FIELDS'; END IF;
 v_ref:=btrim(coalesce(p_payload->>'externalReference',''));
 IF length(v_ref)<16 OR length(v_ref)>128 THEN RAISE EXCEPTION 'RECEIPT_REFERENCE_REQUIRED'; END IF;
 v_unit:=(p_payload->>'unitId')::uuid;
 v_amount:=(p_payload->>'amount')::numeric;
 IF v_amount<=0 THEN RAISE EXCEPTION 'INVALID_RECEIPT_AMOUNT'; END IF;
 v_portions:=p_payload->'portions';
 -- Strict canonical shape; rejects accidental extra keys and duplicate account IDs.
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_portions) x(value)
   WHERE jsonb_typeof(x.value)<>'object'
   OR NOT (x.value ? 'account_id' AND x.value ? 'amount')
   OR (SELECT count(*) FROM jsonb_object_keys(x.value))<>2
   OR coalesce(x.value->>'account_id','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
   OR coalesce(x.value->>'amount','') !~ '^([0-9]+)(\.[0-9]{1,2})?$'
   OR (x.value->>'amount')::numeric<=0)
 THEN RAISE EXCEPTION 'INVALID_PORTION'; END IF;
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_portions) x(value)
   GROUP BY lower(x.value->>'account_id') HAVING count(*)>1)
 THEN RAISE EXCEPTION 'DUPLICATE_ACCOUNT'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'account_id', (x.value->>'account_id')::uuid,
   'amount', (x.value->>'amount')::numeric) ORDER BY x.value->>'account_id'),'[]'::jsonb)
 INTO v_expected FROM jsonb_array_elements(v_portions) x(value);
 IF (SELECT sum((x.value->>'amount')::numeric) FROM jsonb_array_elements(v_portions) x(value))<>v_amount
 THEN RAISE EXCEPTION 'RECEIPT_SUM_MISMATCH'; END IF;
 -- Serialize requests for the same upstream collection event (even concurrent retries).
 PERFORM pg_advisory_xact_lock(hashtextextended('personal-receipt:'||v_ref,0));
 SELECT * INTO v_receipt FROM public.tower_finance_receipts
  WHERE btrim(external_reference)=v_ref AND receipt_status IN ('POSTED','REVERSED') FOR UPDATE;
 IF FOUND THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('account_id',rp.account_id,'amount',rp.amount)
    ORDER BY rp.account_id),'[]'::jsonb) INTO v_existing
  FROM public.tower_finance_receipt_portions rp WHERE rp.receipt_id=v_receipt.receipt_id;
  IF v_receipt.unit_id<>v_unit OR v_receipt.collector_id<>v_actor.user_id
    OR v_receipt.amount<>v_amount OR v_expected<>v_existing
  THEN RAISE EXCEPTION 'RECEIPT_REFERENCE_CONFLICT'; END IF;
  IF v_receipt.receipt_status<>'POSTED' THEN RAISE EXCEPTION 'RECEIPT_ALREADY_REVERSED'; END IF;
  RETURN jsonb_build_object('receiptId',v_receipt.receipt_id,'status','POSTED','replayed',true);
 END IF;
 -- Identity is NEVER supplied by client. Allocation and inserts are one SQL transaction.
 v_id:=public.tower_finance_post_personal_receipt_internal(
   v_unit,v_actor.user_id,v_amount,v_portions,v_ref);
 RETURN jsonb_build_object('receiptId',v_id,'status','POSTED','replayed',false);
END; $function$
;

CREATE OR REPLACE FUNCTION public.tower_finance_refund_action(p_token text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users%ROWTYPE;
 v_m public.tower_finance_cash_movements%ROWTYPE;
 v_id uuid;
 v_status text;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin THEN
  RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
  RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action NOT IN ('confirm','cancel') OR p_action IS NULL THEN
  RAISE EXCEPTION 'REFUND_REQUEST_REQUIRES_TRUSTED_ELIGIBILITY'; END IF;
 IF coalesce(p_payload->>'movementId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN
  RAISE EXCEPTION 'INVALID_MOVEMENT_ID'; END IF;
 v_id:=(p_payload->>'movementId')::uuid;
 -- Primitives acquire account/movement locks and recheck pending state atomically.
 SELECT * INTO v_m FROM public.tower_finance_cash_movements WHERE movement_id=v_id;
 IF NOT FOUND OR v_m.movement_kind<>'UNIT_REFUND' THEN
  RAISE EXCEPTION 'REFUND_MOVEMENT_NOT_FOUND'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.tower_finance_refund_movements
   WHERE movement_id=v_id) THEN RAISE EXCEPTION 'REFUND_APPROVAL_LINK_MISSING'; END IF;
 IF p_action='confirm' THEN
  IF v_actor.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF v_m.recipient_user_id<>v_actor.user_id THEN RAISE EXCEPTION 'REFUND_ONLY_DESIGNATED_MANAGER'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tower_members m
   WHERE m.user_id=v_actor.user_id AND m.unit_id=v_m.unit_id
    AND m.member_role='MANAGER' AND m.ended_at IS NULL)
  THEN RAISE EXCEPTION 'REFUND_ONLY_CURRENT_UNIT_MANAGER'; END IF;
  -- Do not confirm while multiple active managers make unit authority ambiguous.
  IF (SELECT count(*) FROM public.tower_members m
      JOIN public.tower_users u ON u.user_id=m.user_id
      WHERE m.unit_id=v_m.unit_id AND m.member_role='MANAGER'
       AND m.ended_at IS NULL AND u.role='RESIDENT' AND u.status='ACTIVE')<>1
  THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
  v_status:=public.tower_finance_confirm_unit_refund_internal(v_id,v_actor.user_id);
 ELSE
  IF v_actor.role NOT IN ('UNION','OPERATOR') AND NOT (v_actor.role='ADMIN' AND EXISTS(SELECT 1 FROM public.tower_finance_accounts WHERE account_id=v_m.account_id AND account_kind='PERSONAL_SERVICE')) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF v_m.sender_user_id<>v_actor.user_id THEN RAISE EXCEPTION 'REFUND_ONLY_SENDER_CAN_CANCEL'; END IF;
  v_status:=public.tower_finance_cancel_unit_refund_internal(v_id,v_actor.user_id);
 END IF;
 RETURN jsonb_build_object('movementId',v_id,'status',v_status);
END; $function$
;

CREATE OR REPLACE FUNCTION public.tower_personal_collections_230(p_token text,p_action text DEFAULT 'read',p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;unit uuid;account uuid;amount numeric;remaining numeric;ret jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='collect' THEN
  IF actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  unit:=(p_payload->>'unitId')::uuid;account:=(p_payload->>'accountId')::uuid;
  IF coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_RECEIPT_AMOUNT'; END IF;
  amount:=(p_payload->>'amount')::numeric;
  PERFORM 1 FROM public.tower_units WHERE unit_id=unit AND status='ACTIVE' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_NOT_FOUND'; END IF;
  -- The underlying receipt wrapper checks replay before reallocating. Never reject a valid retry against a now-reduced balance.
  IF NOT EXISTS(SELECT 1 FROM public.tower_finance_receipts WHERE external_reference=p_payload->>'reference') THEN
   SELECT coalesce(sum(greatest(public.tower_task_due_amount_internal(d.due_id)-public.tower_task_due_paid_internal(d.due_id),0)),0) INTO remaining
   FROM public.tower_finance_dues d JOIN public.tower_finance_accounts a ON a.account_id=d.account_id AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE'
   WHERE d.unit_id=unit AND d.account_id=account AND d.status='OPEN';
   IF amount<=0 OR amount>remaining THEN RAISE EXCEPTION 'COLLECTION_EXCEEDS_REMAINING'; END IF;
  END IF;
  RETURN public.tower_finance_personal_receipt_action(p_token,jsonb_build_object('unitId',unit,'amount',p_payload->>'amount','externalReference',p_payload->>'reference','portions',jsonb_build_array(jsonb_build_object('account_id',account,'amount',p_payload->>'amount'))));
 ELSIF p_action<>'read' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x."unitNumber",x."serviceName"),'[]') INTO ret FROM (
 SELECT d.unit_id "unitId",a.account_id "accountId",s.service_id "serviceId",s.name "serviceName",un.unit_number "unitNumber",un.floor,a.status "accountStatus",un.status "unitStatus",
 (SELECT us.name FROM public.tower_members m JOIN public.tower_users us ON us.user_id=m.user_id WHERE m.unit_id=un.unit_id AND m.member_role='MANAGER' AND m.ended_at IS NULL ORDER BY us.user_id LIMIT 1) "managerName",
 sum(public.tower_task_due_amount_internal(d.due_id)) due,sum(public.tower_task_due_paid_internal(d.due_id)) paid,
 sum(greatest(public.tower_task_due_amount_internal(d.due_id)-public.tower_task_due_paid_internal(d.due_id),0)) remaining
 FROM public.tower_finance_dues d JOIN public.tower_finance_accounts a ON a.account_id=d.account_id AND a.account_kind='PERSONAL_SERVICE'
 JOIN public.tower_services s ON s.service_id=a.service_id JOIN public.tower_units un ON un.unit_id=d.unit_id
 WHERE d.status='OPEN' GROUP BY d.unit_id,a.account_id,s.service_id,un.unit_id
 HAVING sum(greatest(public.tower_task_due_amount_internal(d.due_id)-public.tower_task_due_paid_internal(d.due_id),0))>0
 ) x;
 RETURN jsonb_build_object('rows',ret,'canCollect',actor.role IN ('ADMIN','UNION','OPERATOR'));
END $f$;

CREATE OR REPLACE FUNCTION public.tower_task_workflow_action(p_token text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor public.tower_users; v_service public.tower_services; v_id uuid; v_w public.tower_task_workflow; v_data jsonb; v_rows jsonb; v_admin boolean;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status <> 'ACTIVE' OR v_actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 v_admin := v_actor.role IN ('ADMIN','UNION');
 IF p_action='list' THEN
  IF NOT v_admin AND v_actor.role<>'RESIDENT' AND NOT EXISTS(SELECT 1 FROM public.tower_finance_accounts ac WHERE public.tower_task_responsible_236(v_actor.user_id,ac.service_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
     'serviceId',s.service_id,'stage',coalesce(w.stage,CASE WHEN s.enrollment_status='OPEN' THEN 'COLLECT_SUBSCRIBERS' ELSE 'COLLECT_FUNDS' END),
     'executionDate',w.execution_date,'startRule',coalesce(w.start_rule,'MANUAL'),
     'collectionThreshold',coalesce(w.collection_threshold,100),'executionPercent',coalesce(w.execution_percent,0),
     'installmentCount',coalesce(w.installment_count,1),'firstDueDate',w.first_due_date,
     'fundContributionProposed',coalesce(w.fund_contribution_proposed,0),
     'revision',coalesce(w.revision,0),
     'collected',coalesce(fin.collected,0),'approvedDues',coalesce(fin.due_total,0),
     'fundContributionPosted',coalesce((SELECT c.amount FROM public.tower_task_fund_contributions c WHERE c.service_id=s.service_id),0),
     'minimumStartAmount',coalesce((SELECT minimum_start_amount FROM public.tower_task_projects WHERE service_id=s.service_id),0),
     'adjustmentsTotal',coalesce((SELECT sum(amount) FROM public.tower_task_adjustments WHERE service_id=s.service_id AND state='APPROVED'),0),
     'financialNote','مساهمة الصندوق المقترحة لا تدخل في التحصيل إلا بعد تنفيذ تحويل مالي موثق') ORDER BY s.name),'[]'::jsonb)
   INTO v_rows
   FROM public.tower_services s
   LEFT JOIN public.tower_task_workflow w ON w.service_id=s.service_id
   LEFT JOIN LATERAL (
      SELECT coalesce(sum(public.tower_task_due_amount_internal(d.due_id)),0) due_total,
      coalesce(sum(least(public.tower_task_due_amount_internal(d.due_id),public.tower_task_due_paid_internal(d.due_id))),0) collected
      FROM public.tower_finance_dues d
      JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
      WHERE sub.service_id=s.service_id AND d.status='OPEN'
   ) fin ON true
   WHERE s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL' AND (v_actor.role<>'OPERATOR' OR public.tower_task_responsible_236(v_actor.user_id,s.service_id))
     AND (v_admin OR EXISTS(
       SELECT 1 FROM public.tower_members m JOIN public.tower_service_subscriptions ss ON ss.unit_id=m.unit_id
       WHERE m.user_id=v_actor.user_id AND m.ended_at IS NULL AND ss.service_id=s.service_id
     ) OR s.status='ACTIVE');
  RETURN v_rows;
 END IF;
 IF NOT v_admin THEN
 IF NOT public.tower_task_responsible_236(v_actor.user_id,(p_payload->>'serviceId')::uuid) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_task_workflow w WHERE w.service_id=(p_payload->>'serviceId')::uuid AND (w.start_rule,w.execution_date,w.collection_threshold,w.installment_count,w.first_due_date,w.fund_contribution_proposed) IS DISTINCT FROM (p_payload->>'startRule',nullif(p_payload->>'executionDate','')::date,(p_payload->>'collectionThreshold')::integer,(p_payload->>'installmentCount')::integer,nullif(p_payload->>'firstDueDate','')::date,(p_payload->>'fundContributionProposed')::numeric)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_task_workflow WHERE service_id=(p_payload->>'serviceId')::uuid) AND (p_payload->>'startRule'<>'MANUAL' OR coalesce(p_payload->>'executionDate','')<>'' OR (p_payload->>'collectionThreshold')::int<>100 OR (p_payload->>'installmentCount')::int<>1 OR coalesce(p_payload->>'firstDueDate','')<>'' OR (p_payload->>'fundContributionProposed')::numeric<>0) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 END IF;
 IF p_action<>'save' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 BEGIN v_id:=(p_payload->>'serviceId')::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'INVALID_SERVICE_ID'; END;
 SELECT * INTO v_service FROM public.tower_services WHERE service_id=v_id FOR UPDATE;
 IF NOT FOUND OR v_service.service_kind<>'ONE_TIME' OR v_service.pricing_mode<>'SHARED_TOTAL' THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 IF (p_payload->>'stage') NOT IN ('COLLECT_SUBSCRIBERS','COLLECT_FUNDS','READY','IN_PROGRESS','COMPLETED') THEN RAISE EXCEPTION 'INVALID_STAGE'; END IF;
 IF v_service.enrollment_status<>'OPEN' AND p_payload->>'stage'='COLLECT_SUBSCRIBERS' THEN RAISE EXCEPTION 'ENROLLMENT_NOT_OPEN'; END IF;
 IF v_service.enrollment_status<>'FINALIZED' AND p_payload->>'stage' IN ('READY','IN_PROGRESS','COMPLETED') THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
 IF coalesce((p_payload->>'executionPercent')::int,-1) NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'INVALID_EXECUTION_PERCENT'; END IF;
 IF coalesce((p_payload->>'installmentCount')::int,-1) NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'INVALID_INSTALLMENTS'; END IF;
 IF coalesce((p_payload->>'collectionThreshold')::int,-1) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVALID_THRESHOLD'; END IF;
 IF p_payload->>'startRule' NOT IN ('MANUAL','DATE','COLLECTION','DATE_AND_COLLECTION') THEN RAISE EXCEPTION 'INVALID_START_RULE'; END IF;
 IF (p_payload->>'fundContributionProposed')::numeric < 0 OR (p_payload->>'fundContributionProposed')::numeric > v_service.total_budget THEN RAISE EXCEPTION 'INVALID_FUND_CONTRIBUTION'; END IF;
 IF v_service.enrollment_status='FINALIZED' AND (p_payload->>'fundContributionProposed')::numeric <> coalesce((SELECT fund_contribution_proposed FROM public.tower_task_workflow WHERE service_id=v_id),0) THEN RAISE EXCEPTION 'CONTRIBUTION_LOCKED_AFTER_FINALIZATION'; END IF;
 INSERT INTO public.tower_task_workflow(service_id,stage,execution_date,start_rule,collection_threshold,execution_percent,installment_count,first_due_date,fund_contribution_proposed,updated_by)
 VALUES(v_id,p_payload->>'stage',nullif(p_payload->>'executionDate','')::date,p_payload->>'startRule',(p_payload->>'collectionThreshold')::int,(p_payload->>'executionPercent')::int,(p_payload->>'installmentCount')::int,nullif(p_payload->>'firstDueDate','')::date,(p_payload->>'fundContributionProposed')::numeric,v_actor.user_id)
 ON CONFLICT(service_id) DO UPDATE SET stage=excluded.stage,execution_date=excluded.execution_date,start_rule=excluded.start_rule,
 collection_threshold=excluded.collection_threshold,execution_percent=excluded.execution_percent,installment_count=excluded.installment_count,
 first_due_date=excluded.first_due_date,fund_contribution_proposed=excluded.fund_contribution_proposed,updated_by=v_actor.user_id,
 revision=tower_task_workflow.revision+1,updated_at=now();
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(v_actor.user_id,'UPDATE_TASK_WORKFLOW','SERVICE',v_id::text);
 RETURN jsonb_build_object('success',true,'serviceId',v_id);
END $function$
;

CREATE OR REPLACE FUNCTION public.tower_task_controls_235(p_token text,p_service uuid,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;w public.tower_task_workflow;meta jsonb;plan jsonb;receipt jsonb;patch jsonb;payload jsonb;allowed text[];k text;reason text;first_day date;revision_value integer;had_workflow boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.must_change_pin THEN RAISE EXCEPTION 'PIN_CHANGE_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') AND NOT public.tower_task_responsible_236(a.user_id,p_service) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') AND (p_action='install' OR (p_action='save' AND p_payload->>'section'<>'execution')) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('read','preview','save','install') OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 SELECT * INTO w FROM public.tower_task_workflow WHERE service_id=p_service FOR UPDATE;had_workflow:=FOUND;revision_value:=coalesce(w.revision,0);
 SELECT x INTO meta FROM jsonb_array_elements(public.tower_task_workflow_action(p_token,'list','{}')) x WHERE x->>'serviceId'=p_service::text;
 IF meta IS NULL THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 IF s.enrollment_status<>'OPEN' AND meta->>'stage'='COLLECT_SUBSCRIBERS' THEN meta:=jsonb_set(meta,'{stage}','"COLLECT_FUNDS"'); END IF;
 plan:=public.tower_task_installments_action(p_token,p_service,'list');
 first_day:=(date_trunc('month',now() AT TIME ZONE 'Africa/Cairo')+interval '1 month')::date;
 reason:=CASE WHEN coalesce((plan->>'hasPlan')::boolean,false) THEN 'INSTALLMENT_PLAN_ALREADY_INSTALLED'
  WHEN s.enrollment_status<>'FINALIZED' THEN 'ALLOCATION_NOT_FINALIZED'
  WHEN EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service AND phase IN ('FINANCIAL_CLOSED','CANCELLED')) THEN 'TASK_CLOSED'
  WHEN coalesce((plan->>'noPlanNeeded')::boolean,false) THEN 'NO_APPROVED_DUES'
  WHEN coalesce((plan->>'hasPayments')::boolean,false) THEN 'INSTALLMENTS_REQUIRE_UNPAID_DUES' ELSE NULL END;
 plan:=plan||jsonb_build_object('canInstall',reason IS NULL,'installBlockedReason',reason,'installmentCount',coalesce(w.installment_count,1),'firstDueDate',CASE WHEN coalesce((plan->>'hasPlan')::boolean,false) THEN (SELECT min(i.due_date) FROM public.tower_task_due_installments i JOIN public.tower_finance_dues d ON d.due_id=i.due_id JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service) ELSE first_day END,'revision',revision_value);
 IF p_action='preview' THEN RETURN plan; END IF;
 IF p_action='read' THEN
  IF coalesce((meta->>'fundContributionPosted')::numeric,0)>0 THEN BEGIN receipt:=public.tower_task_fund_receipt_action_217(p_token,p_service,'status'); EXCEPTION WHEN others THEN receipt:=jsonb_build_object('unavailable',true); END; END IF;
  RETURN jsonb_build_object('workflow',meta,'installments',plan,'fundReceipt',receipt);
 END IF;
 IF p_action='install' AND coalesce((plan->>'hasPlan')::boolean,false) THEN RETURN plan||jsonb_build_object('alreadyInstalled',true); END IF;
 IF p_payload->>'expectedRevision' IS NULL OR (p_payload->>'expectedRevision')::integer<>revision_value THEN RAISE EXCEPTION 'TASK_WORKFLOW_CHANGED_REFRESH'; END IF;
 IF p_action='install' THEN
  IF reason IS NOT NULL THEN RAISE EXCEPTION '%',reason; END IF;
  IF p_payload->>'expectedFirstDueDate' IS NULL OR (p_payload->>'expectedFirstDueDate')::date<>first_day THEN RAISE EXCEPTION 'INSTALLMENT_SETUP_CHANGED'; END IF;
  -- Only an uninstalled schedule acquires the automatic date. Existing schedules are immutable.
  INSERT INTO public.tower_task_workflow(service_id,stage,start_rule,collection_threshold,execution_percent,installment_count,first_due_date,fund_contribution_proposed,updated_by)
   VALUES(p_service,'COLLECT_FUNDS','MANUAL',100,0,1,first_day,0,a.user_id)
   ON CONFLICT(service_id) DO UPDATE SET first_due_date=first_day,updated_by=a.user_id,revision=tower_task_workflow.revision+1,updated_at=now();
  -- The original engine splits cents, validates unpaid dues, locks them, and creates no new debt.
  RETURN public.tower_task_installments_action(p_token,p_service,'install');
 END IF;
 IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service AND phase IN ('FINANCIAL_CLOSED','CANCELLED')) THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
 patch:=p_payload->'patch';
 IF jsonb_typeof(patch)<>'object' OR patch='{}'::jsonb THEN RAISE EXCEPTION 'INVALID_TASK_CONTROLS'; END IF;
 allowed:=CASE p_payload->>'section' WHEN 'overview' THEN ARRAY['stage','executionPercent','startRule','executionDate','collectionThreshold','fundContributionProposed'] WHEN 'execution' THEN ARRAY['stage','executionPercent'] WHEN 'start' THEN ARRAY['startRule','executionDate','collectionThreshold'] WHEN 'fund' THEN ARRAY['fundContributionProposed'] WHEN 'installments' THEN ARRAY['installmentCount'] ELSE NULL END;
 IF allowed IS NULL THEN RAISE EXCEPTION 'INVALID_TASK_CONTROLS'; END IF;
 FOR k IN SELECT jsonb_object_keys(patch) LOOP IF NOT(k=ANY(allowed)) THEN RAISE EXCEPTION 'INVALID_TASK_CONTROLS'; END IF; END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_each(patch) j WHERE j.value='null'::jsonb AND j.key<>'executionDate') THEN RAISE EXCEPTION 'INVALID_TASK_CONTROLS'; END IF;
 IF p_payload->>'section'='installments' AND coalesce((plan->>'hasPlan')::boolean,false) THEN RAISE EXCEPTION 'INSTALLMENT_PLAN_ALREADY_INSTALLED'; END IF;
 IF p_payload->>'section'='installments' AND coalesce((plan->>'hasPayments')::boolean,false) THEN RAISE EXCEPTION 'INSTALLMENTS_REQUIRE_UNPAID_DUES'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text(patch) j WHERE j.key IN ('executionPercent','collectionThreshold','installmentCount') AND j.value !~ '^[0-9]+$') THEN RAISE EXCEPTION 'INVALID_TASK_CONTROLS'; END IF;
 IF patch ? 'fundContributionProposed' AND ((patch->>'fundContributionProposed') !~ '^[0-9]+(\.[0-9]{1,2})?$') THEN RAISE EXCEPTION 'INVALID_FUND_CONTRIBUTION'; END IF;
 payload:=meta||patch||jsonb_build_object('serviceId',p_service);
 IF payload->>'startRule' IN ('DATE','DATE_AND_COLLECTION') AND nullif(payload->>'executionDate','') IS NULL THEN RAISE EXCEPTION 'EXECUTION_DATE_REQUIRED'; END IF;
 PERFORM public.tower_task_workflow_action(p_token,'save',payload);
 IF NOT had_workflow THEN UPDATE public.tower_task_workflow SET revision=1 WHERE service_id=p_service; END IF;
 SELECT revision INTO revision_value FROM public.tower_task_workflow WHERE service_id=p_service;
 RETURN jsonb_build_object('success',true,'revision',revision_value);
END $f$;

-- Delegated membership changes create no dues; final distribution stays administrative.
CREATE OR REPLACE FUNCTION public.tower_task_installments_action(p_token text,p_service_id uuid,p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;v_due_record record;v_count int;v_first date;v_installment int;cents bigint;v_part numeric;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION','RESIDENT') AND NOT public.tower_task_responsible_236(a.user_id,p_service_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('list','install') THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=p_service_id AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL') THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 IF a.role='RESIDENT' AND NOT public.tower_task_responsible_236(a.user_id,p_service_id) AND NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_service_subscriptions s ON s.unit_id=m.unit_id WHERE m.user_id=a.user_id AND m.ended_at IS NULL AND s.service_id=p_service_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='install' THEN
  IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  PERFORM 1 FROM public.tower_services WHERE service_id=p_service_id AND enrollment_status='FINALIZED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service_id AND phase='FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
  SELECT installment_count,first_due_date INTO v_count,v_first FROM public.tower_task_workflow WHERE service_id=p_service_id;
  IF v_first IS NULL THEN RAISE EXCEPTION 'INSTALLMENT_START_DATE_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND d.status='OPEN' AND public.tower_task_due_amount_internal(d.due_id)>0) THEN RAISE EXCEPTION 'NO_APPROVED_DUES'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues d ON d.due_id=i.due_id JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id) THEN RAISE EXCEPTION 'INSTALLMENT_PLAN_ALREADY_INSTALLED'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id AND public.tower_task_due_paid_internal(d.due_id)>0) THEN RAISE EXCEPTION 'INSTALLMENTS_REQUIRE_UNPAID_DUES'; END IF;
  FOR v_due_record IN SELECT d.* FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id AND d.status='OPEN' ORDER BY d.due_id FOR UPDATE OF d LOOP
   cents:=round(public.tower_task_due_amount_internal(v_due_record.due_id)*100)::bigint;
   IF cents=0 THEN CONTINUE; END IF;
   IF cents<v_count THEN RAISE EXCEPTION 'INSTALLMENTS_EXCEED_AMOUNT_CENTS'; END IF;
   FOR v_installment IN 1..v_count LOOP
    v_part:=((cents/v_count)+CASE WHEN v_installment<=cents%v_count THEN 1 ELSE 0 END)::numeric/100;
    INSERT INTO public.tower_task_due_installments(due_id,installment_no,due_date,amount) VALUES(v_due_record.due_id,v_installment,(v_first+make_interval(months=>v_installment-1))::date,v_part);
   END LOOP;
  END LOOP;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'INSTALL_TASK_DUE_SCHEDULE','SERVICE',p_service_id::text);
 END IF;
 WITH dues AS (
 SELECT d.*,public.tower_task_due_amount_internal(d.due_id) effective,public.tower_task_due_paid_internal(d.due_id) paid
 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
 WHERE sub.service_id=p_service_id AND d.status='OPEN' AND (a.role IN ('ADMIN','UNION') OR public.tower_task_responsible_236(a.user_id,p_service_id) OR EXISTS(SELECT 1 FROM public.tower_members m WHERE m.unit_id=d.unit_id AND m.user_id=a.user_id AND m.ended_at IS NULL))),
 plan AS (SELECT i.due_id,i.installment_no no,i.due_date,i.amount FROM public.tower_task_due_installments i JOIN dues d ON d.due_id=i.due_id
 UNION ALL
 SELECT d.due_id,coalesce((SELECT max(i.installment_no) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)+1,
 coalesce((SELECT max(ad.approved_at)::date FROM public.tower_task_credit_reversals cr JOIN public.tower_task_adjustments ad ON ad.adjustment_id=cr.adjustment_id WHERE cr.due_id=d.due_id),d.due_date),
 d.effective-coalesce((SELECT sum(i.amount) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)
 FROM dues d WHERE d.effective>coalesce((SELECT sum(i.amount) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)
 AND EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues other ON other.due_id=i.due_id JOIN public.tower_service_subscriptions sub ON sub.subscription_id=other.subscription_id WHERE sub.service_id=p_service_id)),
 base AS (SELECT d.due_id,d.unit_id,i.no,i.due_date,i.amount,d.effective,d.paid,
 coalesce(sum(i.amount) OVER(PARTITION BY d.due_id ORDER BY i.no ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM dues d JOIN plan i ON i.due_id=d.due_id),
 net AS (SELECT *,greatest(0,least(amount,effective-prior)) net_amount FROM base)
 SELECT coalesce(jsonb_agg(jsonb_build_object('dueId',due_id,'unitId',unit_id,'installment',no,'dueDate',due_date,'amount',net_amount,
 'paid',greatest(0,least(net_amount,paid-prior)),'remaining',net_amount-greatest(0,least(net_amount,paid-prior))) ORDER BY unit_id,due_date,no),'[]') INTO rows FROM net WHERE net_amount>0;
 RETURN jsonb_build_object('success',true,'rows',rows,
 'hasPlan',EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues d ON d.due_id=i.due_id JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id),
 'noPlanNeeded',NOT EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND d.status='OPEN' AND public.tower_task_due_amount_internal(d.due_id)>0),
 'hasPayments',EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND public.tower_task_due_paid_internal(d.due_id)>0));
END $f$;
CREATE OR REPLACE FUNCTION public.tower_task_fund_receipt_action_217(p_token text, p_service_id uuid, p_action text DEFAULT 'status'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor public.tower_users; v_f public.tower_task_fund_contributions;
 v_r public.tower_task_fund_receipts; v_account uuid; v_count integer;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin
 THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION') AND NOT (p_action='status' AND public.tower_task_responsible_236(v_actor.user_id,p_service_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('status','confirm') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 SELECT * INTO v_f FROM public.tower_task_fund_contributions WHERE service_id=p_service_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'FUND_CONTRIBUTION_NOT_POSTED'; END IF;
 SELECT * INTO v_r FROM public.tower_task_fund_receipts WHERE service_id=p_service_id;
 IF p_action='confirm' AND NOT FOUND THEN
  -- Lock funding row to serialize concurrent confirmations.
  PERFORM 1 FROM public.tower_task_fund_contributions WHERE service_id=p_service_id FOR UPDATE;
  SELECT * INTO v_r FROM public.tower_task_fund_receipts WHERE service_id=p_service_id;
  IF FOUND THEN RAISE EXCEPTION 'FUND_RECEIPT_ALREADY_CONFIRMED'; END IF;
  SELECT count(*),min(a.account_id::text)::uuid INTO v_count,v_account
  FROM public.tower_finance_accounts a WHERE a.account_kind='PERSONAL_SERVICE'
   AND a.service_id=p_service_id AND a.status='ACTIVE';
  IF v_count<>1 THEN RAISE EXCEPTION 'UNIQUE_ACTIVE_TASK_ACCOUNT_REQUIRED'; END IF;
  INSERT INTO public.tower_task_fund_receipts(service_id,account_id,amount,confirmed_by)
  VALUES(p_service_id,v_account,v_f.amount,v_actor.user_id);
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id)
  VALUES(v_actor.user_id,'CONFIRM_TASK_FUND_RECEIPT','SERVICE',p_service_id::text);
  SELECT * INTO v_r FROM public.tower_task_fund_receipts WHERE service_id=p_service_id;
 END IF;
 RETURN jsonb_build_object('serviceId',p_service_id,'fundExpenseId',v_f.fund_entry_id,
  'postedAmount',v_f.amount,'confirmed',v_r.service_id IS NOT NULL,
  'confirmedAmount',CASE WHEN v_r.service_id IS NOT NULL THEN v_r.amount ELSE 0 END,
  'accountId',v_r.account_id,'confirmedAt',v_r.confirmed_at);
END $function$;
CREATE OR REPLACE FUNCTION public.tower_finance_refund_approval_action(p_token text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users%ROWTYPE;
 v_sub public.tower_service_subscriptions%ROWTYPE;
 v_account_id uuid;
 v_id uuid;
 v_amount numeric(16,2);
 v_total numeric(16,2);
 v_used numeric(16,2);
 v_reserved numeric(16,2);
 v_date date;
 v_sub_id uuid;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
 IF p_action='list' THEN
  RETURN jsonb_build_object('readOnly',true,'subscriptions',coalesce((
   SELECT jsonb_agg(jsonb_build_object('subscriptionId',s.subscription_id,'serviceName',sv.name,
    'unitId',s.unit_id,'endedAt',s.ended_at,'hasApproval',EXISTS(
     SELECT 1 FROM public.tower_finance_refund_authorizations r
     WHERE r.subscription_id=s.subscription_id AND r.authorization_status='APPROVED'))
    ORDER BY s.ended_at DESC)
   FROM public.tower_service_subscriptions s
   JOIN public.tower_services sv ON sv.service_id=s.service_id
   WHERE s.status='ENDED' AND s.ended_at IS NOT NULL AND sv.billing_timing='PREPAID'
    AND EXISTS(SELECT 1 FROM public.tower_finance_accounts a WHERE a.service_id=s.service_id
      AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE')
   ),'[]'::jsonb));
 END IF;
 IF p_action<>'approve' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR
    coalesce(p_payload->>'subscriptionId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' OR
    coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR
    coalesce(p_payload->>'effectiveDate','') !~ '^\d{4}-\d{2}-\d{2}$'
 THEN RAISE EXCEPTION 'INVALID_APPROVAL_FIELDS'; END IF;
 v_sub_id:=(p_payload->>'subscriptionId')::uuid;
 v_amount:=(p_payload->>'amount')::numeric;
 IF v_amount<=0 OR v_amount<>round(v_amount,2) THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
 BEGIN v_date:=(p_payload->>'effectiveDate')::date;
 EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN RAISE EXCEPTION 'INVALID_EFFECTIVE_DATE'; END;
 -- Lock account first; all refund reservations and advance consumption must follow this lock ordering.
 SELECT a.account_id INTO v_account_id FROM public.tower_finance_accounts a
 JOIN public.tower_service_subscriptions s ON s.service_id=a.service_id
 WHERE s.subscription_id=v_sub_id AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE'
 ORDER BY a.account_id LIMIT 1 FOR UPDATE OF a;
 IF NOT FOUND THEN RAISE EXCEPTION 'PERSONAL_ACCOUNT_NOT_FOUND'; END IF;
 SELECT * INTO v_sub FROM public.tower_service_subscriptions
 WHERE subscription_id=v_sub_id AND status='ENDED' AND ended_at IS NOT NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ENDED'; END IF;
 -- Re-check service eligibility in the trusted write path (not only the UI/list).
 PERFORM 1 FROM public.tower_services svc
 WHERE svc.service_id=v_sub.service_id AND svc.billing_timing='PREPAID';
 IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_SERVICE_NOT_PREPAID'; END IF;
 -- An ambiguous service-to-account mapping can route funds to the wrong beneficiary.
 IF (SELECT count(*) FROM public.tower_finance_accounts a
      WHERE a.service_id=v_sub.service_id AND a.account_kind='PERSONAL_SERVICE'
       AND a.status='ACTIVE')<>1
 THEN RAISE EXCEPTION 'AMBIGUOUS_PERSONAL_ACCOUNT'; END IF;
 IF v_date<v_sub.ended_at::date OR v_date>current_date THEN RAISE EXCEPTION 'INVALID_EFFECTIVE_DATE'; END IF;
 -- No overlapping active authorizations even from multiple UNION sessions.
 IF EXISTS (SELECT 1 FROM public.tower_finance_refund_authorizations r
   WHERE r.subscription_id=v_sub_id AND r.account_id=v_account_id
    AND r.authorization_status='APPROVED') THEN RAISE EXCEPTION 'ACTIVE_REFUND_APPROVAL_EXISTS'; END IF;
 IF EXISTS (SELECT 1 FROM public.tower_finance_advance_uses x
  JOIN public.tower_finance_applications ap ON ap.application_id=x.advance_application_id
  JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
  JOIN public.tower_finance_receipts rec ON rec.receipt_id=rp.receipt_id
  LEFT JOIN public.tower_finance_advance_use_subscriptions e ON e.use_id=x.use_id
  WHERE rp.account_id=v_account_id AND rec.unit_id=v_sub.unit_id AND e.use_id IS NULL)
 THEN RAISE EXCEPTION 'UNATTRIBUTED_HISTORIC_ADVANCE_USE'; END IF;
 SELECT coalesce(sum(l.amount),0) INTO v_total
 FROM public.tower_finance_advance_subscription_links l
 JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id
 JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
 JOIN public.tower_finance_receipts rec ON rec.receipt_id=rp.receipt_id
 WHERE l.subscription_id=v_sub_id AND rp.account_id=v_account_id
   AND rec.unit_id=v_sub.unit_id AND rec.receipt_status='POSTED';
 SELECT coalesce(sum(x.amount),0) INTO v_used
 FROM public.tower_finance_advance_use_subscriptions e
 JOIN public.tower_finance_advance_uses x ON x.use_id=e.use_id
 JOIN public.tower_finance_advance_subscription_links l ON l.link_id=e.link_id
 JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id
 JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
 JOIN public.tower_finance_receipts rec ON rec.receipt_id=rp.receipt_id
 WHERE l.subscription_id=v_sub_id AND rp.account_id=v_account_id AND rec.unit_id=v_sub.unit_id
  AND rec.receipt_status='POSTED';
 SELECT coalesce(sum(m.amount),0) INTO v_reserved
 FROM public.tower_finance_refund_movements rm
 JOIN public.tower_finance_refund_authorizations r ON r.refund_authorization_id=rm.refund_authorization_id
 JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id
 WHERE r.subscription_id=v_sub_id AND r.account_id=v_account_id
  AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED');
 IF v_total-v_used-v_reserved<=0 OR v_amount>v_total-v_used-v_reserved
 THEN RAISE EXCEPTION 'REFUND_EXCEEDS_EXACT_UNUSED_ADVANCE'; END IF;
 INSERT INTO public.tower_finance_refund_authorizations
 (unit_id,account_id,subscription_id,max_amount,approved_by,effective_date)
 VALUES(v_sub.unit_id,v_account_id,v_sub_id,v_amount,v_actor.user_id,v_date)
 RETURNING refund_authorization_id INTO v_id;
 RETURN jsonb_build_object('authorizationId',v_id,'amount',v_amount,'status','APPROVED',
  'subscriptionId',v_sub_id,'unitId',v_sub.unit_id);
END; $function$;
CREATE OR REPLACE FUNCTION public.tower_finance_request_unit_refund_action(p_token text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users%ROWTYPE;
 v_auth public.tower_finance_refund_authorizations%ROWTYPE;
 v_sub public.tower_service_subscriptions%ROWTYPE;
 v_manager uuid;
 v_manager_count integer;
 v_auth_id uuid;
 v_amount numeric(16,2);
 v_exact numeric(16,2);
 v_reserved numeric(16,2);
 v_id uuid;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF coalesce(p_payload->>'authorizationId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
   OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$'
 THEN RAISE EXCEPTION 'INVALID_REFUND_FIELDS'; END IF;
 v_auth_id:=(p_payload->>'authorizationId')::uuid;
 v_amount:=(p_payload->>'amount')::numeric;
 IF v_amount<=0 THEN RAISE EXCEPTION 'INVALID_REFUND_AMOUNT'; END IF;
 -- Serialize across ALL authorizations sharing an account, then lock the particular authorization.
 PERFORM 1 FROM public.tower_finance_accounts a
 JOIN public.tower_finance_refund_authorizations r ON r.account_id=a.account_id
 WHERE r.refund_authorization_id=v_auth_id AND a.account_kind='PERSONAL_SERVICE'
  AND a.status='ACTIVE' FOR UPDATE OF a;
 IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_ACCOUNT_UNAVAILABLE'; END IF;
 SELECT * INTO v_auth FROM public.tower_finance_refund_authorizations
 WHERE refund_authorization_id=v_auth_id FOR UPDATE;
 IF NOT FOUND OR v_auth.authorization_status<>'APPROVED' THEN RAISE EXCEPTION 'REFUND_NOT_APPROVED'; END IF;
 SELECT * INTO v_sub FROM public.tower_service_subscriptions
 WHERE subscription_id=v_auth.subscription_id AND unit_id=v_auth.unit_id
  AND status='ENDED' AND ended_at IS NOT NULL FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ENDED'; END IF;
 IF v_auth.effective_date < v_sub.ended_at::date THEN RAISE EXCEPTION 'INVALID_CANCELLATION_EFFECTIVE_DATE'; END IF;
 PERFORM 1 FROM public.tower_finance_accounts a
 WHERE a.account_id=v_auth.account_id AND a.service_id=v_sub.service_id
  AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_ACCOUNT_SUBSCRIPTION_MISMATCH'; END IF;
 PERFORM 1 FROM public.tower_users u WHERE u.user_id=v_auth.approved_by
  AND u.role IN ('ADMIN','UNION') AND u.status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_REQUIRES_UNION_APPROVAL'; END IF;
 -- Fail closed on ambiguous current managers, rather than refunding to an arbitrary UUID.
 SELECT count(*),min(m.user_id) INTO v_manager_count,v_manager
 FROM public.tower_members m
 JOIN public.tower_users u ON u.user_id=m.user_id
 WHERE m.unit_id=v_auth.unit_id AND m.member_role='MANAGER'
  AND m.ended_at IS NULL AND u.role='RESIDENT' AND u.status='ACTIVE';
 IF v_manager_count<>1 THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
 IF v_manager IS NULL THEN RAISE EXCEPTION 'CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
 IF v_manager=v_actor.user_id THEN RAISE EXCEPTION 'SELF_REFUND_NOT_ALLOWED'; END IF;
 -- Missing exact attributions make the whole account/UNIT unsafe, not just this subscription.
 IF EXISTS (
  SELECT 1 FROM public.tower_finance_advance_uses x
  JOIN public.tower_finance_applications ap ON ap.application_id=x.advance_application_id
  JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
  JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id
  LEFT JOIN public.tower_finance_advance_use_subscriptions e ON e.use_id=x.use_id
  WHERE rp.account_id=v_auth.account_id AND r.unit_id=v_auth.unit_id AND e.use_id IS NULL
 ) THEN RAISE EXCEPTION 'UNATTRIBUTED_HISTORIC_ADVANCE_USE'; END IF;
 -- Exact link-specific remaining prepayment. Exclude REVERSED original receipts.
 SELECT COALESCE(sum(l.amount),0) INTO v_exact
 FROM public.tower_finance_advance_subscription_links l
 JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id
 JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
 JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id
 WHERE l.subscription_id=v_auth.subscription_id AND rp.account_id=v_auth.account_id
  AND r.unit_id=v_auth.unit_id AND r.receipt_status='POSTED';
 SELECT v_exact-COALESCE(sum(x.amount),0) INTO v_exact
 FROM public.tower_finance_advance_use_subscriptions e
 JOIN public.tower_finance_advance_uses x ON x.use_id=e.use_id
 JOIN public.tower_finance_advance_subscription_links l ON l.link_id=e.link_id
 WHERE l.subscription_id=v_auth.subscription_id
  AND EXISTS (
   SELECT 1 FROM public.tower_finance_applications ap
   JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
   JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id
   WHERE ap.application_id=l.advance_application_id AND rp.account_id=v_auth.account_id
    AND r.unit_id=v_auth.unit_id AND r.receipt_status='POSTED');
 IF v_exact<0 THEN RAISE EXCEPTION 'REFUND_LEDGER_INCONSISTENT'; END IF;
 SELECT COALESCE(sum(m.amount),0) INTO v_reserved
 FROM public.tower_finance_refund_movements rm
 JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id
 JOIN public.tower_finance_refund_authorizations a ON a.refund_authorization_id=rm.refund_authorization_id
 WHERE a.subscription_id=v_auth.subscription_id AND a.account_id=v_auth.account_id
  AND a.unit_id=v_auth.unit_id AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED');
 IF v_amount>v_exact-v_reserved THEN RAISE EXCEPTION 'REFUND_EXCEEDS_EXACT_UNUSED_ADVANCE'; END IF;
 -- Underlying function additionally locks/checks authorization max and sender cash availability.
 v_id:=public.tower_finance_request_unit_refund_internal(v_auth_id,v_actor.user_id,v_manager,v_amount);
 RETURN jsonb_build_object('movementId',v_id,'status','PENDING','amount',v_amount,'unitId',v_auth.unit_id);
END; $function$;
CREATE OR REPLACE FUNCTION public.tower_finance_handover_action(p_token text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_actor public.tower_users%ROWTYPE;
 v_id uuid;
 v_account uuid;
 v_recipient uuid;
 v_amount numeric;
 v_kind text;
 v_result text;
 v_recipient_user public.tower_users%ROWTYPE;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin
 THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF v_actor.role NOT IN ('UNION','OPERATOR','RESIDENT','ADMIN') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action='request' THEN
  IF v_actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF coalesce(p_payload->>'accountId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
   OR coalesce(p_payload->>'recipientId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
   OR coalesce(p_payload->>'amount','') !~ '^([0-9]+)(\.[0-9]{1,2})?$'
  THEN RAISE EXCEPTION 'INVALID_HANDOVER_FIELDS'; END IF;
  v_account:=(p_payload->>'accountId')::uuid;
  v_recipient:=(p_payload->>'recipientId')::uuid;
  v_amount:=(p_payload->>'amount')::numeric;
  v_kind:=p_payload->>'kind';
  IF v_kind NOT IN ('BENEFICIARY_DELIVERY','BENEFICIARY_HANDOVER') OR v_kind IS NULL
  THEN RAISE EXCEPTION 'INVALID_HANDOVER_KIND'; END IF;
  SELECT * INTO v_recipient_user FROM public.tower_users WHERE user_id=v_recipient;
  IF NOT FOUND OR v_recipient_user.status<>'ACTIVE' THEN RAISE EXCEPTION 'RECIPIENT_NOT_ACTIVE'; END IF;
  IF v_kind='BENEFICIARY_HANDOVER' AND v_recipient_user.role NOT IN ('ADMIN','UNION','OPERATOR')
  THEN RAISE EXCEPTION 'INVALID_INTERMEDIARY_ROLE'; END IF;
  -- Sender identity is always derived from validated session, NEVER from payload.
  v_id:=public.tower_finance_request_cash_handover_internal(
    v_account,v_actor.user_id,v_recipient,v_amount,v_kind);
  RETURN jsonb_build_object('movementId',v_id,'status','PENDING');
 ELSIF p_action IN ('confirm','cancel') THEN
  IF coalesce(p_payload->>'movementId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
  THEN RAISE EXCEPTION 'INVALID_MOVEMENT_ID'; END IF;
  v_id:=(p_payload->>'movementId')::uuid;
  -- Internal primitive will verify recipient/sender while holding account and movement locks.
  IF p_action='confirm' THEN
   v_result:=public.tower_finance_confirm_movement_internal(v_id,v_actor.user_id);
  ELSE
   v_result:=public.tower_finance_cancel_handover_internal(v_id,v_actor.user_id);
  END IF;
  RETURN jsonb_build_object('movementId',v_id,'status',v_result);
 ELSE
  RAISE EXCEPTION 'UNKNOWN_HANDOVER_ACTION';
 END IF;
END; $function$;
CREATE TABLE IF NOT EXISTS public.tower_task_requests_236(
 request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_id uuid NOT NULL REFERENCES public.tower_services,
 actor_id uuid NOT NULL REFERENCES public.tower_users,kind text NOT NULL CHECK(kind IN ('ALLOCATION','COST','CANCELLATION')),
 reference text NOT NULL UNIQUE,payload jsonb NOT NULL,state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','REVIEWED','REJECTED')),
 reviewed_by uuid REFERENCES public.tower_users,review_note text NOT NULL DEFAULT '',created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_task_requests_236 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_task_requests_236 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_task_management_236(p_token text,p_action text,p_service uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;admin boolean;owner boolean;result jsonb;sub public.tower_service_subscriptions;units uuid[];un uuid;req public.tower_task_requests_236;note text;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.must_change_pin THEN RAISE EXCEPTION 'PIN_CHANGE_REQUIRED'; END IF;
 admin:=a.role IN ('ADMIN','UNION');
 IF p_action IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF p_action='assigned' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('serviceId',svc.service_id,'name',svc.name,'phase',p.phase,'enrollment',svc.enrollment_status) ORDER BY svc.name),'[]') INTO result FROM public.tower_services svc JOIN public.tower_task_projects p ON p.service_id=svc.service_id WHERE public.tower_task_responsible_236(a.user_id,svc.service_id);
  RETURN result;
 END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 owner:=public.tower_task_responsible_236(a.user_id,p_service);
 IF NOT admin AND NOT owner THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='requests' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('actorName',public.tower_person_label_231(NULL,NULL,r.actor_id)) ORDER BY r.created_at DESC),'[]') INTO result FROM (SELECT * FROM public.tower_task_requests_236 WHERE service_id=p_service AND (admin OR actor_id=a.user_id) ORDER BY created_at DESC LIMIT 50) r;RETURN result;
 END IF;
 IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service AND phase IN ('CANCELLED','FINANCIAL_CLOSED')) THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
 IF p_action='request' THEN
  IF p_payload->>'kind' NOT IN ('ALLOCATION','COST','CANCELLATION') OR length(btrim(coalesce(p_payload->>'note',''))) NOT BETWEEN 1 AND 2000 OR length(coalesce(p_payload->>'reference','')) NOT BETWEEN 16 AND 80 THEN RAISE EXCEPTION 'INVALID_TASK_REQUEST'; END IF;
  IF p_payload ? 'amount' AND jsonb_typeof(p_payload->'amount')<>'null' AND coalesce(p_payload->>'amount','') !~ '^-?[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_TASK_REQUEST'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('task-request:'||(p_payload->>'reference'),0));
  SELECT * INTO req FROM public.tower_task_requests_236 WHERE reference=p_payload->>'reference';
  IF FOUND THEN IF req.actor_id<>a.user_id OR req.service_id<>p_service OR req.payload IS DISTINCT FROM p_payload THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;RETURN jsonb_build_object('success',true,'replayed',true,'requestId',req.request_id); END IF;
  INSERT INTO public.tower_task_requests_236(service_id,actor_id,kind,reference,payload) VALUES(p_service,a.user_id,p_payload->>'kind',p_payload->>'reference',p_payload) RETURNING request_id INTO un;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_MANAGEMENT_REQUEST','SERVICE',p_service::text);RETURN jsonb_build_object('success',true,'requestId',un);
 ELSIF p_action='review_request' THEN
  IF NOT admin THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_payload->>'state' NOT IN ('REVIEWED','REJECTED') OR p_payload->>'state' IS NULL OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_TASK_REQUEST'; END IF;
  UPDATE public.tower_task_requests_236 SET state=p_payload->>'state',reviewed_by=a.user_id,review_note=coalesce(p_payload->>'note','') WHERE request_id=(p_payload->>'requestId')::uuid AND service_id=p_service AND state='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING'; END IF;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'REVIEW_TASK_REQUEST','SERVICE',p_service::text);RETURN jsonb_build_object('success',true);
 END IF;
 IF s.enrollment_status<>'OPEN' OR NOT EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service AND phase='PARTICIPATION' AND (deadline IS NULL OR deadline>=current_date)) THEN RAISE EXCEPTION 'ENROLLMENT_NOT_OPEN'; END IF;
 IF p_action='member_enroll' THEN
  IF jsonb_typeof(p_payload->'unitIds')<>'array' OR jsonb_array_length(p_payload->'unitIds') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  SELECT array_agg(DISTINCT x::uuid) INTO units FROM jsonb_array_elements_text(p_payload->'unitIds') x;
  IF cardinality(units)<>jsonb_array_length(p_payload->'unitIds') THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  FOREACH un IN ARRAY units LOOP
   IF NOT EXISTS(SELECT 1 FROM public.tower_units WHERE unit_id=un AND status='ACTIVE') OR EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service AND cardinality(target_units)>0 AND NOT un=ANY(target_units)) THEN RAISE EXCEPTION 'UNIT_OUTSIDE_TASK_SCOPE'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND unit_id=un AND status IN ('ACTIVE','PENDING')) THEN CONTINUE; END IF;
   INSERT INTO public.tower_service_subscriptions(service_id,unit_id,requested_by,status,quantity,unit_price_snapshot,amount_snapshot,billing_timing,auto_renew) VALUES(p_service,un,a.user_id,'ACTIVE',1,0,0,'POSTPAID',false) RETURNING subscription_id INTO note;
   INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(note::uuid,'OTHER',left(coalesce(p_payload->>'note','اتفاق مباشر مع مسؤول المهمة'),2000),a.user_id);
  END LOOP;
 ELSIF p_action IN ('member_review','member_remove') THEN
  SELECT * INTO sub FROM public.tower_service_subscriptions WHERE subscription_id=(p_payload->>'subscriptionId')::uuid AND service_id=p_service FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUBSCRIPTION_SCOPE_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_finance_dues WHERE subscription_id=sub.subscription_id) THEN RAISE EXCEPTION 'SERVICE_ALREADY_HAS_DUES'; END IF;
  IF p_action='member_review' THEN
   IF sub.status<>'PENDING' OR coalesce(p_payload->>'decision','') NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING'; END IF;
   UPDATE public.tower_service_subscriptions SET status=CASE WHEN p_payload->>'decision'='APPROVE' THEN 'ACTIVE' ELSE 'REJECTED' END,reviewed_by=a.user_id,reviewed_at=now() WHERE subscription_id=sub.subscription_id;
   IF p_payload->>'decision'='APPROVE' THEN INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(sub.subscription_id,'APP','موافقة طلب التطبيق',a.user_id) ON CONFLICT DO NOTHING; END IF;
  ELSE
   IF sub.status<>'ACTIVE' THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE'; END IF;
   UPDATE public.tower_service_subscriptions SET status='ENDED',quantity=0,amount_snapshot=0,ended_at=now() WHERE subscription_id=sub.subscription_id;
  END IF;
 ELSE RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_'||upper(p_action),'SERVICE',p_service::text);
 RETURN jsonb_build_object('success',true);
END $f$;
-- One Save transaction validates the preview, saves the count and installs the original schedule.
CREATE OR REPLACE FUNCTION public.tower_task_schedule_save_236(p_token text,p_service uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;plan jsonb;cnt integer;result jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF coalesce(p_payload->>'installmentCount','') !~ '^[0-9]+$' THEN RAISE EXCEPTION 'INVALID_INSTALLMENTS'; END IF;
 cnt:=(p_payload->>'installmentCount')::int;IF cnt NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'INVALID_INSTALLMENTS'; END IF;
 plan:=public.tower_task_controls_235(p_token,p_service,'preview','{}');
 IF coalesce((plan->>'hasPlan')::boolean,false) THEN
  IF cnt<>(plan->>'installmentCount')::int THEN RAISE EXCEPTION 'INSTALLMENT_PLAN_ALREADY_INSTALLED'; END IF;
  RETURN plan||jsonb_build_object('alreadyInstalled',true);
 END IF;
 IF p_payload->>'expectedFirstDueDate' IS DISTINCT FROM plan->>'firstDueDate' THEN RAISE EXCEPTION 'INSTALLMENT_SETUP_CHANGED'; END IF;
 PERFORM public.tower_task_controls_235(p_token,p_service,'save',jsonb_build_object('section','installments','expectedRevision',p_payload->'expectedRevision','patch',jsonb_build_object('installmentCount',cnt)));
 plan:=public.tower_task_controls_235(p_token,p_service,'preview','{}');
 result:=public.tower_task_controls_235(p_token,p_service,'install',jsonb_build_object('expectedRevision',plan->'revision','expectedFirstDueDate',p_payload->>'expectedFirstDueDate'));
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_task_management_236(text,text,uuid,jsonb),public.tower_task_schedule_save_236(text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_management_236(text,text,uuid,jsonb),public.tower_task_schedule_save_236(text,uuid,jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.tower_task_project_read_229(text,uuid,uuid),public.tower_task_project_action_229(text,text,uuid,jsonb),public.tower_finance_personal_receipt_action(text,jsonb),public.tower_finance_refund_action(text,text,jsonb),public.tower_personal_collections_230(text,text,jsonb),public.tower_task_workflow_action(text,text,jsonb),public.tower_task_controls_235(text,uuid,text,jsonb),public.tower_task_installments_action(text,uuid,text),public.tower_service_shared_allocation_action(text,text,uuid),public.tower_task_fund_receipt_action_217(text,uuid,text),public.tower_finance_refund_approval_action(text,text,jsonb),public.tower_finance_request_unit_refund_action(text,jsonb),public.tower_finance_handover_action(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_project_read_229(text,uuid,uuid),public.tower_task_project_action_229(text,text,uuid,jsonb),public.tower_finance_personal_receipt_action(text,jsonb),public.tower_finance_refund_action(text,text,jsonb),public.tower_personal_collections_230(text,text,jsonb),public.tower_task_workflow_action(text,text,jsonb),public.tower_task_controls_235(text,uuid,text,jsonb),public.tower_task_installments_action(text,uuid,text),public.tower_service_shared_allocation_action(text,text,uuid),public.tower_task_fund_receipt_action_217(text,uuid,text),public.tower_finance_refund_approval_action(text,text,jsonb),public.tower_finance_request_unit_refund_action(text,jsonb),public.tower_finance_handover_action(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.181 - SQL_236.

Code End
*/
