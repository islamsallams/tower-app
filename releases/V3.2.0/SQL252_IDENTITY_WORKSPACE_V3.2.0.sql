/*
Tower App V3.2.0 - SQL_252.
___________________________
*/
BEGIN;
ALTER TABLE public.tower_brand_presentation_251 ADD COLUMN IF NOT EXISTS login_fade boolean NOT NULL DEFAULT true;
CREATE OR REPLACE FUNCTION public.tower_brand_settings_252(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;result jsonb;fonts jsonb;fade boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('get','save') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 IF p_action='save' THEN
  IF p_payload ? 'uiPreferences' AND jsonb_typeof(p_payload->'uiPreferences') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_UI_PREFERENCES'; END IF;
  IF p_payload->'branding' ? 'loginFade' AND jsonb_typeof(p_payload->'branding'->'loginFade') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_BRAND_FADE'; END IF;
  PERFORM pg_advisory_xact_lock(71300251);
 END IF;
 -- Existing validation, permissions, settings and focus save remain authoritative.
 result:=public.tower_brand_settings_251(p_token,p_action,p_payload);
 IF p_action='save' THEN
  IF p_payload ? 'uiPreferences' THEN
   PERFORM public.tower_ui_preferences_action(p_token,'update',p_payload->'uiPreferences');
  END IF;
  SELECT coalesce((p_payload->'branding'->>'loginFade')::boolean,login_fade,true) INTO fade FROM public.tower_brand_presentation_251 WHERE singleton;
  UPDATE public.tower_brand_presentation_251 SET login_fade=coalesce(fade,true) WHERE singleton;
 END IF;
 fonts:=to_jsonb(public.tower_ui_preferences_action(p_token,'get','{}'::jsonb));
 SELECT login_fade INTO fade FROM public.tower_brand_presentation_251 WHERE singleton;
 RETURN result||jsonb_build_object('branding',coalesce(result->'branding','{}'::jsonb)||jsonb_build_object('loginFade',coalesce(fade,true)),'uiPreferences',fonts);
END $f$;
REVOKE ALL ON FUNCTION public.tower_brand_settings_252(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_brand_settings_252(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.2.0 - SQL_252.
Code End
*/
