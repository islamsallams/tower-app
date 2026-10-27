/*
Tower App V2.5.190 - SQL_242.

___________________________
*/
BEGIN;
-- Optional display preferences only. Existing trip ledger/functions are not redefined.
CREATE TABLE IF NOT EXISTS public.tower_trip_alert_preferences_242 (
 unit_id uuid PRIMARY KEY REFERENCES public.tower_units(unit_id) ON DELETE CASCADE,
 alert_amount numeric CHECK (alert_amount IS NULL OR (alert_amount>=1 AND alert_amount<=100000000 AND alert_amount=trunc(alert_amount))),
 alert_days integer CHECK (alert_days IS NULL OR alert_days BETWEEN 1 AND 3650),
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tower_trip_alert_preferences_242 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_trip_alert_preferences_242 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_resident_trip_preferences_242(p_token text,p_action text,p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp AS $fn$
DECLARE
 v_actor public.tower_users;
 v_unit_id uuid;
 v_settings jsonb;
 v_amount numeric;
 v_days integer;
 v_amount_text text;
 v_days_text text;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status<>'ACTIVE' OR v_actor.role<>'RESIDENT' OR v_actor.must_change_pin THEN
  RAISE EXCEPTION 'FORBIDDEN';
 END IF;
 IF p_action IS NULL OR p_action NOT IN ('get','update') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
  RAISE EXCEPTION 'INVALID_OPERATION';
 END IF;
 BEGIN v_unit_id:=nullif(p_payload->>'unitId','')::uuid;
 EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'INVALID_UNIT_ID'; END;
 IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id
  WHERE m.user_id=v_actor.user_id AND m.unit_id=v_unit_id AND m.ended_at IS NULL AND u.status='ACTIVE') THEN
  RAISE EXCEPTION 'UNIT_ACCESS_DENIED';
 END IF;
 IF p_action='update' THEN
  -- Serialize this unit's settings; the original settings function still authorizes the update.
  PERFORM 1 FROM public.tower_units WHERE unit_id=v_unit_id FOR UPDATE;
  SELECT alert_amount,alert_days INTO v_amount,v_days FROM public.tower_trip_alert_preferences_242 WHERE unit_id=v_unit_id;
  IF p_payload ? 'alertAmount' THEN
   v_amount_text:=nullif(btrim(p_payload->>'alertAmount'),'');
   IF v_amount_text IS NULL THEN v_amount:=NULL;
   ELSIF length(v_amount_text)>9 OR v_amount_text !~ '^[0-9]+$' THEN RAISE EXCEPTION 'INVALID_TRIP_ALERT';
   ELSE
    v_amount:=v_amount_text::numeric;
    IF v_amount<1 OR v_amount>100000000 THEN RAISE EXCEPTION 'INVALID_TRIP_ALERT'; END IF;
   END IF;
  END IF;
  IF p_payload ? 'alertDays' THEN
   v_days_text:=nullif(btrim(p_payload->>'alertDays'),'');
   IF v_days_text IS NULL THEN v_days:=NULL;
   ELSIF length(v_days_text)>4 OR v_days_text !~ '^[0-9]+$' THEN RAISE EXCEPTION 'INVALID_TRIP_ALERT';
   ELSE
    v_days:=v_days_text::integer;
    IF v_days<1 OR v_days>3650 THEN RAISE EXCEPTION 'INVALID_TRIP_ALERT'; END IF;
   END IF;
  END IF;
 END IF;
 -- Preserve installed distance validation, permissions, audit, and fee behavior verbatim.
 -- Both parts commit together or both roll back. No trip or settlement data is touched.
 v_settings:=to_jsonb(public.tower_resident_trip_settings(p_token,p_action,p_payload-'alertAmount'-'alertDays'));
 IF p_action='update' THEN
  INSERT INTO public.tower_trip_alert_preferences_242(unit_id,alert_amount,alert_days)
  VALUES(v_unit_id,v_amount,v_days)
  ON CONFLICT(unit_id) DO UPDATE SET alert_amount=EXCLUDED.alert_amount,alert_days=EXCLUDED.alert_days,updated_at=now();
 ELSE
  SELECT alert_amount,alert_days INTO v_amount,v_days FROM public.tower_trip_alert_preferences_242 WHERE unit_id=v_unit_id;
 END IF;
 RETURN coalesce(v_settings,'{}'::jsonb)||jsonb_build_object('alertAmount',v_amount,'alertDays',v_days);
END $fn$;
REVOKE ALL ON FUNCTION public.tower_resident_trip_preferences_242(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_resident_trip_preferences_242(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.190 - SQL_242.

Code End
*/
