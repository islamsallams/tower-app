/*
Tower App V3.0.0 - SQL_251.
___________________________
*/
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_brand_presentation_251(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 desktop_x numeric NOT NULL DEFAULT 50 CHECK(desktop_x BETWEEN 0 AND 100),
 desktop_y numeric NOT NULL DEFAULT 50 CHECK(desktop_y BETWEEN 0 AND 100),
 mobile_x numeric NOT NULL DEFAULT 50 CHECK(mobile_x BETWEEN 0 AND 100),
 mobile_y numeric NOT NULL DEFAULT 50 CHECK(mobile_y BETWEEN 0 AND 100)
);
ALTER TABLE public.tower_brand_presentation_251 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_brand_presentation_251 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tower_brand_presentation_251 TO service_role;
REVOKE INSERT,UPDATE,DELETE ON public.tower_brand_presentation_251 FROM service_role;
CREATE OR REPLACE FUNCTION public.tower_brand_settings_251(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;result jsonb;p public.tower_brand_presentation_251;b jsonb;dx numeric;dy numeric;mx numeric;my numeric;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('get','save') OR p_action IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 IF p_action='save' THEN
  IF jsonb_typeof(p_payload->'branding') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_BRANDING'; END IF;
  b:=p_payload->'branding';
  IF EXISTS(SELECT 1 FROM jsonb_each(b) x WHERE x.key IN ('loginDesktopX','loginDesktopY','loginMobileX','loginMobileY') AND (jsonb_typeof(x.value)<>'number' OR length(x.value::text)>10)) THEN RAISE EXCEPTION 'INVALID_BRAND_FOCUS'; END IF;
  -- Serialize the global presentation alongside the existing settings save.
  PERFORM pg_advisory_xact_lock(71300251);
  SELECT * INTO p FROM public.tower_brand_presentation_251 WHERE singleton;
  dx:=coalesce((b->>'loginDesktopX')::numeric,p.desktop_x,(b->>'heroFocusX')::numeric,50);
  dy:=coalesce((b->>'loginDesktopY')::numeric,p.desktop_y,(b->>'heroFocusY')::numeric,50);
  mx:=coalesce((b->>'loginMobileX')::numeric,p.mobile_x,dx);my:=coalesce((b->>'loginMobileY')::numeric,p.mobile_y,dy);
  IF dx NOT BETWEEN 0 AND 100 OR dy NOT BETWEEN 0 AND 100 OR mx NOT BETWEEN 0 AND 100 OR my NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'INVALID_BRAND_FOCUS'; END IF;
 END IF;
 result:=to_jsonb(public.tower_admin_system_settings(p_token,p_action,p_payload));
 IF p_action='save' THEN
  INSERT INTO public.tower_brand_presentation_251(singleton,desktop_x,desktop_y,mobile_x,mobile_y) VALUES(true,dx,dy,mx,my)
  ON CONFLICT(singleton) DO UPDATE SET desktop_x=EXCLUDED.desktop_x,desktop_y=EXCLUDED.desktop_y,mobile_x=EXCLUDED.mobile_x,mobile_y=EXCLUDED.mobile_y;
 END IF;
 SELECT * INTO p FROM public.tower_brand_presentation_251 WHERE singleton;
 b:=coalesce(result->'branding','{}'::jsonb);
 RETURN result||jsonb_build_object('branding',b||jsonb_build_object('loginDesktopX',coalesce(p.desktop_x,(b->>'heroFocusX')::numeric,50),'loginDesktopY',coalesce(p.desktop_y,(b->>'heroFocusY')::numeric,50),'loginMobileX',coalesce(p.mobile_x,(b->>'heroFocusX')::numeric,50),'loginMobileY',coalesce(p.mobile_y,(b->>'heroFocusY')::numeric,50)));
END $f$;
REVOKE ALL ON FUNCTION public.tower_brand_settings_251(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_brand_settings_251(text,text,jsonb) TO service_role;

-- Scope is derived from the authenticated actor; no client unit, role or recipient is accepted.
CREATE OR REPLACE FUNCTION public.tower_pending_actions_251(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;admin boolean;items jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION','RESIDENT','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 admin:=a.role IN ('ADMIN','UNION');
 WITH managed AS(
  SELECT m.unit_id FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id
  WHERE m.user_id=a.user_id AND m.member_role='MANAGER' AND m.ended_at IS NULL AND u.status='ACTIVE'
 ), responsible AS(
  -- Same ownership conditions as responsible_236, without its FOR UPDATE locks.
  SELECT s.service_id FROM public.tower_services s JOIN public.tower_finance_accounts ac ON ac.service_id=s.service_id
  WHERE ac.beneficiary_user_id=a.user_id AND ac.account_kind='PERSONAL_SERVICE' AND ac.status='ACTIVE'
  AND s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL' AND s.status='ACTIVE'
  AND (SELECT count(*) FROM public.tower_finance_accounts x WHERE x.service_id=s.service_id AND x.account_kind='PERSONAL_SERVICE' AND x.status='ACTIVE')=1
 ), work AS(
  SELECT 'registration' kind,r.unit_id,NULL::uuid service_id FROM public.tower_registration_requests r
  WHERE r.status='PENDING' AND (admin OR (a.role='RESIDENT' AND r.unit_id IN(SELECT unit_id FROM managed) AND coalesce(to_jsonb(r)->>'manager_opinion','') NOT IN ('SUPPORT','OBJECT')))
  UNION ALL
  SELECT 'membership',r.unit_id,NULL::uuid FROM public.tower_member_requests r
  WHERE r.status='PENDING' AND (admin OR (a.role='RESIDENT' AND r.unit_id IN(SELECT unit_id FROM managed) AND coalesce(to_jsonb(r)->>'manager_opinion','') NOT IN ('SUPPORT','OBJECT')))
  UNION ALL
  SELECT 'subscription',sub.unit_id,sub.service_id FROM public.tower_service_subscriptions sub
  JOIN public.tower_services s ON s.service_id=sub.service_id
  LEFT JOIN public.tower_task_projects p ON p.service_id=s.service_id
  WHERE sub.status='PENDING' AND (s.service_kind<>'ONE_TIME' OR coalesce(p.phase,'') NOT IN ('CANCELLED','FINANCIAL_CLOSED'))
  AND (admin OR sub.service_id IN(SELECT service_id FROM responsible))
  UNION ALL
  SELECT 'serviceChange',r.unit_id,r.service_id FROM public.tower_service_change_requests r WHERE r.status='PENDING' AND admin
  UNION ALL
  SELECT 'taskManagement',NULL::uuid,r.service_id FROM public.tower_task_requests_236 r JOIN public.tower_task_projects p ON p.service_id=r.service_id
  WHERE r.state='PENDING' AND admin AND p.phase NOT IN ('CANCELLED','FINANCIAL_CLOSED')
 ), grouped AS(SELECT kind,unit_id,service_id,count(*) count FROM work GROUP BY kind,unit_id,service_id)
 SELECT coalesce(jsonb_agg(jsonb_build_object('kind',g.kind,'unitId',g.unit_id,'serviceId',g.service_id,'count',g.count,'unitNumber',u.unit_number,'serviceName',s.name,'serviceKind',s.service_kind,'pricingMode',s.pricing_mode) ORDER BY g.kind,g.unit_id,g.service_id),'[]'::jsonb)
 INTO items FROM grouped g LEFT JOIN public.tower_units u ON u.unit_id=g.unit_id LEFT JOIN public.tower_services s ON s.service_id=g.service_id;
 RETURN jsonb_build_object('scope','PENDING_ACTIONS','readOnly',true,'items',items);
END $f$;
REVOKE ALL ON FUNCTION public.tower_pending_actions_251(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_pending_actions_251(text) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.0.0 - SQL_251.
Code End
*/
