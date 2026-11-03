/*
Tower App V3.9.4 - SQL_274.
___________________________
Explicit actions only. Installation sends no notification and executes no financial operation.
*/
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_reject_member_394(p_token text,p_request uuid,p_notes text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users;r jsonb;updates text:='status=''REJECTED''';c record;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF length(coalesce(p_notes,''))>2000 THEN RAISE EXCEPTION 'INVALID_NOTES';END IF;
 SELECT to_jsonb(t) INTO r FROM public.tower_member_requests t WHERE request_id=p_request FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MEMBER_REQUEST_NOT_FOUND';END IF;
 IF r->>'status'='REJECTED' THEN RETURN jsonb_build_object('success',true,'status','REJECTED','replayed',true);END IF;
 IF r->>'status'<>'PENDING' THEN RAISE EXCEPTION 'REQUEST_ALREADY_REVIEWED';END IF;
 FOR c IN SELECT attname FROM pg_attribute WHERE attrelid='public.tower_member_requests'::regclass AND attnum>0 AND NOT attisdropped LOOP
  IF c.attname IN ('decided_at','reviewed_at','updated_at') THEN updates:=updates||format(',%I=now()',c.attname);
  ELSIF c.attname IN ('decided_by','reviewed_by') THEN updates:=updates||format(',%I=$2',c.attname);
  ELSIF c.attname IN ('decision_notes','review_notes') OR c.attname='notes' AND NOT (r ? 'decision_notes' OR r ? 'review_notes') THEN updates:=updates||format(',%I=$3',c.attname);END IF;
 END LOOP;
 EXECUTE 'UPDATE public.tower_member_requests SET '||updates||' WHERE request_id=$1 AND status=''PENDING''' USING p_request,a.user_id,coalesce(p_notes,'');
 IF NOT EXISTS(SELECT 1 FROM public.tower_member_requests WHERE request_id=p_request AND status='REJECTED') THEN RAISE EXCEPTION 'MEMBER_REJECTION_NOT_SAVED';END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'REJECT_MEMBER_REQUEST_394','MEMBER_REQUEST',p_request::text);
 RETURN jsonb_build_object('success',true,'status','REJECTED','requestId',p_request);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_operator_trip_notice_394() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $t$
DECLARE names text;
BEGIN
 IF NEW.actor_role<>'OPERATOR' OR NEW.status<>'OPEN' OR NEW.settlement_id IS NOT NULL THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND (NEW.items,NEW.notes) IS NOT DISTINCT FROM (OLD.items,OLD.notes) THEN RETURN NEW;END IF;
 SELECT string_agg(left(x->>'name',60),'، ' ORDER BY ord) INTO names FROM jsonb_array_elements(CASE WHEN jsonb_typeof(NEW.items)='array' THEN NEW.items ELSE '[]'::jsonb END) WITH ORDINALITY e(x,ord) WHERE ord<=5;
 BEGIN
  INSERT INTO public.tower_notifications(unit_id,target_role,type,title,body,entity,entity_id)
  VALUES(NEW.unit_id,'RESIDENT','TRIP',CASE WHEN TG_OP='INSERT' THEN 'الأمين سجّل مشوارًا لوحدتك' ELSE 'الأمين حدّث مشتريات مشوار وحدتك' END,left(coalesce(names,'افتح المشوار لمراجعة البنود'),400),'trip',NEW.trip_id::text);
 EXCEPTION WHEN check_violation THEN
  -- Older notification kind constraints accept SERVICE; routing and unit scope remain trip-specific.
  INSERT INTO public.tower_notifications(unit_id,target_role,type,title,body,entity,entity_id)
  VALUES(NEW.unit_id,'RESIDENT','SERVICE',CASE WHEN TG_OP='INSERT' THEN 'الأمين سجّل مشوارًا لوحدتك' ELSE 'الأمين حدّث مشتريات مشوار وحدتك' END,left(coalesce(names,'افتح المشوار لمراجعة البنود'),400),'trip',NEW.trip_id::text);
 END;
 RETURN NEW;
END $t$;
DROP TRIGGER IF EXISTS tower_operator_trip_notice_394 ON public.tower_trips;
CREATE TRIGGER tower_operator_trip_notice_394 AFTER INSERT OR UPDATE OF items,notes ON public.tower_trips FOR EACH ROW EXECUTE FUNCTION public.tower_operator_trip_notice_394();

CREATE OR REPLACE FUNCTION public.tower_subscriptions_report_394(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $r$
DECLARE a public.tower_users;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('unit',u.unit_number,'service',s.name,'task',s.service_kind='ONE_TIME','shared',s.pricing_mode='SHARED_TOTAL',
 'quantity',sub.quantity,'status',sub.status,'amount',CASE WHEN s.pricing_mode='SHARED_TOTAL' THEN (SELECT coalesce(sum(public.tower_task_due_amount_internal(d.due_id)),0) FROM public.tower_finance_dues d WHERE d.subscription_id=sub.subscription_id AND d.status='OPEN') ELSE sub.amount_snapshot END,
 'allocated',s.enrollment_status='FINALIZED','renewal',CASE WHEN s.service_kind='RECURRING' AND sub.status='ACTIVE' THEN sub.next_renewal_at ELSE NULL END)
 ORDER BY u.unit_number,s.name,sub.requested_at),'[]') INTO rows FROM public.tower_service_subscriptions sub JOIN public.tower_services s ON s.service_id=sub.service_id JOIN public.tower_units u ON u.unit_id=sub.unit_id;
 RETURN jsonb_build_object('rows',rows);
END $r$;

-- Budget-neutral funding adjustment: changes unit liability, never the total project cost.
ALTER TABLE public.tower_task_adjustments ADD COLUMN IF NOT EXISTS funding_amount_394 numeric(16,2) NOT NULL DEFAULT 0;
ALTER TABLE public.tower_task_adjustments DROP CONSTRAINT IF EXISTS tower_task_adjustments_amount_check;
ALTER TABLE public.tower_task_adjustments DROP CONSTRAINT IF EXISTS tower_task_adjustments_funding_check_394;
ALTER TABLE public.tower_task_adjustments ADD CONSTRAINT tower_task_adjustments_funding_check_394 CHECK(
 (amount<>0 AND funding_amount_394=0) OR (amount=0 AND funding_amount_394>0 AND reference LIKE 'funding394:%'));
CREATE OR REPLACE FUNCTION public.tower_task_funding_394(p_token text,p_service uuid,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;t record;d record;amount numeric;balance numeric;total numeric;plan jsonb:='[]';proof text;hashes text:='';h text;tablename text;v numeric;take numeric;leftover numeric;entry uuid;adj uuid;ref text;old public.tower_task_adjustments;idx int;cnt int;allocated numeric:=0;before_due numeric;paid numeric;credit numeric;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action NOT IN ('preview','execute') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 amount:=(p_payload->>'amount')::numeric;
 IF amount IS NULL OR amount<=0 OR amount<>round(amount,2) THEN RAISE EXCEPTION 'INVALID_AMOUNT';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service FOR UPDATE;
 IF NOT FOUND OR s.service_kind<>'ONE_TIME' OR s.pricing_mode<>'SHARED_TOTAL' OR s.enrollment_status<>'FINALIZED' OR s.status<>'ACTIVE' THEN RAISE EXCEPTION 'FINALIZED_ACTIVE_TASK_REQUIRED';END IF;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=p_service FOR UPDATE;
 IF NOT FOUND THEN p.service_id:=p_service;p.phase:='PARTICIPATION';p.version:=0;END IF;
 IF p.phase IN ('PROPOSAL','CANCELLED','FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED';END IF;
 ref:='funding394:'||coalesce(p_payload->>'reference','');
 IF p_action='execute' THEN
  IF length(ref) NOT BETWEEN 27 AND 110 THEN RAISE EXCEPTION 'REFERENCE_REQUIRED';END IF;
  SELECT * INTO old FROM public.tower_task_adjustments WHERE service_id=p_service AND reference=ref;
  IF FOUND THEN
   IF old.proposed_by<>a.user_id OR old.funding_amount_394<>amount THEN RAISE EXCEPTION 'REFERENCE_CONFLICT';END IF;
   RETURN jsonb_build_object('success',true,'replayed',true);
  END IF;
 END IF;
 IF (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN RAISE EXCEPTION 'UNIQUE_ACTIVE_TASK_ACCOUNT_REQUIRED';END IF;
 IF EXISTS(SELECT 1 FROM public.tower_task_fund_contributions WHERE service_id=p_service) THEN RAISE EXCEPTION 'TASK_FUND_CONTRIBUTION_ALREADY_POSTED';END IF;
 -- Lock the existing ledger writers and all allocation/refund state used by the proof.
 FOR tablename IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND (c.relname LIKE 'tower\_finance\_%' ESCAPE '\' OR c.relname LIKE 'tower\_task\_%' ESCAPE '\' OR c.relname IN ('tower_fund_entries','tower_service_subscriptions')) ORDER BY c.relname LOOP
  EXECUTE format('LOCK TABLE public.%I IN SHARE ROW EXCLUSIVE MODE',tablename);
  EXECUTE format('SELECT md5(coalesce(string_agg(to_jsonb(t)::text,E''\n'' ORDER BY to_jsonb(t)::text),'''')) FROM public.%I t',tablename) INTO h;
  hashes:=hashes||tablename||':'||h||';';
 END LOOP;
 SELECT coalesce(sum(CASE WHEN f.entry_type='INCOME' THEN f.amount ELSE -f.amount END),0) INTO balance FROM public.tower_fund_entries f WHERE f.status='ACTIVE';
 SELECT coalesce(sum(public.tower_task_due_amount_internal(fd.due_id)),0) INTO total FROM public.tower_finance_dues fd JOIN public.tower_service_subscriptions sub ON sub.subscription_id=fd.subscription_id WHERE sub.service_id=p_service AND fd.status='OPEN';
 IF amount>total THEN RAISE EXCEPTION 'FUNDING_EXCEEDS_UNIT_LIABILITY';END IF;
 IF amount>balance THEN RAISE EXCEPTION 'INSUFFICIENT_FUND_BALANCE';END IF;
 DROP TABLE IF EXISTS pg_temp.tower_funding_plan394;
 CREATE TEMP TABLE tower_funding_plan394(subscription_id uuid PRIMARY KEY,unit_id uuid,due numeric,paid numeric,reduction numeric) ON COMMIT DROP;
 INSERT INTO tower_funding_plan394
 SELECT sub.subscription_id,sub.unit_id,sum(public.tower_task_due_amount_internal(fd.due_id)),sum(public.tower_task_due_paid_internal(fd.due_id)),0
 FROM public.tower_service_subscriptions sub JOIN public.tower_finance_dues fd ON fd.subscription_id=sub.subscription_id AND fd.status='OPEN'
 WHERE sub.service_id=p_service GROUP BY sub.subscription_id,sub.unit_id HAVING sum(public.tower_task_due_amount_internal(fd.due_id))>0;
 UPDATE tower_funding_plan394 SET reduction=trunc(amount*due/total,2);
 SELECT round((amount-sum(reduction))*100)::integer INTO cnt FROM tower_funding_plan394;
 FOR t IN SELECT * FROM tower_funding_plan394 ORDER BY (amount*due/total-reduction) DESC,unit_id,subscription_id LIMIT cnt LOOP
  UPDATE tower_funding_plan394 SET reduction=reduction+.01 WHERE subscription_id=t.subscription_id;
 END LOOP;
 SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',x.unit_id,'unitNumber',u.unit_number,'before',x.due,'paid',x.paid,'reduction',x.reduction,'after',x.due-x.reduction,'remaining',greatest(0,x.due-x.reduction-x.paid),'credit',greatest(0,x.paid-x.due+x.reduction)) ORDER BY u.unit_number,x.unit_id),'[]') INTO plan FROM tower_funding_plan394 x JOIN public.tower_units u ON u.unit_id=x.unit_id;
 proof:=md5(a.user_id::text||':'||to_jsonb(s)::text||':'||to_jsonb(p)::text||':'||amount::text||':'||balance::text||':'||hashes||':'||plan::text);
 IF p_action='preview' THEN RETURN jsonb_build_object('previewToken',proof,'amount',amount,'fundBalance',balance,'fundAfter',balance-amount,'rows',plan,'budgetUnchanged',true);END IF;
 IF p_payload->>'previewToken' IS DISTINCT FROM proof OR p_payload->>'confirmed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FUNDING_PREVIEW_CHANGED';END IF;
 entry:=gen_random_uuid();adj:=gen_random_uuid();
 INSERT INTO public.tower_fund_entries(entry_id,entry_type,category,description,amount,reference,status,created_by,created_at)
 VALUES(entry,'EXPENSE','صيانة','تمويل مهمة بعد اعتماد التوزيع: '||left(s.name,200),amount,'TASK_FUND_CONTRIBUTION:'||p_service::text,'ACTIVE',a.user_id,now());
 INSERT INTO public.tower_task_fund_contributions(service_id,fund_entry_id,amount,posted_by) VALUES(p_service,entry,amount,a.user_id);
 INSERT INTO public.tower_task_adjustments(adjustment_id,service_id,reference,amount,funding_amount_394,reason,state,proposed_by,approved_by,approved_at)
 VALUES(adj,p_service,ref,0,amount,'تمويل من الصندوق بعد اعتماد التوزيع؛ تكلفة المهمة لم تتغير','APPROVED',a.user_id,a.user_id,now());
 FOR t IN SELECT * FROM tower_funding_plan394 WHERE reduction>0 ORDER BY unit_id LOOP
  INSERT INTO public.tower_task_adjustment_lines(adjustment_id,subscription_id,amount) VALUES(adj,t.subscription_id,-t.reduction);
  leftover:=t.reduction;
  -- Reduce unpaid liability first, preserving paid cash and creating refundable credit where appropriate.
  FOR d IN SELECT fd.due_id,greatest(0,public.tower_task_due_amount_internal(fd.due_id)-public.tower_task_due_paid_internal(fd.due_id)) available FROM public.tower_finance_dues fd WHERE fd.subscription_id=t.subscription_id AND fd.status='OPEN' ORDER BY fd.due_date DESC,fd.due_id DESC LOOP
   take:=least(leftover,d.available);IF take>0 THEN INSERT INTO public.tower_task_due_credits VALUES(adj,d.due_id,take);leftover:=leftover-take;END IF;EXIT WHEN leftover=0;
  END LOOP;
  IF leftover>0 THEN
   FOR d IN SELECT fd.due_id,public.tower_task_due_amount_internal(fd.due_id) available FROM public.tower_finance_dues fd WHERE fd.subscription_id=t.subscription_id AND fd.status='OPEN' ORDER BY fd.due_date DESC,fd.due_id DESC LOOP
    take:=least(leftover,d.available);IF take>0 THEN INSERT INTO public.tower_task_due_credits VALUES(adj,d.due_id,take) ON CONFLICT(adjustment_id,due_id) DO UPDATE SET amount=tower_task_due_credits.amount+excluded.amount;leftover:=leftover-take;END IF;EXIT WHEN leftover=0;
   END LOOP;
  END IF;
  IF leftover<>0 THEN RAISE EXCEPTION 'FUNDING_ALLOCATION_CHANGED';END IF;
 END LOOP;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_FUNDING_AFTER_ALLOCATION_394','SERVICE',p_service::text);
 RETURN jsonb_build_object('success',true,'amount',amount,'fundEntryId',entry,'receiptPending',true);
END $f$;
REVOKE ALL ON FUNCTION public.tower_reject_member_394(text,uuid,text),public.tower_subscriptions_report_394(text),public.tower_task_funding_394(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_reject_member_394(text,uuid,text),public.tower_subscriptions_report_394(text),public.tower_task_funding_394(text,uuid,text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.tower_task_report_394(p_token text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $tr$
DECLARE a public.tower_users;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('name',s.name,'allocated',s.enrollment_status='FINALIZED',
 'budget',s.total_budget+coalesce((SELECT sum(ad.amount) FROM public.tower_task_adjustments ad WHERE ad.service_id=s.service_id AND ad.state='APPROVED'),0),
 'fund',coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=s.service_id),0),
 'due',coalesce((SELECT sum(public.tower_task_due_amount_internal(fd.due_id)) FROM public.tower_finance_dues fd JOIN public.tower_service_subscriptions sub ON sub.subscription_id=fd.subscription_id WHERE sub.service_id=s.service_id AND fd.status='OPEN'),0),
 'paid',coalesce((SELECT sum(least(public.tower_task_due_amount_internal(fd.due_id),public.tower_task_due_paid_internal(fd.due_id))) FROM public.tower_finance_dues fd JOIN public.tower_service_subscriptions sub ON sub.subscription_id=fd.subscription_id WHERE sub.service_id=s.service_id AND fd.status='OPEN'),0),
 'remaining',coalesce((SELECT sum(greatest(0,public.tower_task_due_amount_internal(fd.due_id)-public.tower_task_due_paid_internal(fd.due_id))) FROM public.tower_finance_dues fd JOIN public.tower_service_subscriptions sub ON sub.subscription_id=fd.subscription_id WHERE sub.service_id=s.service_id AND fd.status='OPEN'),0),
 'expenses',coalesce((SELECT sum(e.amount) FROM public.tower_task_expenses e WHERE e.service_id=s.service_id AND e.state='APPROVED'),0)) ORDER BY s.name),'[]') INTO rows FROM public.tower_services s WHERE s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL';
 RETURN jsonb_build_object('rows',rows);
END $tr$;
REVOKE ALL ON FUNCTION public.tower_task_report_394(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_report_394(text) TO service_role;

-- Persistent unit-to-facade mapping. Bootstrap existing numbered apartments only on first installation.
DO $init$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.tower_units'::regclass AND attname='facade_slot_394' AND NOT attisdropped) THEN
  ALTER TABLE public.tower_units ADD COLUMN facade_slot_394 text;
  WITH candidates AS (SELECT unit_id,CASE WHEN translate(btrim(unit_number),'٠١٢٣٤٥٦٧٨٩','0123456789') ~ '^0*([1-9]|[12][0-9]|3[0-8])$' THEN 'APT_'||(translate(btrim(unit_number),'٠١٢٣٤٥٦٧٨٩','0123456789')::int)::text
   WHEN translate(btrim(unit_number),'٠١٢٣٤٥٦٧٨٩','0123456789') ~ '^محل[ ]*0*[1-4]$' THEN 'SHOP_'||(regexp_replace(translate(btrim(unit_number),'٠١٢٣٤٥٦٧٨٩','0123456789'),'[^0-9]','','g')::int)::text ELSE NULL END slot FROM public.tower_units),unique_slots AS(SELECT slot FROM candidates WHERE slot IS NOT NULL GROUP BY slot HAVING count(*)=1)
  UPDATE public.tower_units u SET facade_slot_394=c.slot FROM candidates c JOIN unique_slots q ON q.slot=c.slot WHERE c.unit_id=u.unit_id;
 END IF;
END $init$;
CREATE UNIQUE INDEX IF NOT EXISTS tower_units_facade_unique394 ON public.tower_units(facade_slot_394) WHERE facade_slot_394 IS NOT NULL;
ALTER TABLE public.tower_units DROP CONSTRAINT IF EXISTS tower_units_facade_allowed394;
ALTER TABLE public.tower_units ADD CONSTRAINT tower_units_facade_allowed394 CHECK(facade_slot_394 IS NULL OR facade_slot_394 ~ '^(APT_([1-9]|[12][0-9]|3[0-8])|SHOP_[1-4])$');
CREATE OR REPLACE FUNCTION public.tower_building_slots_394(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $m$
DECLARE a public.tower_users;slot text;id uuid;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action='list' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',u.unit_id,'slot',u.facade_slot_394) ORDER BY u.unit_id),'[]') INTO rows FROM public.tower_units u
  WHERE a.role IN ('ADMIN','UNION') OR a.role='RESIDENT' AND u.status='ACTIVE' AND EXISTS(SELECT 1 FROM public.tower_members m WHERE m.unit_id=u.unit_id AND m.user_id=a.user_id AND m.ended_at IS NULL);
  RETURN rows;
 END IF;
 IF p_action<>'save' OR p_action IS NULL OR a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 id:=(p_payload->>'unitId')::uuid;slot:=nullif(p_payload->>'slot','');
 IF slot IS NOT NULL AND slot !~ '^(APT_([1-9]|[12][0-9]|3[0-8])|SHOP_[1-4])$' THEN RAISE EXCEPTION 'INVALID_FACADE_SLOT';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 IF NOT EXISTS(SELECT 1 FROM public.tower_units WHERE unit_id=id) THEN RAISE EXCEPTION 'UNIT_NOT_FOUND';END IF;
 IF slot IS NOT NULL AND EXISTS(SELECT 1 FROM public.tower_units WHERE facade_slot_394=slot AND unit_id<>id) THEN RAISE EXCEPTION 'FACADE_SLOT_ALREADY_USED';END IF;
 UPDATE public.tower_units SET facade_slot_394=slot WHERE unit_id=id;
 RETURN jsonb_build_object('success',true,'unitId',id,'slot',slot);
END $m$;
CREATE OR REPLACE FUNCTION public.tower_unit_facade_mutate_394(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $u$
DECLARE result jsonb;id uuid;
BEGIN
 result:=to_jsonb(public.tower_unit_mutate_262(p_token,p_action,p_payload-'facadeSlot394'));
 IF p_action IN ('create','update') AND p_payload ? 'facadeSlot394' THEN
  IF p_action='create' THEN id:=nullif(result->>'unitId','')::uuid;ELSE id:=(p_payload->>'unitId')::uuid;END IF;
  IF id IS NULL THEN RAISE EXCEPTION 'UNIT_NOT_FOUND';END IF;
  PERFORM public.tower_building_slots_394(p_token,'save',jsonb_build_object('unitId',id,'slot',p_payload->>'facadeSlot394'));
 END IF;
 RETURN result;
END $u$;
REVOKE ALL ON FUNCTION public.tower_building_slots_394(text,text,jsonb),public.tower_unit_facade_mutate_394(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_building_slots_394(text,text,jsonb),public.tower_unit_facade_mutate_394(text,text,jsonb) TO service_role;

NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.9.4 - SQL_274.
Code End
*/
