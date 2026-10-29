/*
Tower App V3.5.0 - SQL_261.
___________________________
*/
BEGIN;
ALTER TABLE public.tower_users ADD COLUMN IF NOT EXISTS first_name_261 text;
ALTER TABLE public.tower_users ADD COLUMN IF NOT EXISTS rest_name_261 text;
ALTER TABLE public.tower_registration_requests ADD COLUMN IF NOT EXISTS first_name_261 text;
ALTER TABLE public.tower_registration_requests ADD COLUMN IF NOT EXISTS rest_name_261 text;
ALTER TABLE public.tower_member_requests ADD COLUMN IF NOT EXISTS first_name_261 text;
ALTER TABLE public.tower_member_requests ADD COLUMN IF NOT EXISTS rest_name_261 text;
UPDATE public.tower_users SET first_name_261=split_part(btrim(name),' ',1),rest_name_261=btrim(substr(btrim(name),length(split_part(btrim(name),' ',1))+1)) WHERE first_name_261 IS NULL;
UPDATE public.tower_registration_requests SET first_name_261=split_part(btrim(name),' ',1),rest_name_261=btrim(substr(btrim(name),length(split_part(btrim(name),' ',1))+1)) WHERE first_name_261 IS NULL;
UPDATE public.tower_member_requests SET first_name_261=split_part(btrim(candidate_name),' ',1),rest_name_261=btrim(substr(btrim(candidate_name),length(split_part(btrim(candidate_name),' ',1))+1)) WHERE first_name_261 IS NULL;
CREATE OR REPLACE FUNCTION public.tower_person_name_sync_261() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $f$
DECLARE data jsonb:=to_jsonb(NEW);old_data jsonb;key text:=CASE WHEN TG_TABLE_NAME='tower_member_requests' THEN 'candidate_name' ELSE 'name' END;full_name text;first_name text;rest_name text;explicit jsonb;
BEGIN
 full_name:=btrim(data->>key);first_name:=data->>'first_name_261';rest_name:=coalesce(data->>'rest_name_261','');
 IF TG_OP='UPDATE' THEN old_data:=to_jsonb(OLD);END IF;
 explicit:=nullif(current_setting('tower.explicit_name_261',true),'')::jsonb;
 IF explicit->>'name'=full_name THEN first_name:=explicit->>'firstName';rest_name:=explicit->>'restName';
 ELSIF TG_OP='UPDATE' AND (data->'first_name_261',data->'rest_name_261') IS DISTINCT FROM (old_data->'first_name_261',old_data->'rest_name_261') THEN
  full_name:=concat_ws(' ',nullif(btrim(first_name),''),nullif(btrim(rest_name),''));
 ELSIF first_name IS NULL OR (TG_OP='UPDATE' AND data->>key IS DISTINCT FROM old_data->>key) THEN
  first_name:=split_part(full_name,' ',1);rest_name:=btrim(substr(full_name,length(first_name)+1));
 END IF;
 IF length(btrim(coalesce(first_name,''))) NOT BETWEEN 1 AND 80 OR length(full_name)>80 OR length(rest_name)>80 OR first_name~'[[:cntrl:]]' OR rest_name~'[[:cntrl:]]' THEN RAISE EXCEPTION 'INVALID_PERSON_NAME';END IF;
 NEW:=jsonb_populate_record(NEW,jsonb_build_object(key,full_name,'first_name_261',btrim(first_name),'rest_name_261',btrim(rest_name)));RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_person_name_sync_261 ON public.tower_users;
CREATE TRIGGER tower_person_name_sync_261 BEFORE INSERT OR UPDATE OF name,first_name_261,rest_name_261 ON public.tower_users FOR EACH ROW EXECUTE FUNCTION public.tower_person_name_sync_261();
DROP TRIGGER IF EXISTS tower_person_name_sync_261 ON public.tower_registration_requests;
CREATE TRIGGER tower_person_name_sync_261 BEFORE INSERT OR UPDATE OF name,first_name_261,rest_name_261 ON public.tower_registration_requests FOR EACH ROW EXECUTE FUNCTION public.tower_person_name_sync_261();
DROP TRIGGER IF EXISTS tower_person_name_sync_261 ON public.tower_member_requests;
CREATE TRIGGER tower_person_name_sync_261 BEFORE INSERT OR UPDATE OF candidate_name,first_name_261,rest_name_261 ON public.tower_member_requests FOR EACH ROW EXECUTE FUNCTION public.tower_person_name_sync_261();
CREATE OR REPLACE FUNCTION public.tower_person_action_261(p_token text,p_engine text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE result jsonb;first_name text;rest_name text;full_name text;request_row jsonb;previous_setting text;
BEGIN
 IF p_payload ? 'firstName' THEN
  IF jsonb_typeof(p_payload->'firstName') IS DISTINCT FROM 'string' OR jsonb_typeof(p_payload->'restName') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'INVALID_PERSON_NAME';END IF;
  first_name:=btrim(p_payload->>'firstName');rest_name:=btrim(p_payload->>'restName');
  full_name:=concat_ws(' ',nullif(first_name,''),nullif(rest_name,''));
  IF length(first_name)<1 OR length(full_name)>80 OR first_name~'[[:cntrl:]]' OR rest_name~'[[:cntrl:]]' THEN RAISE EXCEPTION 'INVALID_PERSON_NAME';END IF;
  p_payload:=p_payload||jsonb_build_object('name',full_name);
 ELSIF p_engine='onboarding' AND p_action='registrationApprove' THEN
  SELECT to_jsonb(r) INTO request_row FROM public.tower_registration_requests r WHERE request_id=(p_payload->>'requestId')::uuid;
 ELSIF p_engine='memberApprove' AND p_action='approve' THEN
  SELECT to_jsonb(r)||jsonb_build_object('name',candidate_name) INTO request_row FROM public.tower_member_requests r WHERE request_id=(p_payload->>'requestId')::uuid;
 END IF;
 IF request_row IS NOT NULL THEN first_name:=request_row->>'first_name_261';rest_name:=request_row->>'rest_name_261';full_name:=request_row->>'name';END IF;
 previous_setting:=current_setting('tower.explicit_name_261',true);
 PERFORM set_config('tower.explicit_name_261',CASE WHEN first_name IS NULL THEN '' ELSE jsonb_build_object('name',full_name,'firstName',first_name,'restName',rest_name)::text END,true);
 -- Each original engine retains authentication, permissions, transaction, and credential rules.
 IF p_engine='createUser' AND p_action='create' THEN result:=public.tower_admin_create_user(p_token,p_payload);
 ELSIF p_engine='account' AND p_action IN ('profile','update','resetPin') THEN result:=public.tower_user_account_mutate(p_token,p_action,p_payload);
 ELSIF p_engine='onboarding' AND p_action IN ('registrationContext','registrationSubmit','registrationApprove','registrationReject','registrationActivate','registrationList','resetSubmit','resetComplete','resetIssue','resetList') THEN result:=public.tower_onboarding(p_action=>p_action,p_token=>p_token,p_payload=>p_payload);
 ELSIF p_engine='memberRequest' AND p_action IN ('request','reject') THEN result:=public.tower_member_request_mutate(p_token,p_action,p_payload);
 ELSIF p_engine='memberUpdate' AND p_action='update' THEN result:=public.tower_member_request_update_pending(p_token,p_payload);
 ELSIF p_engine='memberApprove' AND p_action='approve' THEN result:=public.tower_approve_member_request(p_token,p_payload);
 ELSE RAISE EXCEPTION 'INVALID_ACTION';END IF;
 PERFORM set_config('tower.explicit_name_261',coalesce(previous_setting,''),true);
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_person_name_sync_261(),public.tower_person_action_261(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_person_action_261(text,text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.5.0 - SQL_261.
Code End
*/
