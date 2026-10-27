/*
Tower App V2.5.194 - SQL_246.

___________________________
*/
BEGIN;
SET LOCAL lock_timeout='10s';
ALTER TABLE public.tower_trip_settlement_options_244
 ADD COLUMN IF NOT EXISTS cash_payment_id uuid REFERENCES public.tower_trip_payments(payment_id);
CREATE OR REPLACE FUNCTION public.tower_trip_settlement_cash_246(p_sid uuid,p_unit uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public,pg_temp AS $cash$
DECLARE opt public.tower_trip_settlement_options_244;candidate uuid;matches integer;
BEGIN
 SELECT * INTO opt FROM public.tower_trip_settlement_options_244 WHERE settlement_id=p_sid AND unit_id=p_unit;
 -- Legacy/implicit/zero cash never authorizes canceling an independent payment.
 IF NOT FOUND OR NOT opt.explicit_payment OR opt.paid_now=0 THEN RETURN NULL; END IF;
 SELECT count(*),(array_agg(x.payment_id))[1] INTO matches,candidate FROM (
  SELECT DISTINCT p.payment_id
  FROM public.tower_trip_settlements s
  JOIN public.tower_trip_settlement_details d ON d.settlement_id=s.settlement_id AND d.unit_id=s.unit_id
  JOIN public.tower_trip_payments p ON p.payment_id=d.entity_id AND p.unit_id=s.unit_id
  WHERE s.settlement_id=p_sid AND s.unit_id=p_unit AND d.detail_type='PAYMENT'
   AND p.source='RESIDENT_PAYMENT' AND p.amount=opt.paid_now AND d.amount=opt.paid_now
   AND p.created_by=s.settled_by AND p.created_at=s.settled_at
   AND p.reference='مدفوع عند التسوية'
   AND d.snapshot->>'paymentId'=p.payment_id::text AND d.snapshot->>'source'='RESIDENT_PAYMENT'
   AND d.snapshot->>'reference'='مدفوع عند التسوية'
   AND (d.snapshot->>'amount')::numeric=opt.paid_now
   AND (d.snapshot->>'createdAt')::timestamptz=s.settled_at
   AND (opt.cash_payment_id IS NULL OR opt.cash_payment_id=p.payment_id)
   AND EXISTS(SELECT 1 FROM public.tower_trip_close_requests_244 q
    WHERE q.unit_id=p_unit AND q.actor_id=s.settled_by
     AND q.result->>'settlementId'=p_sid::text AND q.result->>'paymentOnly'='false'
     AND (q.result->>'closingPayment')::numeric=opt.paid_now
     AND (q.payload->>'paidNow')::numeric=opt.paid_now)
 ) x;
 IF matches<>1 THEN RAISE EXCEPTION 'SETTLEMENT_PAYMENT_LINK_UNCLEAR'; END IF;
 RETURN candidate;
END $cash$;
-- Only the existing authenticated settlement RPC may call this internal resolver.
REVOKE ALL ON FUNCTION public.tower_trip_settlement_cash_246(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_trip_settlement_action_244(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp AS $f$
DECLARE
 actor public.tower_users;uid uuid;sett public.tower_trip_settlements;request_row public.tower_trip_close_requests_244;
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
 WITH trips AS (SELECT * FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL),
 payments AS (SELECT * FROM public.tower_trip_payments WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL)
 SELECT (SELECT count(*) FROM trips),(SELECT coalesce(sum(purchases_total),0) FROM trips),
  (SELECT coalesce(sum(distance_fee+extra_fee),0) FROM trips),(SELECT coalesce(sum(total_due),0) FROM trips),
  (SELECT coalesce(sum(amount),0) FROM payments),
  md5(jsonb_build_object('trips',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY trip_id),'[]') FROM trips t),
  'payments',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY payment_id),'[]') FROM payments p))::text)
 INTO n,purchases,fees,gross,paid,revision;
 IF p_action='preview' THEN RETURN jsonb_build_object('unitId',uid,'revision',revision,'openTripCount',n,
  'purchasesTotal',purchases,'feesTotal',fees,'grossTotal',gross,'paymentsTotal',paid,'dueTotal',greatest(0,gross-paid),'creditBalance',greatest(0,paid-gross)); END IF;
 rid:=coalesce(p_payload->>'requestId','');IF rid !~ '^[a-zA-Z0-9_-]{16,100}$' THEN RAISE EXCEPTION 'SETTLEMENT_REFERENCE_REQUIRED'; END IF;
 identity_payload:=p_payload-'unitId';
 SELECT * INTO request_row FROM public.tower_trip_close_requests_244 WHERE unit_id=uid AND request_id=rid;
 IF FOUND THEN
  IF request_row.actor_id<>actor.user_id OR request_row.payload<>identity_payload THEN RAISE EXCEPTION 'SETTLEMENT_REQUEST_CHANGED'; END IF;
  RETURN request_row.result||jsonb_build_object('replayed',true,'alreadyCanceled',CASE WHEN request_row.result->>'settlementId' IS NOT NULL THEN EXISTS(SELECT 1 FROM public.tower_trip_settlements WHERE settlement_id=(request_row.result->>'settlementId')::uuid AND status='CANCELED') ELSE EXISTS(SELECT 1 FROM public.tower_trip_payments WHERE payment_id=(request_row.result->>'paymentId')::uuid AND status='CANCELED') END);
 END IF;
 IF n=0 THEN RAISE EXCEPTION 'NO_OPEN_TRIPS'; END IF;
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
 FROM public.tower_trips WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL;
 UPDATE public.tower_trips SET status='SETTLED',settlement_id=sid,updated_at=now() WHERE unit_id=uid AND status='OPEN' AND settlement_id IS NULL;
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

REVOKE ALL ON FUNCTION public.tower_trip_settlement_action_244(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_trip_settlement_action_244(text,text,jsonb) TO service_role;
-- Authorized correction: only the canceled settlement #3 of unit 26, cash 200.
-- No report, names, payment IDs or account rows are embedded in this migration.
DO $repair$
DECLARE target_unit uuid;target_set public.tower_trip_settlements;cash_id uuid;
 payment public.tower_trip_payments;unit_matches integer;opt public.tower_trip_settlement_options_244;
BEGIN
 SELECT count(*),(array_agg(unit_id))[1] INTO unit_matches,target_unit FROM public.tower_units
 WHERE translate(btrim(unit_number::text),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789') ~ '^0*26$';
 IF unit_matches<>1 THEN RAISE EXCEPTION 'تعذر تحديد الوحدة 26 بشكل منفرد؛ لم يطبق الإصلاح.'; END IF;
 PERFORM 1 FROM public.tower_units WHERE unit_id=target_unit FOR UPDATE;
 SELECT * INTO target_set FROM public.tower_trip_settlements WHERE unit_id=target_unit AND sequence_no=3 FOR UPDATE;
 IF NOT FOUND OR target_set.status<>'CANCELED' THEN RAISE EXCEPTION 'التسوية رقم 3 للوحدة 26 ليست ملغاة؛ لم يطبق الإصلاح.'; END IF;
 SELECT * INTO opt FROM public.tower_trip_settlement_options_244 WHERE unit_id=target_unit AND settlement_id=target_set.settlement_id;
 IF NOT FOUND OR NOT opt.explicit_payment OR opt.paid_now<>200 THEN
  RAISE EXCEPTION 'مدفوع التسوية رقم 3 لا يطابق الدفعة المطلوب إصلاحها؛ لم يطبق الإصلاح.';
 END IF;
 cash_id:=public.tower_trip_settlement_cash_246(target_set.settlement_id,target_unit);
 IF cash_id IS NULL THEN RAISE EXCEPTION 'تعذر إثبات ارتباط الدفعة بالتسوية؛ لم يطبق الإصلاح.'; END IF;
 SELECT * INTO payment FROM public.tower_trip_payments WHERE payment_id=cash_id AND unit_id=target_unit FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.tower_trip_settlement_details d JOIN public.tower_trip_settlements s USING(settlement_id)
   WHERE d.unit_id=target_unit AND s.unit_id=target_unit AND s.status='ACTIVE'
    AND d.detail_type='PAYMENT' AND d.entity_id=cash_id) THEN
  RAISE EXCEPTION 'دفعة 200 جنيه مستخدمة في تسوية فعالة؛ لم يطبق الإصلاح أو يغير أي رصيد.';
 END IF;
 IF payment.status='CANCELED' AND payment.settlement_id=target_set.settlement_id
  AND payment.reversal_reason='UNDO '||target_set.settlement_id::text THEN
  RAISE NOTICE 'الدفعة مصححة بالفعل؛ لم يتم تكرار الإلغاء.';RETURN;
 END IF;
 IF payment.status<>'OPEN' OR payment.settlement_id IS NOT NULL THEN
  RAISE EXCEPTION 'حالة دفعة 200 جنيه تغيرت؛ لم يطبق الإصلاح أو يغير أي رصيد.';
 END IF;
 UPDATE public.tower_trip_settlement_options_244 SET cash_payment_id=cash_id WHERE settlement_id=target_set.settlement_id AND unit_id=target_unit;
 UPDATE public.tower_trip_payments SET status='CANCELED',settlement_id=target_set.settlement_id,
  reversal_reason='UNDO '||target_set.settlement_id::text,updated_at=now() WHERE payment_id=cash_id AND unit_id=target_unit;
 -- Maintenance action, not falsely attributed to the original resident or canceling actor.
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(NULL,'REPAIR_SETTLEMENT_CASH_246','TRIP_PAYMENT',cash_id::text);
END $repair$;
-- One small result only; these are current values, not a replacement of historical snapshots.
SELECT 'تم تثبيت إصلاح التراجع ومعالجة دفعة التسوية رقم 3' AS result,
 (SELECT coalesce(sum(p.amount),0) FROM public.tower_trip_payments p JOIN public.tower_units u USING(unit_id)
  WHERE translate(btrim(u.unit_number::text),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789') ~ '^0*26$'
   AND p.status='OPEN' AND p.settlement_id IS NULL) AS unit26_open_payments;

NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.194 - SQL_246.

Code End
*/
