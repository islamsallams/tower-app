/*
Tower App V3.6.0 - SQL_264.
___________________________
*/
BEGIN;
-- Display metadata only. Existing amounts, policies and historical allocations are untouched.
ALTER TABLE public.tower_unit_types ADD COLUMN IF NOT EXISTS color_264 text NOT NULL DEFAULT '#2f80ed';
DO $f$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.tower_unit_types'::regclass AND conname='tower_unit_type_color_264') THEN
  ALTER TABLE public.tower_unit_types ADD CONSTRAINT tower_unit_type_color_264 CHECK(color_264 ~ '^#[0-9a-fA-F]{6}$');
 END IF;
END $f$;
CREATE OR REPLACE FUNCTION public.tower_unit_type_mutate_264(p_token text,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users;result jsonb;id uuid;v_color text;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IS NULL OR p_action NOT IN ('create','update','deactivate','reactivate') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 IF p_action IN ('create','update') AND p_payload ? 'color' THEN
  v_color:=p_payload->>'color';
  IF v_color IS NULL OR v_color !~ '^#[0-9a-fA-F]{6}$' THEN RAISE EXCEPTION 'INVALID_UNIT_TYPE_COLOR';END IF;
 END IF;
 -- Same lock/order as the existing type engine, one transaction for type and color.
 PERFORM pg_advisory_xact_lock(71120260);
 result:=public.tower_unit_type_mutate(p_token,p_action,p_payload-'color');
 IF result IS NULL OR result->>'success'='false' OR result ? 'error' THEN RAISE EXCEPTION 'UNIT_TYPE_NOT_SAVED';END IF;
 IF p_action IN ('create','update') AND v_color IS NOT NULL THEN
  id:=CASE WHEN p_action='create' THEN (result->>'unitTypeId')::uuid ELSE (p_payload->>'unitTypeId')::uuid END;
  IF id IS NULL THEN RAISE EXCEPTION 'UNIT_TYPE_NOT_SAVED';END IF;
  UPDATE public.tower_unit_types SET color_264=lower(v_color) WHERE unit_type_id=id;
  IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_TYPE_NOT_SAVED';END IF;
 END IF;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_unit_type_mutate_264(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_unit_type_mutate_264(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.6.0 - SQL_264.
Code End
*/
