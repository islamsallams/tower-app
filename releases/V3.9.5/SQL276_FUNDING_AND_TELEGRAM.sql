/* Tower App V3.9.5 — SQL276. Requires SQL274. No funding, old notices, or old decisions executed at installation. */
BEGIN;
DO $check$ BEGIN
 IF to_regprocedure('public.tower_task_funding_394(text,uuid,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'SQL274_REQUIRED'; END IF;
END $check$;
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
 UPDATE tower_funding_plan394 SET reduction=trunc(amount*due/total,2) WHERE due>0;
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
REVOKE ALL ON FUNCTION public.tower_task_funding_394(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_funding_394(text,uuid,text,jsonb) TO service_role;

-- Fresh, recipient-scoped projection. It is never a public API and never accepts arbitrary trip IDs.
CREATE OR REPLACE FUNCTION public.tower_telegram_content_395(p_delivery uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $tg$
DECLARE l record;n public.tower_notifications;u public.tower_users;acct record;t public.tower_trips;st public.tower_trip_settlements;unit_label text;sender text;items jsonb;kind text;show_money boolean;
BEGIN
 SELECT user_id,event_key INTO l FROM public.tower_telegram_delivery_log WHERE delivery_id=p_delivery;
 IF NOT FOUND OR l.event_key !~ '^notification:[0-9a-fA-F-]{36}$' THEN RETURN NULL;END IF;
 SELECT * INTO n FROM public.tower_notifications WHERE notification_id=substring(l.event_key FROM 14)::uuid;
 IF NOT FOUND OR lower(coalesce(n.entity,'')) NOT IN ('trip','trip_settlement','settlement') THEN RETURN NULL;END IF;
 SELECT * INTO u FROM public.tower_users WHERE user_id=l.user_id AND status='ACTIVE' AND NOT must_change_pin;
 IF NOT FOUND THEN RETURN jsonb_build_object('skip',true);END IF;
 SELECT chat_id,show_amounts INTO acct FROM public.tower_telegram_accounts WHERE user_id=u.user_id AND enabled;
 IF NOT FOUND THEN RETURN jsonb_build_object('skip',true);END IF;
 IF (n.user_id IS NOT NULL AND n.user_id<>u.user_id) OR (n.target_role IS NOT NULL AND n.target_role<>u.role) THEN RETURN jsonb_build_object('skip',true);END IF;
 IF u.role='RESIDENT' THEN
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units un USING(unit_id) WHERE m.unit_id=n.unit_id AND m.user_id=u.user_id AND m.ended_at IS NULL AND un.status='ACTIVE') THEN RETURN jsonb_build_object('skip',true);END IF;
 ELSIF u.role<>'OPERATOR' THEN RETURN NULL;
 END IF;
 show_money:=coalesce(acct.show_amounts,false) AND u.role='RESIDENT';
 SELECT unit_number INTO unit_label FROM public.tower_units WHERE unit_id=n.unit_id;
 IF lower(n.entity)='trip' THEN
  SELECT * INTO t FROM public.tower_trips WHERE trip_id=n.entity_id::uuid AND unit_id=n.unit_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('skip',true);END IF;
  SELECT public.tower_person_label_231(p.name,coalesce(nullif(p.custom_title,''),p.title),p.user_id) INTO sender FROM public.tower_users p WHERE p.user_id=t.created_by;
  SELECT coalesce(jsonb_agg(jsonb_build_object('name',left(coalesce(x->>'name','بند'),80))||CASE WHEN show_money THEN jsonb_build_object('price',x->'price') ELSE '{}'::jsonb END ORDER BY ord),'[]'::jsonb) INTO items
   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.items)='array' THEN t.items ELSE '[]'::jsonb END) WITH ORDINALITY e(x,ord) WHERE ord<=20;
  kind:=CASE WHEN t.status='CANCELED' THEN 'canceled' WHEN n.title ~ '(حدّث|تعديل|تحديث)' THEN 'updated' ELSE 'created' END;
  RETURN jsonb_build_object('entity','trip','entityId',t.trip_id,'unitId',t.unit_id,'owner',u.user_id,'chatId',acct.chat_id,'unitNumber',unit_label,'sender',sender,'kind',kind,'items',items,'moreItems',greatest(0,jsonb_array_length(CASE WHEN jsonb_typeof(t.items)='array' THEN t.items ELSE '[]'::jsonb END)-20),'note',left(coalesce(t.notes,''),200),'showAmounts',show_money)
   ||CASE WHEN show_money THEN jsonb_build_object('purchases',t.purchases_total,'distance',t.distance,'distanceFee',t.distance_fee,'extraFee',t.extra_fee,'total',t.total_due,
    'missingPrices',EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.items)='array' THEN t.items ELSE '[]'::jsonb END) x WHERE x->>'price' IS NULL OR btrim(x->>'price')='')) ELSE '{}'::jsonb END;
 END IF;
 SELECT * INTO st FROM public.tower_trip_settlements WHERE settlement_id=n.entity_id::uuid AND unit_id=n.unit_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('skip',true);END IF;
 RETURN jsonb_build_object('entity','trip_settlement','entityId',st.settlement_id,'unitId',st.unit_id,'owner',u.user_id,'chatId',acct.chat_id,'unitNumber',unit_label,'sequence',st.sequence_no,'kind',CASE WHEN st.status='CANCELED' THEN 'canceled' ELSE 'approved' END,'showAmounts',show_money)
  ||CASE WHEN show_money THEN jsonb_build_object('purchases',st.purchases_total,'fees',st.fees_total,'total',st.gross_total,'priorPayments',st.prior_payments,'closingPayment',st.closing_payment,'credit',st.credit_after) ELSE '{}'::jsonb END;
END $tg$;
REVOKE ALL ON FUNCTION public.tower_telegram_content_395(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_telegram_content_395(uuid) TO service_role;

-- Runs only for future transitions; existing notification/push/Telegram enqueue triggers remain installed.
CREATE OR REPLACE FUNCTION public.tower_settlement_notice_395() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $notice$
DECLARE recipient_role text;heading text;
BEGIN
 IF NEW.status NOT IN ('ACTIVE','CANCELED') OR (TG_OP='UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status) THEN RETURN NEW;END IF;
 heading:=CASE WHEN NEW.status='CANCELED' THEN 'تم التراجع عن تسوية المشاوير' ELSE 'تم اعتماد تسوية المشاوير' END;
 FOREACH recipient_role IN ARRAY ARRAY['RESIDENT','OPERATOR'] LOOP
  IF EXISTS(SELECT 1 FROM public.tower_notifications n WHERE n.entity_id=NEW.settlement_id::text AND lower(n.entity) IN ('settlement','trip_settlement') AND n.unit_id=NEW.unit_id AND n.user_id IS NULL AND (n.target_role=recipient_role OR n.target_role IS NULL)
   AND CASE WHEN NEW.status='CANCELED' THEN n.title ~ '(التراجع|إلغاء|إلغاء)' ELSE n.title !~ '(التراجع|إلغاء)' END) THEN CONTINUE;END IF;
  BEGIN
   INSERT INTO public.tower_notifications(unit_id,target_role,type,title,body,entity,entity_id)
    VALUES(NEW.unit_id,recipient_role,'SETTLEMENT',heading,'افتح التطبيق لمراجعة تفاصيل التسوية.','trip_settlement',NEW.settlement_id::text);
  EXCEPTION WHEN check_violation THEN
   INSERT INTO public.tower_notifications(unit_id,target_role,type,title,body,entity,entity_id)
    VALUES(NEW.unit_id,recipient_role,'SERVICE',heading,'افتح التطبيق لمراجعة تفاصيل التسوية.','trip_settlement',NEW.settlement_id::text);
  END;
 END LOOP;
 RETURN NEW;
END $notice$;
REVOKE ALL ON FUNCTION public.tower_settlement_notice_395() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER IF EXISTS zz_tower_settlement_notice_395 ON public.tower_trip_settlements;
CREATE TRIGGER zz_tower_settlement_notice_395 AFTER INSERT OR UPDATE OF status ON public.tower_trip_settlements FOR EACH ROW EXECUTE FUNCTION public.tower_settlement_notice_395();
NOTIFY pgrst,'reload schema';
COMMIT;
