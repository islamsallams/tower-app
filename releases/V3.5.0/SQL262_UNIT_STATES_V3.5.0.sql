/*
Tower App V3.5.0 - SQL_262.
___________________________
*/
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_unit_states_262(
 state_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),code text UNIQUE,name text NOT NULL UNIQUE CHECK(length(btrim(name)) BETWEEN 1 AND 60),
 color text NOT NULL CHECK(color ~ '^#[0-9a-fA-F]{6}$'),enabled boolean NOT NULL DEFAULT true,
 exempt_building boolean NOT NULL DEFAULT false,exempt_services boolean NOT NULL DEFAULT false,exempt_tasks boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_unit_states_262 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_unit_states_262 FROM PUBLIC,anon,authenticated;
INSERT INTO public.tower_unit_states_262(code,name,color,enabled) VALUES('ACTIVE','نشطة','#36c68a',true),('INACTIVE','غير نشطة','#ef4444',false) ON CONFLICT(code) DO NOTHING;
ALTER TABLE public.tower_units ADD COLUMN IF NOT EXISTS state_id_262 uuid REFERENCES public.tower_unit_states_262(state_id);
UPDATE public.tower_units u SET state_id_262=s.state_id FROM public.tower_unit_states_262 s WHERE s.code=CASE WHEN u.status='ACTIVE' THEN 'ACTIVE' ELSE 'INACTIVE' END AND u.state_id_262 IS NULL;
CREATE OR REPLACE FUNCTION public.tower_unit_state_sync_262() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE s public.tower_unit_states_262;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.state_id_262 IS NULL THEN SELECT state_id INTO NEW.state_id_262 FROM public.tower_unit_states_262 WHERE code=CASE WHEN NEW.status='ACTIVE' THEN 'ACTIVE' ELSE 'INACTIVE' END;END IF;
 ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.state_id_262 IS NOT DISTINCT FROM OLD.state_id_262 THEN
  SELECT state_id INTO NEW.state_id_262 FROM public.tower_unit_states_262 WHERE code=CASE WHEN NEW.status='ACTIVE' THEN 'ACTIVE' ELSE 'INACTIVE' END;
 END IF;
 SELECT * INTO s FROM public.tower_unit_states_262 WHERE state_id=NEW.state_id_262;
 IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_STATE_REQUIRED';END IF;
 NEW.status:=CASE WHEN s.enabled THEN 'ACTIVE' ELSE 'INACTIVE' END;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_unit_state_sync_262 ON public.tower_units;
CREATE TRIGGER tower_unit_state_sync_262 BEFORE INSERT OR UPDATE OF status,state_id_262 ON public.tower_units FOR EACH ROW EXECUTE FUNCTION public.tower_unit_state_sync_262();
CREATE OR REPLACE FUNCTION public.tower_unit_exempt_262(p_unit uuid,p_scope text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
 SELECT coalesce((SELECT CASE p_scope WHEN 'BUILDING' THEN s.exempt_building WHEN 'SERVICE' THEN s.exempt_services WHEN 'TASK' THEN s.exempt_tasks ELSE true END FROM public.tower_units u JOIN public.tower_unit_states_262 s ON s.state_id=u.state_id_262 WHERE u.unit_id=p_unit),false)
$f$;
CREATE OR REPLACE FUNCTION public.tower_unit_states_262(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users;id uuid;s public.tower_unit_states_262;result jsonb;n integer;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 -- Shared allocator/generator locks: a preview may age, but each create recalculates under these locks.
 PERFORM pg_advisory_xact_lock(73912016);PERFORM pg_advisory_xact_lock(73912023);
 IF p_action='list' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('stateId',state_id,'code',code,'name',name,'color',color,'enabled',enabled,'exemptBuilding',exempt_building,'exemptServices',exempt_services,'exemptTasks',exempt_tasks) ORDER BY code NULLS LAST,name),'[]') INTO result FROM public.tower_unit_states_262;RETURN result;
 END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD';END IF;
 id:=nullif(p_payload->>'stateId','')::uuid;
 IF p_action='save' THEN
  IF length(btrim(coalesce(p_payload->>'name',''))) NOT BETWEEN 1 AND 60 OR coalesce(p_payload->>'color','') !~ '^#[0-9a-fA-F]{6}$' THEN RAISE EXCEPTION 'INVALID_UNIT_STATE';END IF;
  IF EXISTS(SELECT 1 FROM unnest(ARRAY['enabled','exemptBuilding','exemptServices','exemptTasks']) k WHERE jsonb_typeof(p_payload->k) IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'INVALID_UNIT_STATE';END IF;
  IF id IS NULL THEN
   INSERT INTO public.tower_unit_states_262(name,color,enabled,exempt_building,exempt_services,exempt_tasks) VALUES(btrim(p_payload->>'name'),p_payload->>'color',(p_payload->>'enabled')::boolean,(p_payload->>'exemptBuilding')::boolean,(p_payload->>'exemptServices')::boolean,(p_payload->>'exemptTasks')::boolean) RETURNING state_id INTO id;
  ELSE
   SELECT * INTO s FROM public.tower_unit_states_262 WHERE state_id=id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_STATE_NOT_FOUND';END IF;
   IF s.code IS NOT NULL AND s.enabled IS DISTINCT FROM (p_payload->>'enabled')::boolean THEN RAISE EXCEPTION 'BUILTIN_STATE_AVAILABILITY_FIXED';END IF;
   UPDATE public.tower_unit_states_262 SET name=btrim(p_payload->>'name'),color=p_payload->>'color',enabled=(p_payload->>'enabled')::boolean,exempt_building=(p_payload->>'exemptBuilding')::boolean,exempt_services=(p_payload->>'exemptServices')::boolean,exempt_tasks=(p_payload->>'exemptTasks')::boolean,updated_at=now() WHERE state_id=id;
   UPDATE public.tower_units SET state_id_262=state_id_262,updated_at=now() WHERE state_id_262=id;
  END IF;
 ELSIF p_action='delete' THEN
  IF EXISTS(SELECT 1 FROM public.tower_units WHERE state_id_262=id) THEN RAISE EXCEPTION 'UNIT_STATE_IN_USE';END IF;
  DELETE FROM public.tower_unit_states_262 WHERE state_id=id AND code IS NULL;IF NOT FOUND THEN RAISE EXCEPTION 'BUILTIN_OR_MISSING_STATE';END IF;
 ELSIF p_action='assign' THEN
  IF jsonb_typeof(p_payload->'unitIds') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'unitIds') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'INVALID_UNIT_IDS';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_unit_states_262 WHERE state_id=id) THEN RAISE EXCEPTION 'UNIT_STATE_NOT_FOUND';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_payload->'unitIds') x WHERE NOT EXISTS(SELECT 1 FROM public.tower_units WHERE unit_id=x::uuid)) THEN RAISE EXCEPTION 'INVALID_UNIT_IDS';END IF;
  PERFORM 1 FROM public.tower_units WHERE unit_id IN(SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds')) ORDER BY unit_id FOR UPDATE;
  UPDATE public.tower_units SET state_id_262=id,updated_at=now() WHERE unit_id IN(SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds'));GET DIAGNOSTICS n=ROW_COUNT;
 ELSE RAISE EXCEPTION 'INVALID_ACTION';END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'UNIT_STATE_'||upper(p_action),'UNIT_STATE',id::text);
 RETURN jsonb_build_object('success',true,'stateId',id,'count',n);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_unit_mutate_262(p_token text,p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE result jsonb;id uuid;s public.tower_unit_states_262;
BEGIN
 IF p_action NOT IN ('create','update') OR NOT(p_payload ? 'stateId') THEN RETURN public.tower_unit_mutate(p_token,p_action,p_payload);END IF;
 PERFORM pg_advisory_xact_lock(73912016);PERFORM pg_advisory_xact_lock(73912023);
 SELECT * INTO s FROM public.tower_unit_states_262 WHERE state_id=(p_payload->>'stateId')::uuid;
 IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_STATE_NOT_FOUND';END IF;
 result:=public.tower_unit_mutate(p_token,p_action,(p_payload-'stateId')||jsonb_build_object('status',CASE WHEN s.enabled THEN 'ACTIVE' ELSE 'INACTIVE' END));
 id:=CASE WHEN p_action='create' THEN (result->>'unitId')::uuid ELSE (p_payload->>'unitId')::uuid END;
 UPDATE public.tower_units SET state_id_262=s.state_id WHERE unit_id=id;
 RETURN result;
END $f$;
-- Relation views enforce eligibility BEFORE counts, weights, rounding and allocation.
-- Same final relation names retain existing table-qualified references in installed functions.
CREATE SCHEMA IF NOT EXISTS tower_policy262;
REVOKE ALL ON SCHEMA tower_policy262 FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE VIEW tower_policy262.tower_service_subscriptions AS SELECT sub.* FROM public.tower_service_subscriptions sub JOIN public.tower_services s ON s.service_id=sub.service_id WHERE s.enrollment_status='FINALIZED' OR NOT public.tower_unit_exempt_262(sub.unit_id,'TASK');
REVOKE ALL ON ALL TABLES IN SCHEMA tower_policy262 FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.tower_charge_preview(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_dist text:=upper(coalesce(p_payload->>'distribution','EQUAL_ALL'));
 v_total numeric(14,2); v_active_weight numeric; v_base_weight numeric; v_used numeric(14,2):=0;
 v_unit record; v_weight numeric; v_base numeric(14,2); v_amount numeric(14,2);
 v_deferred boolean; v_custom jsonb:=coalesce(p_payload->'customAmounts','{}'::jsonb);
 v_selected jsonb:=coalesce(p_payload->'unitIds','[]'::jsonb);
 v_delayed jsonb:=coalesce(p_payload->'deferredUnitIds','[]'::jsonb);
 v_category public.tower_collection_categories; v_rows jsonb:='[]'::jsonb;
 v_target_count int; v_active_count int; v_active_idx int:=0; v_sum numeric(14,2):=0;
begin
 if v_dist not in ('EQUAL_ALL','EQUAL_SELECTED','TYPE_POLICY','CATEGORY_POLICY','CUSTOM') then raise exception 'INVALID_DISTRIBUTION'; end if;
 if jsonb_typeof(v_selected)<>'array' or jsonb_typeof(v_delayed)<>'array' or jsonb_typeof(v_custom)<>'object' then raise exception 'INVALID_ALLOCATION_INPUT'; end if;
 if coalesce(p_payload->>'totalAmount','') !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then raise exception 'INVALID_TOTAL'; end if;
 v_total:=(p_payload->>'totalAmount')::numeric;
 if v_total<=0 then raise exception 'INVALID_TOTAL'; end if;
 if v_dist='CATEGORY_POLICY' and nullif(p_payload->>'categoryId','') is not null then
   select * into v_category from public.tower_collection_categories where category_id=(p_payload->>'categoryId')::uuid and status='ACTIVE';
   if not found then raise exception 'CATEGORY_NOT_FOUND'; end if;
 end if;
 -- Serialize target and weight selection in one ordered set; previews cannot write data.
 with targets as (
 select u.unit_id,u.unit_number,u.floor,u.unit_type_id,t.name type_name,
 case when v_dist in ('TYPE_POLICY','CATEGORY_POLICY') then
   case when v_dist='CATEGORY_POLICY' and v_category.category_id is not null
        then greatest(0.01,coalesce(nullif((v_category.weights->>u.unit_type_id::text)::numeric,0),1))
        else greatest(0.01,coalesce(nullif(t.collection_weight,0),1)) end
 else 1::numeric end w,
 (v_delayed ? u.unit_id::text) defer,
 case when (v_custom->>u.unit_id::text) ~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then (v_custom->>u.unit_id::text)::numeric else 0::numeric end custom_amount
 from public.tower_units u join public.tower_unit_types t on t.unit_type_id=u.unit_type_id
 where u.status='ACTIVE' and NOT public.tower_unit_exempt_262(u.unit_id,'BUILDING') and (
 v_dist='EQUAL_ALL' or
 (v_dist in ('TYPE_POLICY','CATEGORY_POLICY') and jsonb_array_length(v_selected)=0) or
 (v_selected ? u.unit_id::text) or
 (v_dist='CUSTOM' and (v_delayed ? u.unit_id::text or coalesce((v_custom->>u.unit_id::text)::numeric,0)>0))
 )
 )
 select count(*), count(*) filter(where not defer),coalesce(sum(w),0),coalesce(sum(w) filter(where not defer),0),
 coalesce(sum(custom_amount) filter(where not defer),0)
 into v_target_count,v_active_count,v_base_weight,v_active_weight,v_sum from targets;
 if v_target_count=0 then raise exception 'UNITS_REQUIRED'; end if;
 if v_dist<>'CUSTOM' and v_active_count=0 then raise exception 'ALL_UNITS_DEFERRED'; end if;
 if v_dist='CUSTOM' and abs(v_sum-v_total)>0.01 then raise exception 'CUSTOM_TOTAL_MISMATCH'; end if;
 for v_unit in
  select u.unit_id,u.unit_number,u.floor,u.unit_type_id,t.name type_name,
  case when v_dist in ('TYPE_POLICY','CATEGORY_POLICY') then
   case when v_dist='CATEGORY_POLICY' and v_category.category_id is not null
       then greatest(0.01,coalesce(nullif((v_category.weights->>u.unit_type_id::text)::numeric,0),1))
       else greatest(0.01,coalesce(nullif(t.collection_weight,0),1)) end else 1::numeric end weight,
  (v_delayed ? u.unit_id::text) deferred,
  case when (v_custom->>u.unit_id::text) ~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then (v_custom->>u.unit_id::text)::numeric else 0::numeric end custom_amount
  from public.tower_units u join public.tower_unit_types t on t.unit_type_id=u.unit_type_id
  where u.status='ACTIVE' and NOT public.tower_unit_exempt_262(u.unit_id,'BUILDING') and (
   v_dist='EQUAL_ALL' or
   (v_dist in ('TYPE_POLICY','CATEGORY_POLICY') and jsonb_array_length(v_selected)=0) or
   (v_selected ? u.unit_id::text) or
   (v_dist='CUSTOM' and ((v_delayed ? u.unit_id::text) or coalesce((v_custom->>u.unit_id::text)::numeric,0)>0))
  ) order by u.unit_number,u.unit_id
 loop
  v_weight:=v_unit.weight;
  if v_dist='CUSTOM' then v_base:=v_unit.custom_amount;
  else v_base:=round(v_total*v_weight/v_base_weight,2); end if;
  if v_unit.deferred then v_amount:=0;
  elsif v_dist='CUSTOM' then v_amount:=v_unit.custom_amount;
  else
   v_active_idx:=v_active_idx+1;
   if v_active_idx=v_active_count then v_amount:=v_total-v_used;
   else v_amount:=round(v_total*v_weight/v_active_weight,2); end if;
   v_used:=v_used+v_amount;
  end if;
  v_rows:=v_rows || jsonb_build_array(jsonb_build_object('unitId',v_unit.unit_id,'unitNumber',v_unit.unit_number,
   'floor',v_unit.floor,'unitTypeId',v_unit.unit_type_id,'unitTypeName',v_unit.type_name,
   'weight',v_weight,'baseAmount',v_base,'amount',v_amount,'deferred',v_unit.deferred));
 end loop;
 return v_rows;
end $function$;

REVOKE ALL ON FUNCTION public.tower_charge_preview(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_charge_preview(jsonb) TO service_role;
DO $install$
DECLARE def text;changed text;
BEGIN
 SELECT pg_get_functiondef('public.tower_service_shared_allocation_action(text,text,uuid)'::regprocedure) INTO def;
 IF position('tower_policy262.tower_service_subscriptions' IN def)=0 THEN
  changed:=replace(def,'public.tower_service_subscriptions','tower_policy262.tower_service_subscriptions');
  changed:=replace(changed,'SELECT count(DISTINCT unit_id), count(*) INTO v_units,v_existing', $replay$
  IF v_service.enrollment_status='FINALIZED' THEN
   SELECT count(*),jsonb_agg(jsonb_build_object('unitId',d.unit_id,'subscriptionId',d.subscription_id,'amount',d.amount) ORDER BY d.unit_id) INTO v_units,v_result FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id;
   RETURN jsonb_build_object('status','FINALIZED','replay',true,'subscriberCount',v_units,'totalBudget',v_service.total_budget,'allocations',coalesce(v_result,'[]'::jsonb));
  END IF;
  SELECT count(DISTINCT unit_id), count(*) INTO v_units,v_existing
  $replay$);
  IF changed=def THEN RAISE EXCEPTION 'TASK_ALLOCATOR_RELATION_NOT_RECOGNIZED';END IF;
  EXECUTE changed;
 END IF;
 SELECT pg_get_functiondef('public.tower_generate_service_dues(text,date)'::regprocedure) INTO def;
 IF position('UNIT_EXEMPT_SKIP_262' IN def)=0 THEN
  changed:=regexp_replace(def,'v_amount\s*:=\s*sub\.amount_snapshot\s*;', $patch$
   -- UNIT_EXEMPT_SKIP_262: advance the exempt period without creating a debt or modifying historical debt.
   IF public.tower_unit_exempt_262(sub.unit_id,'SERVICE') THEN
    UPDATE public.tower_service_subscriptions SET next_renewal_at=(date_trunc('month',sub.next_renewal_at)+interval '1 month')::date,updated_at=now() WHERE subscription_id=sub.subscription_id;
    v_skipped:=v_skipped+1;v_advanced:=v_advanced+1;CONTINUE;
   END IF;
   v_amount:=sub.amount_snapshot;
  $patch$,'i');
  IF changed=def THEN RAISE EXCEPTION 'SERVICE_GENERATOR_NOT_RECOGNIZED';END IF;EXECUTE changed;
 END IF;
END $install$;
-- Fail closed for every alternative writer; never drop a row AFTER computing shares.
-- Existing allocation edits, payments, credits and old obligations retain their original semantics.
CREATE OR REPLACE FUNCTION public.tower_new_due_state_guard_262() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE scope text;sid uuid;
BEGIN
 IF TG_TABLE_NAME='tower_building_allocations' THEN
  SELECT service_id INTO sid FROM public.tower_building_charges WHERE charge_id=NEW.charge_id;
 ELSE
  SELECT service_id INTO sid FROM public.tower_service_subscriptions WHERE subscription_id=NEW.subscription_id;
  IF sid IS NULL THEN SELECT service_id INTO sid FROM public.tower_finance_accounts WHERE account_id=NEW.account_id;END IF;
 END IF;
 scope:=CASE WHEN sid IS NULL THEN 'BUILDING' WHEN EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=sid AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL') THEN 'TASK' ELSE 'SERVICE' END;
 IF public.tower_unit_exempt_262(NEW.unit_id,scope) THEN RAISE EXCEPTION 'UNIT_EXEMPT_NEW_DUE: %',scope;END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_new_due_state_guard_262 ON public.tower_finance_dues;
CREATE TRIGGER tower_new_due_state_guard_262 BEFORE INSERT ON public.tower_finance_dues FOR EACH ROW EXECUTE FUNCTION public.tower_new_due_state_guard_262();
DROP TRIGGER IF EXISTS tower_new_due_state_guard_262 ON public.tower_building_allocations;
CREATE TRIGGER tower_new_due_state_guard_262 BEFORE INSERT ON public.tower_building_allocations FOR EACH ROW EXECUTE FUNCTION public.tower_new_due_state_guard_262();
REVOKE ALL ON FUNCTION public.tower_unit_state_sync_262(),public.tower_unit_exempt_262(uuid,text),public.tower_new_due_state_guard_262(),public.tower_unit_states_262(text,text,jsonb),public.tower_unit_mutate_262(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_unit_states_262(text,text,jsonb),public.tower_unit_mutate_262(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.5.0 - SQL_262.
Code End
*/
