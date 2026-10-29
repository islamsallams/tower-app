/*
Tower App V3.4.0 - SQL_256.
___________________________
*/
BEGIN;
ALTER TABLE public.tower_brand_presentation_251 DROP CONSTRAINT IF EXISTS tower_brand_presentation_251_line_gap_check;
ALTER TABLE public.tower_brand_presentation_251 ADD CONSTRAINT tower_brand_presentation_251_line_gap_check CHECK(line_gap BETWEEN -8 AND 24);
CREATE OR REPLACE FUNCTION public.tower_brand_settings_256(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;result jsonb;size_value numeric;gap_value numeric;b jsonb;p public.tower_brand_presentation_251;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action IS NULL OR p_action NOT IN('get','save') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 IF p_action='save' THEN
  b:=p_payload->'branding';
  IF b ? 'logoSize' AND jsonb_typeof(b->'logoSize') IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'INVALID_BRAND_GEOMETRY'; END IF;
  IF b ? 'lineGap' AND jsonb_typeof(b->'lineGap') IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'INVALID_BRAND_GEOMETRY'; END IF;
  PERFORM pg_advisory_xact_lock(71300251);
  SELECT * INTO p FROM public.tower_brand_presentation_251 WHERE singleton;
  size_value:=coalesce((b->>'logoSize')::numeric,p.logo_size,34);gap_value:=coalesce((b->>'lineGap')::numeric,p.line_gap,2);
  IF size_value<>trunc(size_value) OR gap_value<>trunc(gap_value) OR size_value NOT BETWEEN 24 AND 80 OR gap_value NOT BETWEEN -8 AND 24 THEN RAISE EXCEPTION 'INVALID_BRAND_GEOMETRY'; END IF;
 END IF;
 result:=public.tower_brand_settings_252(p_token,p_action,p_payload);
 IF p_action='save' THEN UPDATE public.tower_brand_presentation_251 SET logo_size=size_value,line_gap=gap_value WHERE singleton; END IF;
 SELECT * INTO p FROM public.tower_brand_presentation_251 WHERE singleton;
 RETURN result||jsonb_build_object('branding',coalesce(result->'branding','{}'::jsonb)||jsonb_build_object('logoSize',coalesce(p.logo_size,34),'lineGap',coalesce(p.line_gap,2)));
END $f$;
REVOKE ALL ON FUNCTION public.tower_brand_settings_256(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_brand_settings_256(text,text,jsonb) TO service_role;
-- Public branding typography only: no sessions, users or administrative settings.
CREATE OR REPLACE FUNCTION public.tower_public_ui_256()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $pub$
DECLARE row_value jsonb;p jsonb;result jsonb:='{"fontFamily":"Cairo"}';d text;k text;key text;v jsonb;n numeric;family text;
BEGIN
 SELECT to_jsonb(t) INTO row_value FROM public.tower_ui_preferences t LIMIT 1;
 p:=coalesce(row_value->'preferences',row_value->'ui_preferences',row_value->'settings',row_value->'value',row_value,'{}');
 p:=coalesce(p->'uiPreferences',p);
 family:=coalesce(p->>'fontFamily',p->>'font_family');
 IF family IN ('Cairo','Tajawal','Noto Sans Arabic','Noto Kufi Arabic') THEN result:=jsonb_build_object('fontFamily',family); END IF;
 FOREACH d IN ARRAY ARRAY['desktop','mobile'] LOOP
  FOREACH k IN ARRAY ARRAY['Helper','Body','Label','Title'] LOOP
   key:=d||k;v:=coalesce(p->key,p->(d||'_'||lower(k)));
   IF jsonb_typeof(v)='number' THEN n:=(v#>>'{}')::numeric;IF n BETWEEN 8 AND 40 THEN result:=result||jsonb_build_object(key,n);END IF;END IF;
  END LOOP;
 END LOOP;
 RETURN result;
END $pub$;
REVOKE ALL ON FUNCTION public.tower_public_ui_256() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_public_ui_256() TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.4.0 - SQL_256.
Code End
*/
