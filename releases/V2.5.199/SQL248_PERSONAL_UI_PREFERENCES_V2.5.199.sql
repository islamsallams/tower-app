/*
Tower App V2.5.199 - SQL_248.
___________________________
*/
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_personal_ui_preferences_248 (
 user_id uuid PRIMARY KEY REFERENCES public.tower_users(user_id) ON DELETE CASCADE,
 desktop text NOT NULL DEFAULT 'default' CHECK(desktop IN ('small','default','large','larger')),
 mobile text NOT NULL DEFAULT 'default' CHECK(mobile IN ('small','default','large','larger')),
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_personal_ui_preferences_248 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_personal_ui_preferences_248 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_personal_ui_preferences_248(p_token text,p_action text,p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp AS $fn$
DECLARE
 v_actor public.tower_users;
 v_desktop text;
 v_mobile text;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.must_change_pin OR v_actor.role NOT IN ('ADMIN','UNION','RESIDENT','OPERATOR') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('get','save') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 IF p_action='save' THEN
  v_desktop:=p_payload->>'desktop';v_mobile:=p_payload->>'mobile';
  IF v_desktop IS NULL OR v_mobile IS NULL OR v_desktop NOT IN ('small','default','large','larger') OR v_mobile NOT IN ('small','default','large','larger') THEN RAISE EXCEPTION 'INVALID_UI_PREFERENCE'; END IF;
  INSERT INTO public.tower_personal_ui_preferences_248(user_id,desktop,mobile) VALUES(v_actor.user_id,v_desktop,v_mobile)
  ON CONFLICT(user_id) DO UPDATE SET desktop=EXCLUDED.desktop,mobile=EXCLUDED.mobile,updated_at=now();
 END IF;
 SELECT desktop,mobile INTO v_desktop,v_mobile FROM public.tower_personal_ui_preferences_248 WHERE user_id=v_actor.user_id;
 RETURN jsonb_build_object('desktop',coalesce(v_desktop,'default'),'mobile',coalesce(v_mobile,'default'));
END $fn$;
REVOKE ALL ON FUNCTION public.tower_personal_ui_preferences_248(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_personal_ui_preferences_248(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V2.5.199 - SQL_248.
Code End
*/
