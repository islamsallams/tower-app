/*
Tower App V3.9.8 - SQL_279_280.
___________________________
*/
BEGIN;
/*
Tower App V3.9.8 - SQL_279.

___________________________
*/

SET LOCAL lock_timeout='10s';
CREATE OR REPLACE FUNCTION public.tower_trip_unpriced_279(p_items jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path TO pg_catalog AS $u$
 SELECT CASE WHEN jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN true ELSE EXISTS(
 SELECT 1 FROM jsonb_array_elements(p_items) item WHERE item->>'price' IS NULL OR btrim(item->>'price')='' OR jsonb_typeof(item->'price') NOT IN ('number','string')) END;
$u$;
REVOKE ALL ON FUNCTION public.tower_trip_unpriced_279(jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_trip_settlement_action_244(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp AS $f$
DECLARE
 actor public.tower_users;uid uuid;sett public.tower_trip_settlements;request_row public.tower_trip_close_requests_244;
 missing_count integer;exclude_missing boolean:=false;
 n integer;purchases numeric(14,2);fees numeric(14,2);gross numeric(14,2);paid numeric(14,2);before_paid numeric(14,2);
 additional numeric(14,2):=0;cash numeric(14,2);closing numeric(14,2);credit numeric(14,2);explicit_cash boolean;
 sid uuid;pid uuid;cash_pid uuid;seq integer;manager_user uuid;manager_name text;revision text;rid text;value_text text;out jsonb;fields jsonb;identity_payload jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('preview','close','undo','summary','details','paymentDetails') OR p_action IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 BEGIN uid:=nullif(p_payload->>'unitId','')::uuid;EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'INVALID_UNIT_ID';END;
 IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id
  WHERE m.user_id=actor.user_id AND m.unit_id=uid AND m.ended_at IS NULL AND u.status='ACTIVE') THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 IF p_action IN ('preview','close','undo') THEN PERFORM 1 FROM public.tower_units WHERE unit_id=uid FOR UPDATE; END IF;
 IF p_action IN ('preview','close') THEN
  IF p_payload ? 'excludeUnpriced' AND jsonb_typeof(p_payload->'excludeUnpriced')<>'boolean' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
  exclude_missing:=coalesce((p_payload->>'excludeUnpriced')::boolean,false);
  PERFORM 1 FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL ORDER BY trip_id FOR UPDATE;
  SELECT count(*) INTO missing_count FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL AND public.tower_trip_unpriced_279(items);
 END IF;
 IF p_action='summary' THEN
  out:=public.tower_trip_account(p_token,'summary',p_payload);
  fields:=public.tower_trip_settlement_fields_244(p_token,ARRAY(SELECT (x->>'settlementId')::uuid FROM jsonb_array_elements(coalesce(out->'settlements','[]')) x));
  RETURN jsonb_set(out,'{settlements}',coalesce((SELECT jsonb_agg(x||coalesce((SELECT f FROM jsonb_array_elements(fields) f WHERE f->>'settlementId'=x->>'settlementId'),'{}') ORDER BY (x->>'sequenceNo')::int DESC) FROM jsonb_array_elements(out->'settlements') x),'[]'));
 ELSIF p_action='details' THEN
  out:=public.tower_trip_account(p_token,'details',p_payload);
  fields:=public.tower_trip_settlement_fields_244(p_token,ARRAY[(out->'settlement'->>'settlementId')::uuid]);
  RETURN jsonb_set(out,'{settlement}',(out->'settlement')||coalesce(fields->0,'{}'));
 ELSIF p_action='paymentDetails' THEN
  SELECT jsonb_build_object('paymentId',p.payment_id,'amount',p.amount,'source',p.source,'reference',p.reference,
   'createdAt',p.created_at,'status',p.status,'settlementId',p.settlement_id,
   'canCancel',p.status='OPEN' AND p.settlement_id IS NULL AND p.source='RESIDENT_PAYMENT') INTO out
  FROM public.tower_trip_payments p WHERE p.unit_id=uid AND p.payment_id=nullif(p_payload->>'paymentId','')::uuid;
  IF out IS NULL THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;RETURN out;
 ELSIF p_action='undo' THEN
  SELECT * INTO sett FROM public.tower_trip_settlements WHERE unit_id=uid ORDER BY sequence_no DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR sett.status<>'ACTIVE' THEN RAISE EXCEPTION 'ONLY_LATEST_SETTLEMENT'; END IF;
  IF coalesce(p_payload->>'expectedSettlementId','')<>sett.settlement_id::text THEN RAISE EXCEPTION 'SETTLEMENT_CHANGED_REFRESH'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_trip_payments WHERE unit_id=uid AND source='SETTLEMENT_CREDIT' AND reference=sett.settlement_id::text AND (status<>'OPEN' OR settlement_id IS NOT NULL)) THEN RAISE EXCEPTION 'CREDIT_ALREADY_USED'; END IF;
  -- SQL246: reverse only the cash created by this approval, not independent advances.
  cash_pid:=public.tower_trip_settlement_cash_246(sett.settlement_id,uid);
  IF cash_pid IS NOT NULL THEN
   PERFORM 1 FROM public.tower_trip_payments WHERE payment_id=cash_pid AND unit_id=uid
    AND status='APPLIED' AND settlement_id=sett.settlement_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'SETTLEMENT_PAYMENT_CHANGED'; END IF;
   UPDATE public.tower_trip_settlement_options_244 SET cash_payment_id=cash_pid WHERE settlement_id=sett.settlement_id AND unit_id=uid;
   UPDATE public.tower_trip_payments SET status='CANCELED',reversal_reason='UNDO '||sett.settlement_id::text,updated_at=now()
    WHERE payment_id=cash_pid AND unit_id=uid;
  END IF;
  UPDATE public.tower_trips SET status='OPEN',settlement_id=NULL,updated_at=now() WHERE unit_id=uid AND settlement_id=sett.settlement_id;
  UPDATE public.tower_trip_payments SET status='REVERSED',reversal_reason='UNDO '||sett.settlement_id::text,updated_at=now() WHERE unit_id=uid AND settlement_id=sett.settlement_id AND source='SETTLEMENT_CLOSING';
  UPDATE public.tower_trip_payments SET status='OPEN',settlement_id=NULL,updated_at=now() WHERE unit_id=uid AND settlement_id=sett.settlement_id AND source<>'SETTLEMENT_CLOSING' AND payment_id IS DISTINCT FROM cash_pid;
  UPDATE public.tower_trip_payments SET status='CANCELED',reversal_reason='UNDO '||sett.settlement_id::text,updated_at=now() WHERE unit_id=uid AND source='SETTLEMENT_CREDIT' AND reference=sett.settlement_id::text AND status='OPEN';
  UPDATE public.tower_trip_settlement_details SET status='CANCELED' WHERE unit_id=uid AND settlement_id=sett.settlement_id;
  UPDATE public.tower_trip_settlements SET status='CANCELED',canceled_at=now(),canceled_by=actor.user_id,cancel_reason=left(coalesce(p_payload->>'reason','UNDO_LATEST'),500) WHERE settlement_id=sett.settlement_id;
  UPDATE public.tower_notifications SET title='تم إلغاء تسوية المشاوير',body='تسوية #'||lpad(sett.sequence_no::text,3,'0')||' ملغاة، وعادت مشاويرها والدفعات السابقة للحساب، وأُلغي مدفوع اعتمادها.' WHERE unit_id=uid AND entity='trip_settlement' AND entity_id=sett.settlement_id::text;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'UNDO_SETTLEMENT','TRIP_SETTLEMENT',sett.settlement_id::text);
  RETURN jsonb_build_object('success',true,'settlementId',sett.settlement_id);
 END IF;
 WITH trips AS (SELECT * FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL AND (NOT exclude_missing OR NOT public.tower_trip_unpriced_279(items))),
 payments AS (SELECT * FROM public.tower_trip_payments WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL)
 SELECT (SELECT count(*) FROM trips),(SELECT coalesce(sum(purchases_total),0) FROM trips),
  (SELECT coalesce(sum(distance_fee+extra_fee),0) FROM trips),(SELECT coalesce(sum(total_due),0) FROM trips),
  (SELECT coalesce(sum(amount),0) FROM payments),
  md5(jsonb_build_object('trips',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY trip_id),'[]') FROM trips t),
  'excludedTrips',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY trip_id),'[]') FROM public.tower_trips t WHERE t.unit_id=uid AND t.status='OPEN' AND t.settlement_id IS NULL AND exclude_missing AND public.tower_trip_unpriced_279(t.items)),
  'payments',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY payment_id),'[]') FROM payments p))::text)
 INTO n,purchases,fees,gross,paid,revision;
 IF p_action='preview' THEN RETURN jsonb_build_object('unitId',uid,'revision',revision,'openTripCount',n,
  'unpricedTripCount',missing_count,'eligibleTripCount',CASE WHEN exclude_missing THEN n ELSE n-missing_count END,'excludeUnpriced',exclude_missing,'purchasesTotal',purchases,'feesTotal',fees,'grossTotal',gross,'paymentsTotal',paid,'dueTotal',greatest(0,gross-paid),'creditBalance',greatest(0,paid-gross)); END IF;
 rid:=coalesce(p_payload->>'requestId','');IF rid !~ '^[a-zA-Z0-9_-]{16,100}$' THEN RAISE EXCEPTION 'SETTLEMENT_REFERENCE_REQUIRED'; END IF;
 identity_payload:=p_payload-'unitId';
 SELECT * INTO request_row FROM public.tower_trip_close_requests_244 WHERE unit_id=uid AND request_id=rid;
 IF FOUND THEN
  IF request_row.actor_id<>actor.user_id OR request_row.payload<>identity_payload THEN RAISE EXCEPTION 'SETTLEMENT_REQUEST_CHANGED'; END IF;
  RETURN request_row.result||jsonb_build_object('replayed',true,'alreadyCanceled',CASE WHEN request_row.result->>'settlementId' IS NOT NULL THEN EXISTS(SELECT 1 FROM public.tower_trip_settlements WHERE settlement_id=(request_row.result->>'settlementId')::uuid AND status='CANCELED') ELSE EXISTS(SELECT 1 FROM public.tower_trip_payments WHERE payment_id=(request_row.result->>'paymentId')::uuid AND status='CANCELED') END);
 END IF;
 IF missing_count>0 AND NOT exclude_missing THEN RAISE EXCEPTION 'UNPRICED_TRIPS_REQUIRE_CHOICE'; END IF;
 IF n=0 THEN RAISE EXCEPTION 'NO_PRICED_TRIPS'; END IF;
 IF coalesce(p_payload->>'expectedRevision','')<>revision THEN RAISE EXCEPTION 'SETTLEMENT_CHANGED_REFRESH'; END IF;
 value_text:=nullif(btrim(p_payload->>'additionalFees'),'');
 IF value_text IS NOT NULL THEN
  IF value_text !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_SETTLEMENT_AMOUNT'; END IF;IF value_text::numeric>100000000 THEN RAISE EXCEPTION 'INVALID_SETTLEMENT_AMOUNT'; END IF;additional:=value_text::numeric;
 END IF;
 value_text:=nullif(btrim(p_payload->>'paidNow'),'');explicit_cash:=value_text IS NOT NULL;
 IF explicit_cash THEN
  IF value_text !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_SETTLEMENT_AMOUNT'; END IF;IF value_text::numeric>100000000 THEN RAISE EXCEPTION 'INVALID_SETTLEMENT_AMOUNT'; END IF;cash:=value_text::numeric;
 ELSE cash:=greatest(0,gross+additional-paid); END IF;
 before_paid:=paid;
 IF explicit_cash AND cash<greatest(0,gross+additional-paid) THEN
  IF cash<=0 THEN RAISE EXCEPTION 'INVALID_SETTLEMENT_AMOUNT'; END IF;
  out:=public.tower_trip_account(p_token,'addPayment',jsonb_build_object('unitId',uid,'amount',cash::text,'reference','دفعة أثناء مراجعة التسوية'));
  out:=out||jsonb_build_object('paymentOnly',true,'additionalFeesApplied',false,'amount',cash);
  INSERT INTO public.tower_trip_close_requests_244(unit_id,request_id,actor_id,payload,result) VALUES(uid,rid,actor.user_id,identity_payload,out);RETURN out;
 END IF;
 IF explicit_cash AND cash>0 THEN
  out:=public.tower_trip_account(p_token,'addPayment',jsonb_build_object('unitId',uid,'amount',cash::text,'reference','مدفوع عند التسوية'));
  cash_pid:=nullif(out->>'paymentId','')::uuid;
  IF cash_pid IS NULL OR NOT EXISTS(SELECT 1 FROM public.tower_trip_payments
   WHERE payment_id=cash_pid AND unit_id=uid AND source='RESIDENT_PAYMENT' AND status='OPEN'
    AND settlement_id IS NULL AND amount=cash AND created_by=actor.user_id) THEN
   RAISE EXCEPTION 'SETTLEMENT_PAYMENT_LINK_UNCLEAR';
  END IF;
  paid:=paid+cash;
 END IF;
 -- Existing accounting columns retain their old meaning: explicit cash is a real resident payment,
 -- implicit closing is a generated closing payment. Separate metadata supplies the human-facing split.
 closing:=greatest(0,gross+additional-paid);credit:=greatest(0,paid-(gross+additional));
 SELECT coalesce(max(sequence_no),0)+1 INTO seq FROM public.tower_trip_settlements WHERE unit_id=uid;
 SELECT m.user_id INTO manager_user FROM public.tower_members m WHERE m.unit_id=uid AND m.member_role='MANAGER' AND m.ended_at IS NULL;
 SELECT public.tower_person_label_231(u.name,coalesce(nullif(u.custom_title,''),u.title),u.user_id) INTO manager_name FROM public.tower_users u WHERE u.user_id=manager_user;
 manager_name:=coalesce(nullif(trim(manager_name),''),'غير معين');
 INSERT INTO public.tower_trip_settlements(unit_id,sequence_no,settled_by,manager_display_name,purchases_total,fees_total,gross_total,prior_payments,closing_payment,credit_after)
 VALUES(uid,seq,actor.user_id,manager_name,purchases,fees+additional,gross+additional,paid,closing,credit) RETURNING settlement_id INTO sid;
 INSERT INTO public.tower_trip_settlement_options_244(settlement_id,unit_id,extra_fee,trip_fees,prior_paid,paid_now,explicit_payment,cash_payment_id)
 VALUES(sid,uid,additional,fees,before_paid,cash,explicit_cash,cash_pid);
 INSERT INTO public.tower_trip_settlement_details(settlement_id,unit_id,detail_type,entity_id,snapshot,amount)
 SELECT sid,uid,'TRIP',trip_id,jsonb_build_object('tripId',trip_id,'items',items,'purchasesTotal',purchases_total,'distance',distance,'distanceFee',distance_fee,'extraFee',extra_fee,'totalDue',total_due,'notes',notes,'createdAt',created_at,'actorRole',actor_role,'orders',(SELECT string_agg(x->>'name','، ') FROM jsonb_array_elements(items) x)),total_due
 FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL AND (NOT exclude_missing OR NOT public.tower_trip_unpriced_279(items));
 UPDATE public.tower_trips SET status='SETTLED',settlement_id=sid,updated_at=now() WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL AND (NOT exclude_missing OR NOT public.tower_trip_unpriced_279(items));
 INSERT INTO public.tower_trip_settlement_details(settlement_id,unit_id,detail_type,entity_id,snapshot,amount)
 SELECT sid,uid,'PAYMENT',payment_id,jsonb_build_object('paymentId',payment_id,'amount',amount,'source',source,'reference',reference,'createdAt',created_at),amount
 FROM public.tower_trip_payments WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL;
 UPDATE public.tower_trip_payments SET status='APPLIED',settlement_id=sid,updated_at=now() WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL;
 IF closing>0 THEN
  INSERT INTO public.tower_trip_payments(unit_id,amount,status,settlement_id,source,reference,created_by)
  VALUES(uid,closing,'APPLIED',sid,'SETTLEMENT_CLOSING',sid::text,actor.user_id) RETURNING payment_id INTO pid;
  INSERT INTO public.tower_trip_settlement_details(settlement_id,unit_id,detail_type,entity_id,snapshot,amount)
  VALUES(sid,uid,'PAYMENT',pid,jsonb_build_object('paymentId',pid,'amount',closing,'source','SETTLEMENT_CLOSING'),closing);
 END IF;
 IF credit>0 THEN
  INSERT INTO public.tower_trip_payments(unit_id,amount,status,source,reference,created_by)
  VALUES(uid,credit,'OPEN','SETTLEMENT_CREDIT',sid::text,actor.user_id) RETURNING payment_id INTO pid;
  INSERT INTO public.tower_trip_settlement_details(settlement_id,unit_id,detail_type,entity_id,snapshot,amount)
  VALUES(sid,uid,'CREDIT_CARRY',pid,jsonb_build_object('paymentId',pid,'amount',credit,'source','SETTLEMENT_CREDIT'),credit);
 END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'CLOSE_SETTLEMENT','TRIP_SETTLEMENT',sid::text);
 out:=jsonb_build_object('success',true,'settlementId',sid,'sequenceNo',seq,'grossTotal',gross+additional,
  'priorPayments',before_paid,'closingPayment',cash,'additionalFees',additional,'creditAfter',credit,'paymentOnly',false);
 INSERT INTO public.tower_trip_close_requests_244(unit_id,request_id,actor_id,payload,result) VALUES(uid,rid,actor.user_id,identity_payload,out);
 RETURN out;
END $f$;

/*
Tower App V3.9.8 - SQL_279.
___________________________
Code End
*/

/*
Tower App V3.9.8 - SQL_280.

___________________________
*/

SET LOCAL lock_timeout='10s';
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
 IF p_action='confirm' AND NOT public.tower_task_responsible_236(v_actor.user_id,p_service_id) THEN RAISE EXCEPTION 'TASK_RECEIPT_RECIPIENT_ONLY'; END IF;
 IF p_action='status' AND v_actor.role NOT IN ('ADMIN','UNION') AND NOT public.tower_task_responsible_236(v_actor.user_id,p_service_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
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
  'canConfirm',public.tower_task_responsible_236(v_actor.user_id,p_service_id),'postedAmount',v_f.amount,'confirmed',v_r.service_id IS NOT NULL,
  'confirmedAmount',CASE WHEN v_r.service_id IS NOT NULL THEN v_r.amount ELSE 0 END,
  'accountId',v_r.account_id,'confirmedAt',v_r.confirmed_at);
END $function$;
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
  RETURN jsonb_build_object('entity','trip','entityId',t.trip_id,'createdAt',t.created_at,'unitId',t.unit_id,'owner',u.user_id,'chatId',acct.chat_id,'unitNumber',unit_label,'sender',sender,'kind',kind,'items',items,'moreItems',greatest(0,jsonb_array_length(CASE WHEN jsonb_typeof(t.items)='array' THEN t.items ELSE '[]'::jsonb END)-20),'note',left(coalesce(t.notes,''),200),'showAmounts',show_money)
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


COMMIT;
/*
Tower App V3.9.8 - SQL_280.
___________________________
Code End
*/

/*
Tower App V3.9.8 - SQL_279_280.
___________________________
Code End
*/
