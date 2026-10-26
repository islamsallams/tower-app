/*
Tower App V2.5.180 - SQL_235.

___________________________
*/
BEGIN;
DO $check$ BEGIN
 IF to_regprocedure('public.tower_unit_membership_234(text,text,jsonb)') IS NULL OR to_regprocedure('public.tower_task_installments_action(text,uuid,text)') IS NULL OR to_regprocedure('public.tower_task_workflow_action(text,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'SQL234_REQUIRED'; END IF;
END $check$;
CREATE OR REPLACE FUNCTION public.tower_task_controls_235(p_token text,p_service uuid,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;w public.tower_task_workflow;meta jsonb;plan jsonb;receipt jsonb;patch jsonb;payload jsonb;allowed text[];k text;reason text;first_day date;revision_value integer;had_workflow boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.must_change_pin THEN RAISE EXCEPTION 'PIN_CHANGE_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
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
REVOKE ALL ON FUNCTION public.tower_task_controls_235(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_controls_235(text,uuid,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.180 - SQL_235.

Code End
*/
