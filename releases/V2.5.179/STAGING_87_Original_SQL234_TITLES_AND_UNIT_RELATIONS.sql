-- Tower App V2.5.179. Install after SQL233. No ledger operations.
BEGIN;
DO $check$ BEGIN
 IF to_regprocedure('public.tower_collection_batch_233(text,text,jsonb)') IS NULL OR
    to_regprocedure('public.tower_member_request_mutate(text,text,jsonb)') IS NULL OR
    to_regprocedure('public.tower_person_label_231(text,text,uuid)') IS NULL OR
    to_regclass('public.tower_titles') IS NULL THEN RAISE EXCEPTION 'SQL233_AND_ACCOUNT_SCHEMA_REQUIRED'; END IF;
END $check$;
-- Real master-data rows; a no-title choice remains distinguishable from missing data.
-- Some older title tables also keep a normalized label; populate it when present.
LOCK TABLE public.tower_titles IN SHARE ROW EXCLUSIVE MODE;
DO $seed$ DECLARE label_value text;cols text:='title_id,label,status';vals text:='gen_random_uuid(),$1,''ACTIVE'''; BEGIN
 IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.tower_titles'::regclass AND attname='normalized' AND NOT attisdropped) THEN cols:=cols||',normalized';vals:=vals||',$1'; END IF;
 FOREACH label_value IN ARRAY ARRAY['أ.','بدون لقب'] LOOP
  IF NOT EXISTS(SELECT 1 FROM public.tower_titles WHERE label=label_value) THEN
   EXECUTE 'INSERT INTO public.tower_titles('||cols||') VALUES('||vals||')' USING label_value;
  END IF;
 END LOOP;
 UPDATE public.tower_titles SET status='ACTIVE' WHERE label IN ('أ.','بدون لقب') AND status<>'ACTIVE';
END $seed$;
ALTER TABLE public.tower_users ALTER COLUMN title SET DEFAULT 'أ.';
-- Only genuinely missing titles acquire the longstanding default; explicit choices are retained.
UPDATE public.tower_users u SET title=t.label FROM public.tower_titles t WHERE u.title_id=t.title_id AND btrim(coalesce(u.title,''))='' AND btrim(coalesce(u.custom_title,''))='';
UPDATE public.tower_users SET title='أ.' WHERE btrim(coalesce(title,''))='' AND btrim(coalesce(custom_title,''))='';
CREATE OR REPLACE FUNCTION public.tower_person_label_231(p_name text,p_title text DEFAULT NULL,p_user uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE n text:=btrim(coalesce(p_name,''));t text:=btrim(coalesce(p_title,''));cnt integer;qualified text;
BEGIN
 IF p_user IS NOT NULL THEN SELECT btrim(name),btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'')) INTO n,t FROM public.tower_users WHERE user_id=p_user; END IF;
 IF n IS NULL OR n='' OR n IN ('—','غير محدد','غير معين','عضو','ساكن','حارس','مستخدم غير معروف','لقب غير مسجل','لقب غير محدد') THEN RETURN coalesce(n,'غير محدد'); END IF;
 IF coalesce(t,'')='' THEN
  SELECT count(DISTINCT btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'أ.'))||' '||btrim(name)),
   min(CASE WHEN btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'أ.'))='بدون لقب' THEN btrim(name) ELSE btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'أ.'))||' '||btrim(name) END)
  INTO cnt,qualified FROM public.tower_users WHERE btrim(coalesce(title,''))||' '||btrim(name)=n OR btrim(coalesce(custom_title,''))||' '||btrim(name)=n;
  IF cnt=1 THEN RETURN qualified; ELSIF cnt>1 THEN RETURN 'لقب غير محدد'; END IF;
  SELECT count(DISTINCT btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'أ.'))),min(btrim(coalesce(nullif(btrim(custom_title),''),nullif(btrim(title),''),'أ.'))) INTO cnt,t FROM public.tower_users WHERE btrim(name)=n;
  IF cnt>1 THEN RETURN 'لقب غير محدد'; END IF;
 END IF;
 t:=coalesce(nullif(btrim(t),''),'أ.');
 IF t='بدون لقب' THEN RETURN n; END IF;
 IF n=t OR left(n,length(t)+1)=t||' ' THEN RETURN n; END IF;
 RETURN t||' '||n;
END $f$;
-- Keep all original transfer checks and behavior inside the same transaction.
-- Snapshot relations by user + unit, so promotion/demotion (or membership replacement) cannot erase them.
CREATE OR REPLACE FUNCTION public.tower_unit_membership_234(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;unit_id_value uuid;target uuid;is_manager boolean;before_rows jsonb;result jsonb;r record;new_relation text;current_relation text;member_id_value uuid;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.must_change_pin THEN RAISE EXCEPTION 'PIN_CHANGE_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION','RESIDENT') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF jsonb_typeof(p_payload)<>'object' OR p_action NOT IN ('transfer','relation','list') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 unit_id_value:=(p_payload->>'unitId')::uuid;
 IF unit_id_value IS NULL THEN RAISE EXCEPTION 'UNIT_REQUIRED'; END IF;
 PERFORM 1 FROM public.tower_units WHERE unit_id=unit_id_value AND status='ACTIVE' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_UNIT'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.tower_members WHERE unit_id=unit_id_value AND user_id=a.user_id AND member_role='MANAGER' AND ended_at IS NULL) INTO is_manager;
 IF a.role='RESIDENT' AND NOT is_manager THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='list' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('userId',m.user_id,'unitMemberId',m.member_id,'unitId',m.unit_id,'name',u.name,'title',u.title,'customTitle',u.custom_title,'displayName',public.tower_person_label_231(u.name,NULL,u.user_id),'memberRole',m.member_role,'relation',m.relation) ORDER BY m.member_role,m.joined_at,m.member_id),'[]') INTO result
   FROM public.tower_members m JOIN public.tower_users u ON u.user_id=m.user_id WHERE m.unit_id=unit_id_value AND m.ended_at IS NULL;
  RETURN result;
 END IF;
 target:=(p_payload->>'userId')::uuid;
 PERFORM m.member_id FROM public.tower_members m WHERE m.unit_id=unit_id_value AND m.ended_at IS NULL ORDER BY m.member_id FOR UPDATE;
 SELECT m.member_id,m.relation INTO member_id_value,current_relation FROM public.tower_members m JOIN public.tower_users u ON u.user_id=m.user_id WHERE m.unit_id=unit_id_value AND m.user_id=target AND m.ended_at IS NULL AND u.status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'TARGET_MUST_BE_ACTIVE_UNIT_MEMBER'; END IF;
 IF p_action='relation' THEN
  new_relation:=btrim(coalesce(p_payload->>'relation',''));
  IF jsonb_typeof(p_payload->'relation')<>'string' OR new_relation='' OR length(new_relation)>80 OR new_relation~'[[:cntrl:]]' OR NOT(p_payload ? 'expectedRelation') THEN RAISE EXCEPTION 'INVALID_RELATION'; END IF;
  IF current_relation IS DISTINCT FROM (p_payload->>'expectedRelation') THEN RAISE EXCEPTION 'MEMBERSHIP_CHANGED_REFRESH'; END IF;
  UPDATE public.tower_members SET relation=new_relation WHERE member_id=member_id_value;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'UNIT_MEMBER_RELATION_234','MEMBER',member_id_value::text);
  RETURN jsonb_build_object('success',true,'relation',new_relation);
 END IF;
 SELECT jsonb_agg(jsonb_build_object('userId',user_id,'relation',relation)) INTO before_rows FROM public.tower_members WHERE unit_id=unit_id_value AND ended_at IS NULL;
 result:=public.tower_member_request_mutate(p_token,'transfer',jsonb_build_object('unitId',unit_id_value,'userId',target));
 IF result IS NULL OR (jsonb_typeof(result)='object' AND (result->>'success'='false' OR result ? 'error')) OR result='false'::jsonb THEN RAISE EXCEPTION 'TRANSFER_NOT_COMPLETED'; END IF;
 -- If the legacy engine returned without transferring, roll everything back rather than report success.
 IF NOT EXISTS(SELECT 1 FROM public.tower_members WHERE unit_id=unit_id_value AND user_id=target AND member_role='MANAGER' AND ended_at IS NULL) OR
    EXISTS(SELECT 1 FROM public.tower_members WHERE unit_id=unit_id_value AND user_id<>target AND member_role='MANAGER' AND ended_at IS NULL) THEN RAISE EXCEPTION 'TRANSFER_NOT_COMPLETED'; END IF;
 FOR r IN SELECT * FROM jsonb_to_recordset(coalesce(before_rows,'[]')) AS x("userId" uuid,relation text) LOOP
  UPDATE public.tower_members SET relation=r.relation WHERE unit_id=unit_id_value AND user_id=r."userId" AND ended_at IS NULL AND relation IS DISTINCT FROM r.relation;
 END LOOP;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_unit_membership_234(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_unit_membership_234(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
