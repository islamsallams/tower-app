/*
Tower App V3.3.0 - SQL_253.
___________________________
*/
BEGIN;
ALTER TABLE public.tower_brand_presentation_251
 ADD COLUMN IF NOT EXISTS logo_size smallint NOT NULL DEFAULT 34 CHECK(logo_size BETWEEN 24 AND 80),
 ADD COLUMN IF NOT EXISTS line_gap smallint NOT NULL DEFAULT 2 CHECK(line_gap BETWEEN 0 AND 24);
CREATE OR REPLACE FUNCTION public.tower_brand_settings_253(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
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
  IF size_value<>trunc(size_value) OR gap_value<>trunc(gap_value) OR size_value NOT BETWEEN 24 AND 80 OR gap_value NOT BETWEEN 0 AND 24 THEN RAISE EXCEPTION 'INVALID_BRAND_GEOMETRY'; END IF;
 END IF;
 result:=public.tower_brand_settings_252(p_token,p_action,p_payload);
 IF p_action='save' THEN UPDATE public.tower_brand_presentation_251 SET logo_size=size_value,line_gap=gap_value WHERE singleton; END IF;
 SELECT * INTO p FROM public.tower_brand_presentation_251 WHERE singleton;
 RETURN result||jsonb_build_object('branding',coalesce(result->'branding','{}'::jsonb)||jsonb_build_object('logoSize',coalesce(p.logo_size,34),'lineGap',coalesce(p.line_gap,2)));
END $f$;
REVOKE ALL ON FUNCTION public.tower_brand_settings_253(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_brand_settings_253(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.3.0 - SQL_253.
Code End
*/
