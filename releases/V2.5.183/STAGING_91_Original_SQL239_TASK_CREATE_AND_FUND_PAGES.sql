/*
Tower App V2.5.183 - SQL_239.

___________________________
*/
BEGIN;
-- Recover the known SQL238 installation failure automatically; no earlier file needs re-running.
DO $repair238$
BEGIN
 IF to_regprocedure('public.tower_assert_unit_account_view_238(text,uuid,uuid)') IS NULL THEN
  EXECUTE $body238$
DO $check$ BEGIN
 IF to_regprocedure('public.tower_task_management_236(text,text,uuid,jsonb)') IS NULL THEN RAISE EXCEPTION 'SQL236_REQUIRED'; END IF;
 IF to_regclass('public.tower_unit_fund_visibility') IS NULL THEN RAISE EXCEPTION 'UNIT_VISIBILITY_SCHEMA_REQUIRED'; END IF;
END $check$;
-- Existing storage keeps its value. The permission now concerns unit accounts, never the general fund.
CREATE OR REPLACE FUNCTION public.tower_unit_fund_visibility_action(p_token text,p_unit_id uuid,p_action text,p_allow boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;member_role text;allowed boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.role<>'RESIDENT' OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 SELECT m.member_role INTO member_role FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id WHERE m.user_id=a.user_id AND m.unit_id=p_unit_id AND m.ended_at IS NULL AND u.status='ACTIVE';
 IF member_role IS NULL THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 IF p_action='set' THEN
  IF member_role<>'MANAGER' OR p_allow IS NULL THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  PERFORM 1 FROM public.tower_units WHERE unit_id=p_unit_id FOR UPDATE;
  INSERT INTO public.tower_unit_fund_visibility(unit_id,members_can_view,changed_by) VALUES(p_unit_id,p_allow,a.user_id)
  ON CONFLICT(unit_id) DO UPDATE SET members_can_view=EXCLUDED.members_can_view,changed_by=EXCLUDED.changed_by,updated_at=now();
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'UNIT_ACCOUNT_VISIBILITY','UNIT',p_unit_id::text);
 ELSIF p_action<>'get' OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 SELECT coalesce(v.members_can_view,true) INTO allowed FROM public.tower_units u LEFT JOIN public.tower_unit_fund_visibility v ON v.unit_id=u.unit_id WHERE u.unit_id=p_unit_id;
 RETURN jsonb_build_object('unitId',p_unit_id,'membersCanView',allowed,'isManager',member_role='MANAGER','canViewFund',true,'canViewAccount',member_role='MANAGER' OR allowed);
END $f$;
-- Private permission guard. A task operator's separately authorized work is not an ordinary unit-account read.
CREATE OR REPLACE FUNCTION public.tower_assert_unit_account_view_238(p_token text,p_unit uuid,p_service uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;uid uuid:=p_unit;visibility jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role IN ('ADMIN','UNION') THEN RETURN; END IF;
 IF p_service IS NOT NULL AND public.tower_task_responsible_236(a.user_id,p_service) THEN RETURN; END IF;
 IF a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF uid IS NULL THEN SELECT m.unit_id INTO uid FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id WHERE m.user_id=a.user_id AND m.ended_at IS NULL AND u.status='ACTIVE' ORDER BY m.unit_id LIMIT 1; END IF;
 visibility:=public.tower_unit_fund_visibility_action(p_token,uid,'get',NULL);
 IF NOT coalesce((visibility->>'canViewAccount')::boolean,false) THEN RAISE EXCEPTION 'UNIT_ACCOUNT_ACCESS_DENIED'; END IF;
END $f$;
REVOKE ALL ON FUNCTION public.tower_assert_unit_account_view_238(text,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
-- Narrow patches preserve installed engines, amounts and filters. Markers make reruns idempotent.
DO $patch$
DECLARE spec record;oid_value regprocedure;src text;needle text;injection text;
BEGIN
 FOR spec IN SELECT * FROM (VALUES
 ('tower_resident_dues_page(text,text,text,text,text,integer,integer)','NULL','NULL'),
 ('tower_resident_dues_page_for_unit(text,uuid,text,text,text,text,integer,integer)','p_unit_id','NULL'),
 ('tower_unit_task_balances_read_for_unit(text,uuid)','p_unit_id','NULL'),
 ('tower_service_workspace_read_232(text,uuid,uuid)','p_unit','p_service'),
 ('tower_task_project_read_229(text,uuid,uuid)','p_unit','p_service')
 ) v(signature,unit_expr,service_expr) LOOP
  oid_value:=to_regprocedure('public.'||spec.signature);
  IF oid_value IS NULL THEN RAISE EXCEPTION 'REQUIRED_ACCOUNT_READER_MISSING: %',spec.signature; END IF;
  src:=pg_get_functiondef(oid_value);
  IF position('tower_assert_unit_account_view_238' IN src)=0 THEN
   -- Match the outer BEGIN only, before the first statement of these known PL/pgSQL readers.
   needle:=substring(src FROM E'(?in)^[ \t]*BEGIN[ \t]*\r?$');
   IF needle IS NULL THEN RAISE EXCEPTION 'UNSUPPORTED_ACCOUNT_READER: %',spec.signature; END IF;
   injection:=needle||' PERFORM public.tower_assert_unit_account_view_238(p_token,'||spec.unit_expr||','||spec.service_expr||');'||chr(10);
   src:=overlay(src placing injection FROM position(needle IN src) FOR length(needle));EXECUTE src;
  END IF;
 END LOOP;
 oid_value:=to_regprocedure('public.tower_resident_fund_overview_for_unit(text,uuid)');
 IF oid_value IS NULL THEN RAISE EXCEPTION 'FUND_OVERVIEW_REQUIRED'; END IF;
 src:=pg_get_functiondef(oid_value);
 IF position('LEFT JOIN public.tower_unit_fund_visibility vis' IN src)>0 THEN
  src:=replace(src,'LEFT JOIN public.tower_unit_fund_visibility vis ON vis.unit_id=m.unit_id','');
  src:=replace(src,'AND (m.member_role=''MANAGER'' OR COALESCE(vis.members_can_view,true))','');
  IF position('vis.members_can_view' IN src)>0 THEN RAISE EXCEPTION 'UNSUPPORTED_FUND_VISIBILITY_GUARD'; END IF;
  EXECUTE src;
 END IF;
 -- Normalize only an explicitly blank proposed contribution. Negative/invalid values still fail validation.
 oid_value:='public.tower_task_controls_235(text,uuid,text,jsonb)'::regprocedure;src:=pg_get_functiondef(oid_value);
 IF position('-- blank contribution238' IN src)=0 THEN
  needle:='patch:=p_payload->''patch'';';
  IF position(needle IN src)=0 THEN RAISE EXCEPTION 'UNSUPPORTED_TASK_CONTROLS'; END IF;
  src:=replace(src,needle,needle||chr(10)||' -- blank contribution238'||chr(10)||' IF patch ? ''fundContributionProposed'' AND jsonb_typeof(patch->''fundContributionProposed'')=''string'' AND btrim(patch->>''fundContributionProposed'')='''' THEN patch:=jsonb_set(patch,''{fundContributionProposed}'',''"0"''::jsonb); END IF;');
  EXECUTE src;
 END IF;
END $patch$;
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
 IF financial AND length(reason)=0 THEN reason:='تعديل مالي مسجّل من الإدارة — بدون سبب إضافي'; END IF;
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

REVOKE ALL ON FUNCTION public.tower_unit_fund_visibility_action(text,uuid,text,boolean),public.tower_service_edit_230(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_unit_fund_visibility_action(text,uuid,text,boolean),public.tower_service_edit_230(text,jsonb) TO service_role;

-- Preserve the installed one-step undo, credit and later-activity checks. Only bind the requested latest identity.
DO $undo$
DECLARE src text;needle text;
BEGIN
 src:=pg_get_functiondef('public.tower_trip_account(text,text,jsonb)'::regprocedure);
 IF position('-- expected latest settlement238' IN src)=0 THEN
  needle:='if not found or v_set.status<>''ACTIVE'' then raise exception ''ONLY_LATEST_SETTLEMENT''; end if;';
  IF position(needle IN src)=0 THEN RAISE EXCEPTION 'UNSUPPORTED_TRIP_UNDO_GUARD'; END IF;
  src:=replace(src,needle,needle||chr(10)||'  -- expected latest settlement238'||chr(10)||'  IF nullif(p_payload->>''expectedSettlementId'','''') IS NOT NULL AND p_payload->>''expectedSettlementId''<>v_set.settlement_id::text THEN RAISE EXCEPTION ''SETTLEMENT_CHANGED_REFRESH''; END IF;');
  EXECUTE src;
 END IF;
END $undo$;
$body238$;
 END IF;
END $repair238$;
DO $check$ BEGIN
 IF to_regprocedure('public.tower_assert_unit_account_view_238(text,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'SQL238_REQUIRED'; END IF;
END $check$;
-- Creation and optional participation terms share one transaction and one original reference.
CREATE OR REPLACE FUNCTION public.tower_task_create_239(p_token text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;result jsonb;sid uuid;ver bigint;deadline date;targets jsonb:=coalesce(p_payload->'targetUnits','[]'::jsonb);
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(coalesce(p_payload->>'scope',''))>4000 OR length(coalesce(p_payload->>'policy',''))>4000 THEN RAISE EXCEPTION 'INVALID_TASK_FIELDS'; END IF;
 IF jsonb_typeof(targets) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
 IF jsonb_array_length(targets)>1000 THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(targets) x WHERE jsonb_typeof(x)<>'string' OR (x#>>'{}') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(targets) x WHERE NOT EXISTS(SELECT 1 FROM public.tower_units u WHERE u.unit_id=x::uuid AND u.status='ACTIVE')) THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
 IF nullif(p_payload->>'deadline','') IS NOT NULL THEN
  IF p_payload->>'deadline' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'INVALID_TASK_DEADLINE'; END IF;
  deadline:=(p_payload->>'deadline')::date;
  IF deadline<(now() AT TIME ZONE 'Africa/Cairo')::date THEN RAISE EXCEPTION 'INVALID_TASK_DEADLINE'; END IF;
 END IF;
 result:=public.tower_task_project_action_229(p_token,'create',NULL,p_payload);
 IF coalesce((result->>'replayed')::boolean,false) THEN RETURN result; END IF;
 sid:=(result->>'serviceId')::uuid;
 IF p_payload ?| ARRAY['targetUnits','policy','deadline'] THEN
  SELECT version INTO ver FROM public.tower_task_projects WHERE service_id=sid FOR UPDATE;
  PERFORM public.tower_task_project_action_229(p_token,'terms',sid,jsonb_build_object('version',ver,'scope',coalesce(p_payload->>'scope',''),'policy',coalesce(p_payload->>'policy',''),'targetUnits',targets,'deadline',deadline,'distribution','EQUAL','agreedAmounts','[]'::jsonb,'minimumStartAmount','0'));
 END IF;
 RETURN result;
END $f$;
-- Match the existing Arabic client search without requiring an unaccent extension.
CREATE OR REPLACE FUNCTION public.tower_search_normalize_239(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO pg_catalog,public AS $normalize$
 SELECT btrim(regexp_replace(translate(lower(coalesce(p_value,'')),'أإآٱىؤئة','اااايويه'),U&'[\064B-\065F\0670\06D6-\06ED\0640]','','g'))
$normalize$;
REVOKE ALL ON FUNCTION public.tower_search_normalize_239(text) FROM PUBLIC,anon,authenticated,service_role;
-- Read the entire history through bounded pages; never substitute the dashboard's recent entries.
CREATE OR REPLACE FUNCTION public.tower_fund_page_239(p_token text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;query text:=btrim(coalesce(p_payload->>'query',''));kind text:=coalesce(p_payload->>'kind','ALL');requested_page integer;actual_page integer;total integer;rows jsonb;from_day date;to_day date;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(query)>200 OR kind NOT IN ('ALL','INCOME','EXPENSE','CANCELLED') OR coalesce(p_payload->>'page','1') !~ '^[0-9]{1,7}$' THEN RAISE EXCEPTION 'INVALID_FUND_FILTER'; END IF;
 requested_page:=coalesce((p_payload->>'page')::integer,1);IF requested_page<1 OR requested_page>1000000 THEN RAISE EXCEPTION 'INVALID_FUND_FILTER'; END IF;
 IF nullif(p_payload->>'from','') IS NOT NULL THEN IF p_payload->>'from' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'INVALID_FUND_FILTER'; END IF;from_day:=(p_payload->>'from')::date;END IF;
 IF nullif(p_payload->>'to','') IS NOT NULL THEN IF p_payload->>'to' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'INVALID_FUND_FILTER'; END IF;to_day:=(p_payload->>'to')::date;END IF;
 IF from_day>to_day THEN RAISE EXCEPTION 'INVALID_FUND_FILTER'; END IF;
 -- JSON projection supports the existing entry_date/created_at presentation variants without selecting private columns.
 WITH projected AS MATERIALIZED (
  SELECT e.entry_id,e.entry_type,e.amount,e.status,to_jsonb(e)->>'description' description,to_jsonb(e)->>'category' category,to_jsonb(e)->>'reference' reference,
    coalesce(nullif(to_jsonb(e)->>'entry_date',''),to_jsonb(e)->>'created_at')::timestamptz stamp
  FROM public.tower_fund_entries e
 ), filtered AS MATERIALIZED (
  SELECT * FROM projected WHERE
   (kind='ALL' OR kind='CANCELLED' AND status<>'ACTIVE' OR kind IN ('INCOME','EXPENSE') AND status='ACTIVE' AND entry_type=kind)
   AND (from_day IS NULL OR (stamp AT TIME ZONE 'Africa/Cairo')::date>=from_day)
   AND (to_day IS NULL OR (stamp AT TIME ZONE 'Africa/Cairo')::date<=to_day)
   AND NOT EXISTS(SELECT 1 FROM regexp_split_to_table(public.tower_search_normalize_239(query),E'\\s+') token WHERE token<>'' AND position(token IN public.tower_search_normalize_239(concat_ws(' ',description,category,reference)))=0)
 ), info AS (SELECT count(*)::integer n FROM filtered), paging AS (SELECT n,greatest(1,least(requested_page,greatest(1,(n+11)/12))) p FROM info), paged AS (
  SELECT f.* FROM filtered f ORDER BY stamp DESC NULLS LAST,entry_id DESC LIMIT 12 OFFSET (SELECT (p-1)*12 FROM paging)
 )
 SELECT n,p,coalesce((SELECT jsonb_agg(jsonb_build_object('entryId',entry_id,'entryType',entry_type,'amount',amount,'status',status,'description',coalesce(description,''),'category',coalesce(category,''),'reference',coalesce(reference,''),'entryDate',stamp) ORDER BY stamp DESC NULLS LAST,entry_id DESC) FROM paged),'[]'::jsonb)
 INTO total,actual_page,rows FROM paging;
 RETURN jsonb_build_object('scope','BUILDING_FUND_PAGE','readOnly',true,'total',total,'page',actual_page,'pageSize',12,'pages',greatest(1,(total+11)/12),'rows',rows);
END $f$;
REVOKE ALL ON FUNCTION public.tower_task_create_239(text,jsonb),public.tower_fund_page_239(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_create_239(text,jsonb),public.tower_fund_page_239(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.183 - SQL_239.

Code End
*/
