-- Tower App V2.5.175. Install after SQL231. No historical balances or account scopes are changed.
BEGIN;
DO $f$ BEGIN
 IF to_regprocedure('public.tower_task_workspace_read_231(text,uuid,uuid)') IS NULL THEN
  RAISE EXCEPTION 'SQL231_REQUIRED';
 END IF;
END $f$;

-- Also runs on direct database writes; the browser cannot override start prerequisites.
CREATE OR REPLACE FUNCTION public.tower_task_start_guard_232() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE s public.tower_services; minimum numeric; due numeric; paid numeric; money_ok boolean; date_ok boolean; previous_stage text;
BEGIN
 IF NEW.stage NOT IN ('READY','IN_PROGRESS','COMPLETED') THEN RETURN NEW; END IF;
 -- Updating progress on work already started does not retroactively undo execution.
 IF TG_OP='INSERT' THEN
  SELECT stage INTO previous_stage FROM public.tower_task_workflow WHERE service_id=NEW.service_id;
 ELSE previous_stage:=OLD.stage; END IF;
 IF previous_stage IN ('IN_PROGRESS','COMPLETED') AND NEW.stage IN ('IN_PROGRESS','COMPLETED') THEN RETURN NEW; END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=NEW.service_id;
 IF NOT FOUND OR s.enrollment_status<>'FINALIZED' THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
 SELECT coalesce(minimum_start_amount,0) INTO minimum FROM public.tower_task_projects WHERE service_id=NEW.service_id;
 minimum:=coalesce(minimum,0);
 SELECT coalesce(sum(public.tower_task_due_amount_internal(d.due_id)),0),
        coalesce(sum(least(public.tower_task_due_amount_internal(d.due_id),public.tower_task_due_paid_internal(d.due_id))),0)
 INTO due,paid FROM public.tower_finance_dues d
 JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
 WHERE sub.service_id=NEW.service_id AND d.status='OPEN';
 money_ok:=CASE WHEN minimum>0 THEN paid>=minimum ELSE paid*100>=due*NEW.collection_threshold END;
 date_ok:=NEW.execution_date IS NOT NULL AND NEW.execution_date<=current_date;
 IF NEW.start_rule IN ('DATE','DATE_AND_COLLECTION') AND NOT date_ok THEN RAISE EXCEPTION 'TASK_START_DATE_NOT_REACHED'; END IF;
 IF ((NEW.start_rule IN ('COLLECTION','DATE_AND_COLLECTION')) OR minimum>0) AND NOT money_ok THEN
  RAISE EXCEPTION 'TASK_START_COLLECTION_NOT_REACHED';
 END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_start_guard_232 ON public.tower_task_workflow;
CREATE TRIGGER tower_task_start_guard_232 BEFORE INSERT OR UPDATE ON public.tower_task_workflow
 FOR EACH ROW EXECUTE FUNCTION public.tower_task_start_guard_232();
REVOKE ALL ON FUNCTION public.tower_task_start_guard_232() FROM PUBLIC,anon,authenticated,service_role;

-- Read model for ordinary services, with explicit resident unit scope and separate recorded dues.
CREATE OR REPLACE FUNCTION public.tower_service_workspace_read_232(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;admin boolean;is_manager boolean:=false;
 account public.tower_finance_accounts;account_count integer;unit_number text;subs jsonb;changes jsonb;records jsonb;balances jsonb;totals jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 admin:=a.role IN ('ADMIN','UNION');
 IF NOT admin AND a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF NOT admin THEN
  IF p_unit IS NULL THEN RAISE EXCEPTION 'UNIT_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id
    WHERE m.user_id=a.user_id AND m.unit_id=p_unit AND m.ended_at IS NULL AND u.status='ACTIVE') THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
  SELECT EXISTS(SELECT 1 FROM public.tower_members WHERE user_id=a.user_id AND unit_id=p_unit AND ended_at IS NULL AND member_role='MANAGER') INTO is_manager;
  SELECT u.unit_number INTO unit_number FROM public.tower_units u WHERE u.unit_id=p_unit;
 END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service;
 IF NOT FOUND OR (NOT admin AND s.status<>'ACTIVE' AND NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND unit_id=p_unit)) THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
 IF s.pricing_mode='SHARED_TOTAL' THEN RAISE EXCEPTION 'USE_TASK_WORKSPACE'; END IF;
 SELECT count(*) INTO account_count FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE';
 IF account_count>1 THEN RAISE EXCEPTION 'SERVICE_ACCOUNT_CONFLICT'; END IF;
 SELECT * INTO account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE';
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'subscriptionId',x.subscription_id,'serviceId',x.service_id,'unitId',x.unit_id,'unitNumber',u.unit_number,'floor',u.floor,
  'unitStatus',u.status,'status',x.status,'quantity',x.quantity,'unitPriceSnapshot',x.unit_price_snapshot,'amountSnapshot',x.amount_snapshot,
  'billingTiming',x.billing_timing,'autoRenew',x.auto_renew,'nextRenewalAt',x.next_renewal_at,
  'requestedAt',x.requested_at,'startedAt',x.started_at,'endedAt',x.ended_at,
  'managerName',coalesce((SELECT string_agg(public.tower_person_label_231(person.name,person.title,person.user_id),'، ' ORDER BY person.user_id)
   FROM public.tower_members m JOIN public.tower_users person ON person.user_id=m.user_id
   WHERE m.unit_id=x.unit_id AND m.member_role='MANAGER' AND m.ended_at IS NULL),'غير محدد')) ORDER BY x.requested_at DESC,x.subscription_id),'[]'::jsonb)
 INTO subs FROM public.tower_service_subscriptions x JOIN public.tower_units u ON u.unit_id=x.unit_id
 WHERE x.service_id=p_service AND (admin OR x.unit_id=p_unit);
 SELECT coalesce(jsonb_agg(jsonb_build_object('requestId',r.request_id,'subscriptionId',r.subscription_id,'serviceId',r.service_id,
  'unitId',r.unit_id,'unitNumber',u.unit_number,'floor',u.floor,'type',r.type,'quantityDelta',r.quantity_delta,
  'requestedQuantity',r.requested_quantity,'status',r.status,'requestedAt',r.requested_at) ORDER BY r.requested_at DESC,r.request_id),'[]'::jsonb)
 INTO changes FROM public.tower_service_change_requests r JOIN public.tower_units u ON u.unit_id=r.unit_id
 WHERE r.service_id=p_service AND (admin OR r.unit_id=p_unit);
 -- Personal dues include posted direct receipts and applied advances; scheduled prices are never debts.
 SELECT coalesce(jsonb_agg(row ORDER BY due_date,record_id),'[]'::jsonb) INTO records FROM (
  SELECT d.due_date,d.due_id record_id,jsonb_build_object('recordId',d.due_id,'source','PERSONAL','subscriptionId',d.subscription_id,
   'unitId',d.unit_id,'unitNumber',u.unit_number,'floor',u.floor,'unitStatus',u.status,'dueDate',d.due_date,'accountId',d.account_id,
   'accountStatus',ac.status,'amount',public.tower_task_due_amount_internal(d.due_id),
   'paid',least(public.tower_task_due_amount_internal(d.due_id),public.tower_task_due_paid_internal(d.due_id)),
   'remaining',greatest(0,public.tower_task_due_amount_internal(d.due_id)-public.tower_task_due_paid_internal(d.due_id))) row
  FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
  JOIN public.tower_finance_accounts ac ON ac.account_id=d.account_id AND ac.account_kind='PERSONAL_SERVICE' AND ac.service_id=p_service
  JOIN public.tower_units u ON u.unit_id=d.unit_id
  WHERE sub.service_id=p_service AND d.status='OPEN' AND (admin OR d.unit_id=p_unit)
  UNION ALL
  SELECT c.due_date,al.allocation_id,jsonb_build_object('recordId',al.allocation_id,'source','FUND','chargeId',c.charge_id,
   'subscriptionId',c.subscription_id,'unitId',al.unit_id,'unitNumber',u.unit_number,'floor',u.floor,'unitStatus',u.status,
   'dueDate',c.due_date,'period',c.period_label,'amount',al.amount,'paid',al.paid,'remaining',greatest(0,al.amount-al.paid))
  FROM public.tower_building_allocations al JOIN public.tower_building_charges c ON c.charge_id=al.charge_id
  LEFT JOIN public.tower_service_subscriptions sub ON sub.subscription_id=c.subscription_id
  JOIN public.tower_units u ON u.unit_id=al.unit_id
  WHERE coalesce(c.service_id,sub.service_id)=p_service AND c.status='ACTIVE' AND al.status='ACTIVE' AND (admin OR al.unit_id=p_unit)
 ) q;
 SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',unit_id,'state','RECORDED','due',due,'paid',paid,'remaining',remaining,'recordCount',cnt) ORDER BY unit_id),'[]'::jsonb)
 INTO balances FROM (SELECT (r->>'unitId')::uuid unit_id,sum((r->>'amount')::numeric) due,sum((r->>'paid')::numeric) paid,
  sum((r->>'remaining')::numeric) remaining,count(*) cnt FROM jsonb_array_elements(records) r GROUP BY r->>'unitId') b;
 SELECT jsonb_build_object('state',CASE WHEN count(*)>0 THEN 'RECORDED' ELSE 'NOT_RECORDED' END,
  'due',coalesce(sum((r->>'amount')::numeric),0),'paid',coalesce(sum((r->>'paid')::numeric),0),
  'remaining',coalesce(sum((r->>'remaining')::numeric),0),'recordCount',count(*))
 INTO totals FROM jsonb_array_elements(records) r;
 RETURN public.tower_present_names_231(jsonb_build_object('serviceId',p_service,'canManage',admin,'isUnitManager',is_manager,
  'unitId',CASE WHEN admin THEN NULL ELSE p_unit END,'unitNumber',CASE WHEN admin THEN NULL ELSE unit_number END,
  'service',jsonb_build_object('serviceId',p_service,'name',s.name,'description',s.description,'price',s.price,
   'billingCycle',CASE WHEN s.service_kind='RECURRING' THEN 'MONTHLY' ELSE 'ONE_TIME' END,'billingTiming',s.billing_timing,
   'allowQuantity',s.allow_quantity,'cancelable',s.cancelable,'autoRenewDefault',s.service_kind='RECURRING','status',s.status,
   'serviceKind',s.service_kind,'pricingMode',s.pricing_mode,'revenueKind',CASE WHEN account_count=0 THEN 'FUND' ELSE 'PERSONAL_SERVICE' END,
   'financeAccountId',account.account_id,'accountStatus',account.status,'beneficiaryUserId',account.beneficiary_user_id,
   'beneficiaryName',(SELECT public.tower_person_label_231(name,title,user_id) FROM public.tower_users WHERE user_id=account.beneficiary_user_id)),
  'subscriptions',subs,'changes',changes,'records',records,'balances',balances,'totals',totals));
END $f$;
REVOKE ALL ON FUNCTION public.tower_service_workspace_read_232(text,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_workspace_read_232(text,uuid,uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*__________________________________ End of code...*/
