/* Tower App V2.5.173 — SQL230. Requires SQL229. No financial workflow runs on installation. */
BEGIN;
DO $check$ BEGIN IF to_regprocedure('public.tower_task_project_action_229(text,text,uuid,jsonb)') IS NULL THEN RAISE EXCEPTION 'SQL229_REQUIRED_BEFORE_SQL230'; END IF; END $check$;
CREATE TABLE IF NOT EXISTS public.tower_service_edit_history_230 (
 edit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), service_id uuid NOT NULL REFERENCES public.tower_services,
 reference text NOT NULL UNIQUE, actor_id uuid NOT NULL REFERENCES public.tower_users,
 request jsonb NOT NULL,before_state jsonb NOT NULL,after_state jsonb NOT NULL,reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_service_edit_history_230 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_service_edit_history_230 FROM PUBLIC,anon,authenticated,service_role;
-- Existing proposals retain their rows and become subscribable. Historical interest rows stay as history.
UPDATE public.tower_task_projects SET phase='PARTICIPATION',version=version+1,updated_at=now() WHERE phase='PROPOSAL';
CREATE OR REPLACE FUNCTION public.tower_task_project_action_229(p_token text,p_action text,p_service uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;v_id uuid;v_sub uuid;v_unit uuid;v_account uuid;
 v_receipt uuid;v_portion uuid;v_app uuid;
 v_amount numeric;v_ref text;v_reason text;v_data jsonb;v_row record;v_total numeric;v_remaining numeric;v_take numeric;v_due uuid;
 e public.tower_task_expenses;ad public.tower_task_adjustments;v_current jsonb;v_authorization uuid;v_manager uuid;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action IN ('interest','confirm_refund','confirm_donation_return') THEN
  IF a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 ELSE IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF; END IF;
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
   IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
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
   IF e.funding='TASK' AND p_action='expense_approve' AND e.recorded_by<>a.user_id THEN RAISE EXCEPTION 'ONLY_RECORDED_HOLDER_CAN_CONFIRM_EXPENSE'; END IF;
   IF e.funding='TASK' OR p_action='expense_pay' THEN
    IF e.amount>public.tower_finance_holder_available_internal(v_account,a.user_id) THEN RAISE EXCEPTION 'INSUFFICIENT_HOLDER_BALANCE'; END IF;
    INSERT INTO public.tower_task_expense_disbursements(expense_id,account_id,holder_id,amount) VALUES(e.expense_id,v_account,a.user_id,e.amount);
   END IF;
   UPDATE public.tower_task_expenses SET state='APPROVED',approved_by=coalesce(approved_by,a.user_id),
    paid_by=CASE WHEN funding='PERSONAL' THEN recorded_by WHEN funding='TASK' OR p_action='expense_pay' THEN a.user_id ELSE NULL END,
    paid_at=CASE WHEN funding IN ('PERSONAL','TASK') OR p_action='expense_pay' THEN now() ELSE NULL END WHERE expense_id=e.expense_id;
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
   IF p_action='cancel_settled' AND (a.role<>'UNION' OR length(btrim(coalesce(p_payload->>'reason','')))=0) THEN RAISE EXCEPTION 'UNION_CANCELLATION_REASON_REQUIRED'; END IF;
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

CREATE OR REPLACE FUNCTION public.tower_task_project_read_230(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE result jsonb; extra jsonb;
BEGIN
 result:=public.tower_task_project_read_229(p_token,p_service,p_unit);
 SELECT jsonb_build_object('totalBudget',s.total_budget+coalesce((SELECT sum(amount) FROM public.tower_task_adjustments WHERE service_id=s.service_id AND state='APPROVED'),0),'description',s.description,'beneficiaryUserId',a.beneficiary_user_id,'responsibleName',u.name,
 'estimatedNet',greatest(s.total_budget-coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=s.service_id),0),0),
 'activeCount',(SELECT count(*) FROM public.tower_service_subscriptions WHERE service_id=s.service_id AND status='ACTIVE')) INTO extra
 FROM public.tower_services s LEFT JOIN public.tower_finance_accounts a ON a.service_id=s.service_id AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE'
 LEFT JOIN public.tower_users u ON u.user_id=a.beneficiary_user_id WHERE s.service_id=p_service;
 IF p_unit IS NOT NULL THEN
 result:=jsonb_set(result,'{project,agreed_amounts}',coalesce((SELECT jsonb_agg(x) FROM jsonb_array_elements((SELECT agreed_amounts FROM public.tower_task_projects WHERE service_id=p_service)) x WHERE x->>'subscriptionId' IN (SELECT subscription_id::text FROM public.tower_service_subscriptions WHERE service_id=p_service AND unit_id=p_unit)),'[]'));
 END IF;
 IF p_unit IS NOT NULL AND (result#>>'{project,distribution}')='EQUAL' THEN
 extra:=extra||jsonb_build_object('estimatedShare',(WITH ranked AS (SELECT unit_id,row_number() OVER(ORDER BY unit_id) n,count(*) OVER() cnt FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE') SELECT (floor((extra->>'estimatedNet')::numeric*100/cnt)+CASE WHEN n<=mod((extra->>'estimatedNet')::numeric*100,cnt) THEN 1 ELSE 0 END)/100 FROM ranked WHERE unit_id=p_unit));
 END IF;
 RETURN result||extra;
END $f$;

CREATE OR REPLACE FUNCTION public.tower_service_edit_230(p_token text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;s public.tower_services;p public.tower_task_projects;ac public.tower_finance_accounts;
 sid uuid:=(p_payload->>'serviceId')::uuid; ref text:=p_payload->>'reference';reason text:=btrim(coalesce(p_payload->>'reason',''));
 target numeric;diff numeric;adj jsonb;prior public.tower_service_edit_history_230;before_data jsonb;financial boolean;beneficiary uuid;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF length(coalesce(ref,'')) NOT BETWEEN 16 AND 128 THEN RAISE EXCEPTION 'REFERENCE_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('service-edit:'||ref,0));
 SELECT * INTO prior FROM public.tower_service_edit_history_230 WHERE reference=ref;
 IF FOUND THEN
  IF prior.actor_id<>actor.user_id OR prior.request<>p_payload THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
  RETURN jsonb_build_object('serviceId',sid,'replayed',true);
 END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=sid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
 IF p_payload->>'expectedUpdatedAt' IS DISTINCT FROM s.updated_at::text AND (p_payload->>'expectedUpdatedAt')::timestamptz IS DISTINCT FROM s.updated_at THEN RAISE EXCEPTION 'TASK_CHANGED_REFRESH'; END IF;
 IF length(btrim(coalesce(p_payload->>'name',''))) NOT BETWEEN 1 AND 200 OR length(coalesce(p_payload->>'description',''))>8000 THEN RAISE EXCEPTION 'INVALID_TASK_FIELDS'; END IF;
 SELECT * INTO ac FROM public.tower_finance_accounts WHERE service_id=sid AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE' FOR UPDATE;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=sid FOR UPDATE;
 IF p.service_id IS NOT NULL AND coalesce((p_payload->>'expectedProjectVersion')::bigint,-1)<>p.version THEN RAISE EXCEPTION 'TASK_CHANGED_REFRESH'; END IF;
 before_data:=jsonb_build_object('service',to_jsonb(s),'project',to_jsonb(p),'account',to_jsonb(ac));
 beneficiary:=coalesce(nullif(p_payload->>'beneficiaryUserId','')::uuid,ac.beneficiary_user_id);
 financial:=false;
 IF ac.account_id IS NOT NULL AND beneficiary IS DISTINCT FROM ac.beneficiary_user_id THEN
  IF NOT EXISTS(SELECT 1 FROM public.tower_users WHERE user_id=beneficiary AND status='ACTIVE') THEN RAISE EXCEPTION 'INVALID_BENEFICIARY'; END IF;
  financial:=true;
 END IF;
 IF s.pricing_mode='SHARED_TOTAL' THEN
  IF coalesce(p_payload->>'totalBudget','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_TOTAL_BUDGET'; END IF;
  target:=(p_payload->>'totalBudget')::numeric;IF target<=0 THEN RAISE EXCEPTION 'INVALID_TOTAL_BUDGET'; END IF;
  diff:=target-(s.total_budget+CASE WHEN s.enrollment_status='FINALIZED' THEN coalesce((SELECT sum(amount) FROM public.tower_task_adjustments WHERE service_id=sid AND state='APPROVED'),0) ELSE 0 END);financial:=financial OR diff<>0;
 ELSE
  IF coalesce(p_payload->>'price','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_PRICE'; END IF;
  financial:=financial OR s.price<>(p_payload->>'price')::numeric;
 END IF;
 IF financial AND length(reason)=0 THEN RAISE EXCEPTION 'EDIT_REASON_REQUIRED'; END IF;
 IF p.phase IN ('CANCELLED','FINANCIAL_CLOSED') AND financial THEN
  UPDATE public.tower_task_projects SET phase='PARTICIPATION',closure_note='إعادة فتح لتعديل موثق: '||reason WHERE service_id=sid;
 END IF;
 IF s.enrollment_status='FINALIZED' AND diff<>0 THEN
  IF ac.account_id IS NULL THEN RAISE EXCEPTION 'DEDICATED_TASK_ACCOUNT_REQUIRED'; END IF;
  adj:=public.tower_task_project_action_229(p_token,'adjustment_draft',sid,jsonb_build_object('reference',ref||':cost','amount',diff,'reason',reason));
  PERFORM public.tower_task_project_action_229(p_token,'adjustment_approve',sid,jsonb_build_object('adjustmentId',adj->>'adjustmentId'));
 END IF;
 -- Updating the current beneficiary does not change receipts, collectors, custody or named pending deliveries.
 IF ac.account_id IS NOT NULL AND beneficiary IS DISTINCT FROM ac.beneficiary_user_id THEN
  UPDATE public.tower_finance_accounts SET beneficiary_user_id=beneficiary WHERE account_id=ac.account_id;
 END IF;
 IF p_payload ? 'billingTiming' AND p_payload->>'billingTiming' NOT IN ('PREPAID','POSTPAID') THEN RAISE EXCEPTION 'INVALID_BILLING_TIMING'; END IF;
 UPDATE public.tower_services SET billing_timing=CASE WHEN pricing_mode<>'SHARED_TOTAL' THEN coalesce(p_payload->>'billingTiming',billing_timing) ELSE billing_timing END,allow_quantity=CASE WHEN pricing_mode<>'SHARED_TOTAL' THEN coalesce((p_payload->>'allowQuantity')::boolean,allow_quantity) ELSE allow_quantity END,cancelable=CASE WHEN pricing_mode<>'SHARED_TOTAL' THEN coalesce((p_payload->>'cancelable')::boolean,cancelable) ELSE cancelable END,name=btrim(p_payload->>'name'),description=coalesce(p_payload->>'description',''),
 total_budget=CASE WHEN pricing_mode='SHARED_TOTAL' AND enrollment_status<>'FINALIZED' THEN target ELSE total_budget END,
 price=CASE WHEN pricing_mode<>'SHARED_TOTAL' THEN (p_payload->>'price')::numeric ELSE price END,updated_at=now() WHERE service_id=sid;
 UPDATE public.tower_task_projects SET scope_text=coalesce(p_payload->>'scope',scope_text),version=version+1,updated_by=actor.user_id,updated_at=now() WHERE service_id=sid;
 INSERT INTO public.tower_service_edit_history_230(service_id,reference,actor_id,request,before_state,after_state,reason)
 VALUES(sid,ref,actor.user_id,p_payload,before_data,jsonb_build_object('service',(SELECT to_jsonb(x) FROM public.tower_services x WHERE service_id=sid),'project',(SELECT to_jsonb(x) FROM public.tower_task_projects x WHERE service_id=sid),'beneficiaryUserId',beneficiary),reason);
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'EDIT_SERVICE_DETAILS_230','SERVICE',sid::text);
 RETURN jsonb_build_object('serviceId',sid,'success',true);
END $f$;

CREATE OR REPLACE FUNCTION public.tower_personal_collections_230(p_token text,p_action text DEFAULT 'read',p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;unit uuid;account uuid;amount numeric;remaining numeric;ret jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='collect' THEN
  IF actor.role NOT IN ('UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
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
 RETURN jsonb_build_object('rows',ret,'canCollect',actor.role IN ('UNION','OPERATOR'));
END $f$;
REVOKE ALL ON FUNCTION public.tower_service_edit_230(text,jsonb),public.tower_task_project_read_230(text,uuid,uuid),public.tower_personal_collections_230(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_edit_230(text,jsonb),public.tower_task_project_read_230(text,uuid,uuid),public.tower_personal_collections_230(text,text,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.tower_service_edit_context_230(p_token text,p_service uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;result jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 SELECT jsonb_build_object('serviceId',s.service_id,'name',s.name,'description',s.description,'price',s.price,'totalBudget',s.total_budget+CASE WHEN s.enrollment_status='FINALIZED' THEN coalesce((SELECT sum(amount) FROM public.tower_task_adjustments WHERE service_id=s.service_id AND state='APPROVED'),0) ELSE 0 END,
 'pricingMode',s.pricing_mode,'serviceKind',s.service_kind,'billingTiming',s.billing_timing,'allowQuantity',s.allow_quantity,'cancelable',s.cancelable,'updatedAt',s.updated_at,'enrollment',s.enrollment_status,
 'scope',p.scope_text,'projectVersion',p.version,'phase',p.phase,'beneficiaryUserId',a.beneficiary_user_id) INTO result
 FROM public.tower_services s LEFT JOIN public.tower_task_projects p ON p.service_id=s.service_id
 LEFT JOIN public.tower_finance_accounts a ON a.service_id=s.service_id AND a.account_kind='PERSONAL_SERVICE' AND a.status='ACTIVE' WHERE s.service_id=p_service;
 IF result IS NULL THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_service_edit_context_230(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_edit_context_230(text,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.tower_service_requests_230(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;data jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 data:=public.tower_services_action(p_token,'requests','{}');
 RETURN coalesce((SELECT jsonb_agg(q||jsonb_build_object('floor',u.floor,'managerName',(SELECT us.name FROM public.tower_members mb JOIN public.tower_users us ON us.user_id=mb.user_id WHERE mb.unit_id=u.unit_id AND mb.member_role='MANAGER' AND mb.ended_at IS NULL ORDER BY us.user_id LIMIT 1))) FROM jsonb_array_elements(data) q LEFT JOIN public.tower_units u ON u.unit_id=(q->>'unitId')::uuid),'[]');
END $f$;
REVOKE ALL ON FUNCTION public.tower_service_requests_230(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_requests_230(text) TO service_role;

CREATE OR REPLACE FUNCTION public.tower_service_edit_preview_230(p_token text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE context jsonb;delta numeric;rows jsonb;sid uuid:=(p_payload->>'serviceId')::uuid;
BEGIN
 context:=public.tower_service_edit_context_230(p_token,sid);
 IF (p_payload->>'expectedUpdatedAt')::timestamptz IS DISTINCT FROM (context->>'updatedAt')::timestamptz
 OR coalesce(p_payload->>'expectedProjectVersion','')<>coalesce(context->>'projectVersion','') THEN RAISE EXCEPTION 'TASK_CHANGED_REFRESH'; END IF;
 IF context->>'pricingMode'='SHARED_TOTAL' THEN
  delta:=(p_payload->>'totalBudget')::numeric-(context->>'totalBudget')::numeric;
  IF context->>'enrollment'='FINALIZED' AND delta<>0 THEN
   IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=sid AND distribution='CUSTOM') AND (SELECT coalesce(sum(original_amount),0) FROM public.tower_task_allocation_snapshots WHERE service_id=sid)=0 THEN RAISE EXCEPTION 'CUSTOM_ZERO_BASE_REQUIRES_NEW_AGREEMENT'; END IF;
   WITH weights AS (SELECT x.*,CASE WHEN p.distribution='CUSTOM' THEN x.original_amount ELSE 1 END weight FROM public.tower_task_allocation_snapshots x JOIN public.tower_task_projects p ON p.service_id=x.service_id WHERE x.service_id=sid),
   raw AS(SELECT *,abs(delta)*100*weight/nullif(sum(weight) OVER(),0) exact FROM weights),
   ranked AS(SELECT *,floor(exact) base,row_number() OVER(ORDER BY exact-floor(exact) DESC,unit_id) rn,abs(delta)*100-sum(floor(exact)) OVER() extras FROM raw)
   SELECT jsonb_agg(jsonb_build_object('unitNumber',u.unit_number,'amount',sign(delta)*(base+CASE WHEN rn<=extras THEN 1 ELSE 0 END)/100) ORDER BY r.unit_id) INTO rows FROM ranked r JOIN public.tower_units u ON u.unit_id=r.unit_id;
  END IF;
 END IF;
 RETURN jsonb_build_object('difference',coalesce(delta,0),'allocations',coalesce(rows,'[]'),'reopensAccount',context->>'phase' IN ('CANCELLED','FINANCIAL_CLOSED') AND ((delta IS NOT NULL AND delta<>0) OR p_payload->>'beneficiaryUserId' IS DISTINCT FROM context->>'beneficiaryUserId'));
END $f$;
REVOKE ALL ON FUNCTION public.tower_service_edit_preview_230(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_edit_preview_230(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*__________________________________ End of code...*/
