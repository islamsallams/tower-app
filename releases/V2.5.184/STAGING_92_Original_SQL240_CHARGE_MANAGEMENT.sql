/*
Tower App V2.5.184 - SQL_240.

___________________________
*/
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_charge_requests_240 (
 reference text PRIMARY KEY,actor_id uuid NOT NULL, payload jsonb NOT NULL,
 charge_id uuid NOT NULL REFERENCES public.tower_building_charges(charge_id),created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_charge_requests_240 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_charge_requests_240 FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS public.tower_charge_history_240 (
 history_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),charge_id uuid NOT NULL REFERENCES public.tower_building_charges(charge_id),
 actor_id uuid NOT NULL,action text NOT NULL,before_state jsonb NOT NULL,after_state jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tower_charge_history_240_charge_idx ON public.tower_charge_history_240(charge_id,created_at);
ALTER TABLE public.tower_charge_history_240 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_charge_history_240 FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.tower_charge_snapshot_240(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 SELECT jsonb_build_object('charge',to_jsonb(c),'allocations',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.unit_id) FROM public.tower_building_allocations a WHERE a.charge_id=c.charge_id),'[]'::jsonb)) FROM public.tower_building_charges c WHERE c.charge_id=p_id
$f$;
REVOKE ALL ON FUNCTION public.tower_charge_snapshot_240(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.tower_charge_manage_240(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;v_charge public.tower_building_charges;prior public.tower_charge_requests_240;
 ref text;cid uuid;before_ids uuid[];result jsonb;snap jsonb;after_snap jsonb;rows jsonb;line jsonb;item jsonb;
 total numeric:=0;n integer;pg integer;cnt integer;flt text;q text;amt numeric;did uuid;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action='list' THEN
  flt:=coalesce(p_payload->>'status','ACTIVE');q:=btrim(coalesce(p_payload->>'query',''));
  IF flt NOT IN ('ACTIVE','CANCELED','ALL') OR length(q)>100 OR coalesce(p_payload->>'page','1') !~ '^[0-9]{1,6}$' THEN RAISE EXCEPTION 'INVALID_CHARGE_FILTER'; END IF;
  pg:=greatest(1,coalesce((p_payload->>'page')::integer,1));
  SELECT count(*) INTO cnt FROM public.tower_building_charges c WHERE (flt='ALL' OR c.status=flt) AND (q='' OR c.title ILIKE '%'||q||'%' OR c.category ILIKE '%'||q||'%');
  pg:=least(pg,greatest(1,ceil(cnt/12.0)::integer));
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'createdAt' DESC,r->>'chargeId' DESC),'[]') INTO rows FROM (
   SELECT jsonb_build_object('chargeId',c.charge_id,'title',c.title,'category',c.category,'dueDate',c.due_date,'periodLabel',c.period_label,'status',c.status,'createdAt',c.created_at,
    'unitCount',(SELECT count(*) FROM public.tower_building_allocations a WHERE a.charge_id=c.charge_id),
    'allocatedTotal',(SELECT coalesce(sum(a.amount),0) FROM public.tower_building_allocations a WHERE a.charge_id=c.charge_id),
    'paidTotal',(SELECT coalesce(sum(a.paid),0) FROM public.tower_building_allocations a WHERE a.charge_id=c.charge_id),
    'remainingTotal',CASE WHEN c.status='ACTIVE' THEN (SELECT coalesce(sum(a.amount-a.paid),0) FROM public.tower_building_allocations a WHERE a.charge_id=c.charge_id) ELSE 0 END) r
   FROM public.tower_building_charges c WHERE (flt='ALL' OR c.status=flt) AND (q='' OR c.title ILIKE '%'||q||'%' OR c.category ILIKE '%'||q||'%') ORDER BY c.created_at DESC,c.charge_id DESC LIMIT 12 OFFSET (pg-1)*12
  ) s;
  RETURN jsonb_build_object('rows',rows,'page',pg,'pages',greatest(1,ceil(cnt/12.0)::integer),'total',cnt);
 END IF;
 IF p_action='create' THEN
  ref:=p_payload->>'reference';
  IF ref IS NULL OR ref !~ '^[A-Za-z0-9_-]{16,64}$' THEN RAISE EXCEPTION 'CHARGE_REFERENCE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('charge-create-240:'||ref,0));
  SELECT * INTO prior FROM public.tower_charge_requests_240 WHERE reference=ref;
  IF FOUND THEN
   IF prior.actor_id<>actor.user_id OR prior.payload<>p_payload-'reference' THEN RAISE EXCEPTION 'CHARGE_REFERENCE_CONFLICT'; END IF;
   RETURN jsonb_build_object('success',true,'chargeId',prior.charge_id,'replayed',true);
  END IF;
  PERFORM pg_advisory_xact_lock(73912016);
  SELECT coalesce(array_agg(charge_id),'{}'::uuid[]) INTO before_ids FROM public.tower_building_charges;
  result:=public.tower_charges_action(p_token,'create',p_payload-'reference');
  IF coalesce(result->>'chargeId','') ~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN
   SELECT charge_id INTO cid FROM public.tower_building_charges WHERE charge_id=(result->>'chargeId')::uuid AND NOT(charge_id=ANY(before_ids));
  END IF;
  IF cid IS NULL THEN
   SELECT count(*) INTO n FROM public.tower_building_charges WHERE NOT(charge_id=ANY(before_ids));
   IF n=1 THEN SELECT charge_id INTO cid FROM public.tower_building_charges WHERE NOT(charge_id=ANY(before_ids));END IF;
  END IF;
  IF cid IS NULL THEN RAISE EXCEPTION 'CHARGE_CREATE_NOT_CONFIRMED'; END IF;
  INSERT INTO public.tower_charge_requests_240(reference,actor_id,payload,charge_id) VALUES(ref,actor.user_id,p_payload-'reference',cid);
  RETURN coalesce(result,'{}')||jsonb_build_object('success',true,'chargeId',cid);
 END IF;
 IF p_action NOT IN ('details','edit','cancel') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 BEGIN cid:=(p_payload->>'chargeId')::uuid;EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'CHARGE_NOT_FOUND';END;
 IF p_action IN ('edit','cancel') THEN
  PERFORM pg_advisory_xact_lock(73912016);
  PERFORM 1 FROM public.tower_building_charges WHERE charge_id=cid FOR UPDATE;
  PERFORM 1 FROM public.tower_building_allocations WHERE charge_id=cid ORDER BY unit_id FOR UPDATE;
 END IF;
 SELECT * INTO v_charge FROM public.tower_building_charges WHERE charge_id=cid;
 IF NOT FOUND THEN RAISE EXCEPTION 'CHARGE_NOT_FOUND'; END IF;
 snap:=public.tower_charge_snapshot_240(cid);
 IF p_action IN ('edit','cancel') THEN
  IF v_charge.status<>'ACTIVE' THEN RAISE EXCEPTION 'CHARGE_ALREADY_CANCELED'; END IF;
  IF v_charge.service_id IS NOT NULL OR v_charge.subscription_id IS NOT NULL THEN RAISE EXCEPTION 'CHARGE_MANAGE_FROM_SERVICE'; END IF;
  IF p_payload->>'revision' IS DISTINCT FROM md5(snap::text) THEN RAISE EXCEPTION 'CHARGE_CHANGED_REFRESH'; END IF;
 END IF;
 IF p_action='edit' THEN
  IF length(btrim(coalesce(p_payload->>'title',''))) NOT BETWEEN 1 AND 200 OR length(coalesce(p_payload->>'notes',''))>2000 OR length(coalesce(p_payload->>'periodLabel',''))>100 THEN RAISE EXCEPTION 'INVALID_CHARGE_DETAILS'; END IF;
  IF jsonb_typeof(p_payload->'allocations') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
  SELECT count(*) INTO n FROM public.tower_building_allocations WHERE charge_id=cid;
  IF jsonb_array_length(p_payload->'allocations')<>n OR n=0 THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
  IF (SELECT count(DISTINCT x->>'unitId') FROM jsonb_array_elements(p_payload->'allocations') x)<>n THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(p_payload->'allocations') LOOP
   IF coalesce(line->>'unitId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' OR coalesce(line->>'amount','') !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
   did:=(line->>'unitId')::uuid;amt:=(line->>'amount')::numeric;
   SELECT to_jsonb(a) INTO item FROM public.tower_building_allocations a WHERE a.charge_id=cid AND a.unit_id=did;
   IF item IS NULL THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
   IF NOT (item->>'deferred')::boolean AND amt<(item->>'paid')::numeric THEN RAISE EXCEPTION 'CHARGE_AMOUNT_BELOW_PAID'; END IF;
   IF (item->>'deferred')::boolean AND (item->>'paid')::numeric>0 THEN RAISE EXCEPTION 'INVALID_CHARGE_ALLOCATION'; END IF;
   total:=total+amt;
   UPDATE public.tower_building_allocations SET base_amount=amt,amount=CASE WHEN deferred THEN 0 ELSE amt END WHERE charge_id=cid AND unit_id=did;
  END LOOP;
  IF total<=0 OR total>100000000 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
  UPDATE public.tower_building_charges SET title=btrim(p_payload->>'title'),notes=coalesce(p_payload->>'notes',''),period_label=coalesce(p_payload->>'periodLabel',''),due_date=nullif(p_payload->>'dueDate','')::date,total_amount=total,distribution='CUSTOM' WHERE charge_id=cid;
 ELSIF p_action='cancel' THEN
  -- Cancel only the remaining obligation. Existing receipts/fund entries are retained.
  UPDATE public.tower_building_charges SET status='CANCELED' WHERE charge_id=cid;
 END IF;
 IF p_action IN ('edit','cancel') THEN
  after_snap:=public.tower_charge_snapshot_240(cid);
  INSERT INTO public.tower_charge_history_240(charge_id,actor_id,action,before_state,after_state) VALUES(cid,actor.user_id,p_action,snap,after_snap);
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,CASE WHEN p_action='edit' THEN 'EDIT_BUILDING_CHARGE' ELSE 'CANCEL_BUILDING_CHARGE' END,'BUILDING_CHARGE',cid::text);
  snap:=after_snap;
  SELECT * INTO v_charge FROM public.tower_building_charges WHERE charge_id=cid;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',a.unit_id,'unitNumber',u.unit_number,'floor',u.floor,'managerName',coalesce((SELECT public.tower_person_label_231(mu.name,mu.title,mu.user_id) FROM public.tower_members m JOIN public.tower_users mu ON mu.user_id=m.user_id WHERE m.unit_id=a.unit_id AND m.member_role='MANAGER' AND m.ended_at IS NULL LIMIT 1),'غير معين'),'amount',a.amount,'paid',a.paid,'remaining',CASE WHEN v_charge.status='ACTIVE' THEN a.amount-a.paid ELSE 0 END,'baseAmount',a.base_amount,'deferred',a.deferred) ORDER BY u.floor,u.unit_number),'[]') INTO rows FROM public.tower_building_allocations a JOIN public.tower_units u ON u.unit_id=a.unit_id WHERE a.charge_id=cid;
 RETURN jsonb_build_object('chargeId',cid,'title',v_charge.title,'category',v_charge.category,'categoryId',v_charge.category_id,'dueDate',v_charge.due_date,'periodLabel',v_charge.period_label,'notes',v_charge.notes,'status',v_charge.status,'totalAmount',v_charge.total_amount,'createdAt',v_charge.created_at,'distribution',v_charge.distribution,'revision',md5(snap::text),'managedByService',v_charge.service_id IS NOT NULL OR v_charge.subscription_id IS NOT NULL,'allocations',rows,
 'paidTotal',(SELECT coalesce(sum(paid),0) FROM public.tower_building_allocations WHERE charge_id=cid),
 'remainingTotal',CASE WHEN v_charge.status='ACTIVE' THEN (SELECT coalesce(sum(amount-paid),0) FROM public.tower_building_allocations WHERE charge_id=cid) ELSE 0 END);
END $f$;
REVOKE ALL ON FUNCTION public.tower_charge_manage_240(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_charge_manage_240(text,text,jsonb) TO service_role;
-- Defense for older collection/payment engines: canceled obligations cannot receive new money.
CREATE OR REPLACE FUNCTION public.tower_charge_payment_guard_240()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
BEGIN
 IF NEW.paid>OLD.paid AND NOT EXISTS(SELECT 1 FROM public.tower_building_charges WHERE charge_id=NEW.charge_id AND status='ACTIVE') THEN RAISE EXCEPTION 'CHARGE_ALREADY_CANCELED'; END IF;
 RETURN NEW;
END $f$;
REVOKE ALL ON FUNCTION public.tower_charge_payment_guard_240() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tower_charge_payment_guard_240 ON public.tower_building_allocations;
CREATE TRIGGER tower_charge_payment_guard_240 BEFORE UPDATE OF paid ON public.tower_building_allocations FOR EACH ROW EXECUTE FUNCTION public.tower_charge_payment_guard_240();
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.184 - SQL_240.

Code End
*/
