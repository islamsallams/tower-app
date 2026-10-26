-- V2.5.178. A transaction boundary around existing FUND and PERSONAL collection engines.
BEGIN;
DO $f$ BEGIN
 IF to_regprocedure('public.tower_service_workspace_read_232(text,uuid,uuid)') IS NULL
 OR to_regprocedure('public.tower_personal_collections_230(text,text,jsonb)') IS NULL
 OR to_regprocedure('public.tower_collection_action(text,text,jsonb)') IS NULL
 OR to_regprocedure('public.tower_union_collect_approve(text,jsonb)') IS NULL THEN
  RAISE EXCEPTION 'COLLECTION_BATCH_DEPENDENCY_REQUIRED';
 END IF;
END $f$;
CREATE TABLE IF NOT EXISTS public.tower_collection_batches_233(
 reference text PRIMARY KEY CHECK(length(reference) BETWEEN 16 AND 64),
 actor_id uuid NOT NULL REFERENCES public.tower_users(user_id),
 payload jsonb NOT NULL,result jsonb NOT NULL,
 state text NOT NULL CHECK(state IN ('COMMITTED','REJECTED')),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_collection_batches_233 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tower_collection_batches_233 FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX IF NOT EXISTS tower_collection_batches_actor_233 ON public.tower_collection_batches_233(actor_id,created_at DESC);
CREATE OR REPLACE FUNCTION public.tower_collection_batch_233(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;ref text;canonical jsonb;lines jsonb;fund jsonb:='[]';personal jsonb:='[]';prior public.tower_collection_batches_233;
 line jsonb;item jsonb;unit uuid;account uuid;amount numeric;fund_total numeric:=0;personal_total numeric:=0;
 context jsonb;fund_result jsonb;receipt jsonb;result jsonb;error_code text;idx integer:=0;rows jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role NOT IN ('ADMIN','UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action='list' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('reference',b.reference,'createdAt',b.created_at,
    'collectorName',public.tower_person_label_231(u.name,u.title,u.user_id),'result',b.result,
    'lines',(SELECT coalesce(jsonb_agg(x.value||jsonb_build_object('unitNumber',un.unit_number,'floor',un.floor,'serviceName',svc.name) ORDER BY x.n),'[]')
       FROM jsonb_array_elements(b.payload->'lines') WITH ORDINALITY x(value,n)
       LEFT JOIN public.tower_units un ON un.unit_id=(x.value->>'unitId')::uuid
       LEFT JOIN public.tower_finance_accounts ac ON ac.account_id=(x.value->>'accountId')::uuid
       LEFT JOIN public.tower_services svc ON svc.service_id=ac.service_id)) ORDER BY b.created_at DESC,b.reference),'[]')
  INTO rows FROM (SELECT * FROM public.tower_collection_batches_233
    WHERE state='COMMITTED' AND (actor.role IN ('ADMIN','UNION') OR actor_id=actor.user_id)
    AND (NOT(p_payload ? 'cursor') OR (created_at,reference)<((p_payload->'cursor'->>'at')::timestamptz,p_payload->'cursor'->>'reference'))
    ORDER BY created_at DESC,reference LIMIT 50) b JOIN public.tower_users u ON u.user_id=b.actor_id;
  RETURN jsonb_build_object('rows',rows,'nextCursor',CASE WHEN jsonb_array_length(rows)=50 THEN jsonb_build_object('at',rows->49->>'createdAt','reference',rows->49->>'reference') ELSE NULL END);
 END IF;
 ref:=btrim(coalesce(p_payload->>'reference',''));
 IF length(ref) NOT BETWEEN 16 AND 64 OR ref !~ '^[A-Za-z0-9_-]+$' THEN RAISE EXCEPTION 'RECEIPT_REFERENCE_REQUIRED'; END IF;
 IF p_action NOT IN ('post','status') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF p_action='post' AND actor.role NOT IN ('UNION','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('collection-batch-233:'||ref,0));
 SELECT * INTO prior FROM public.tower_collection_batches_233 WHERE reference=ref;
 IF FOUND AND prior.actor_id<>actor.user_id AND (p_action='post' OR actor.role NOT IN ('ADMIN','UNION')) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='status' THEN
  RETURN CASE WHEN prior.reference IS NULL THEN jsonb_build_object('state','NOT_FOUND','reference',ref)
   ELSE prior.result||jsonb_build_object('reference',ref,'replayed',true) END;
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('reference','lines'))
 OR jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
 IF jsonb_array_length(p_payload->'lines') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
  IF jsonb_typeof(line)<>'object' OR coalesce(line->>'kind','') NOT IN ('FUND','PERSONAL')
   OR coalesce(line->>'unitId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
   OR coalesce(line->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$'
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(line) k WHERE k NOT IN ('kind','unitId','accountId','amount','method')) THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
  amount:=(line->>'amount')::numeric;
  IF amount<=0 OR amount>100000000 THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
  IF line->>'kind'='PERSONAL' THEN
   IF line ? 'method' OR coalesce(line->>'accountId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
  ELSE
   IF line ? 'accountId' OR coalesce(line->>'method','نقدي') NOT IN ('نقدي','تحويل','إنستاباي','محفظة إلكترونية','أخرى') THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
  END IF;
 END LOOP;
 SELECT jsonb_agg(jsonb_build_object('kind',x->>'kind','unitId',(x->>'unitId')::uuid,'amount',(x->>'amount')::numeric)
  ||CASE WHEN x->>'kind'='FUND' THEN jsonb_build_object('method',coalesce(x->>'method','نقدي')) ELSE jsonb_build_object('accountId',(x->>'accountId')::uuid) END
  ORDER BY (x->>'unitId')::uuid,x->>'kind',coalesce(x->>'accountId','')) INTO lines FROM jsonb_array_elements(p_payload->'lines') x;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines) x GROUP BY x->>'unitId',x->>'kind',x->>'accountId' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVALID_COLLECTION_BATCH'; END IF;
 canonical:=jsonb_build_object('lines',lines);
 IF prior.reference IS NOT NULL THEN
  IF prior.actor_id<>actor.user_id OR prior.payload<>canonical THEN RAISE EXCEPTION 'COLLECTION_BATCH_REFERENCE_CONFLICT'; END IF;
  RETURN prior.result||jsonb_build_object('reference',ref,'replayed',true);
 END IF;
 -- This exception block is a PostgreSQL subtransaction: every financial write rolls back together.
 BEGIN
  PERFORM 1 FROM public.tower_units u WHERE u.unit_id IN (SELECT (x->>'unitId')::uuid FROM jsonb_array_elements(lines) x) ORDER BY u.unit_id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines) x WHERE NOT EXISTS(SELECT 1 FROM public.tower_units u WHERE u.unit_id=(x->>'unitId')::uuid AND u.status='ACTIVE')) THEN RAISE EXCEPTION 'UNIT_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines) x WHERE x->>'kind'='FUND') THEN
   context:=public.tower_collection_action(p_token,'context','{}');
   IF NOT coalesce((context->>'canCollect')::boolean,false) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(lines) LOOP
   unit:=(line->>'unitId')::uuid;amount:=(line->>'amount')::numeric;
   IF line->>'kind'='FUND' THEN
    SELECT value INTO item FROM jsonb_array_elements(coalesce(context->'units','[]')) WHERE value->>'unitId'=unit::text;
    IF item IS NULL OR amount>coalesce((item->>'available')::numeric,0) THEN RAISE EXCEPTION 'COLLECTION_EXCEEDS_REMAINING'; END IF;
    fund:=fund||jsonb_build_array(jsonb_build_object('unitId',unit,'amount',amount,'method',line->>'method'));fund_total:=fund_total+amount;
   END IF;
  END LOOP;
  IF jsonb_array_length(fund)>0 THEN
   IF actor.role='UNION' THEN
    fund_result:=public.tower_union_collect_approve(p_token,jsonb_build_object('lines',fund));
    IF NOT coalesce((fund_result->>'success')::boolean,false) OR (fund_result->>'approvedTotal')::numeric IS DISTINCT FROM fund_total THEN RAISE EXCEPTION 'FUND_COLLECTION_CHANGED'; END IF;
   ELSE fund_result:=public.tower_collection_action(p_token,'create',jsonb_build_object('lines',fund,'submit',true)); END IF;
   IF nullif(fund_result->>'reportId','') IS NULL THEN RAISE EXCEPTION 'COLLECTION_BATCH_FAILED'; END IF;
  END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(lines) WHERE value->>'kind'='PERSONAL' LOOP
   idx:=idx+1;unit:=(line->>'unitId')::uuid;account:=(line->>'accountId')::uuid;amount:=(line->>'amount')::numeric;
   receipt:=public.tower_personal_collections_230(p_token,'collect',jsonb_build_object('unitId',unit,'accountId',account,'amount',amount::text,'reference','BATCH233_'||ref||'_'||idx));
   IF receipt->>'status' IS DISTINCT FROM 'POSTED' OR coalesce((receipt->>'replayed')::boolean,false) THEN RAISE EXCEPTION 'COLLECTION_BATCH_FAILED'; END IF;
   personal:=personal||jsonb_build_array(jsonb_build_object('unitId',unit,'accountId',account,'amount',amount,'receiptId',receipt->>'receiptId'));personal_total:=personal_total+amount;
  END LOOP;
  result:=jsonb_build_object('state','COMMITTED','reference',ref,'fundAmount',fund_total,'personalAmount',personal_total,'fundReportId',fund_result->>'reportId','fundNeedsApproval',actor.role='OPERATOR' AND jsonb_array_length(fund)>0,'personalReceipts',personal,'lineCount',jsonb_array_length(lines),'unitCount',(SELECT count(DISTINCT x->>'unitId') FROM jsonb_array_elements(lines) x));
 EXCEPTION WHEN OTHERS THEN
  error_code:=CASE WHEN SQLERRM IN ('COLLECTION_EXCEEDS_REMAINING','UNIT_NOT_FOUND','FORBIDDEN','FUND_COLLECTION_CHANGED','TASK_NOT_ACCEPTING','TASK_CLOSED','ACCOUNT_INACTIVE') THEN SQLERRM ELSE 'COLLECTION_BATCH_FAILED' END;
  result:=jsonb_build_object('state','REJECTED','reference',ref,'errorCode',error_code,'fundAmount',0,'personalAmount',0);
 END;
 INSERT INTO public.tower_collection_batches_233(reference,actor_id,payload,result,state) VALUES(ref,actor.user_id,canonical,result,result->>'state');
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_collection_batch_233(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_collection_batch_233(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*__________________________________ End of code...*/
