/*
Tower App V3.4.0 - SQL_257.
___________________________
*/
BEGIN;
-- Read acknowledgements only. No triggers or changes to the trip/accounting engine.
CREATE TABLE IF NOT EXISTS public.tower_trip_notice_reads_257(
 user_id uuid NOT NULL REFERENCES public.tower_users(user_id),
 trip_id uuid NOT NULL REFERENCES public.tower_trips(trip_id),
 revision text NOT NULL,
 read_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,trip_id)
);
ALTER TABLE public.tower_trip_notice_reads_257 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_trip_notice_reads_257 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_trip_notices_257(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;result jsonb;trip public.tower_trips;rev text;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role<>'OPERATOR' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action IS NULL OR p_action NOT IN('list','read') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION'; END IF;
 IF p_action='read' THEN
  SELECT * INTO trip FROM public.tower_trips WHERE trip_id=(p_payload->>'tripId')::uuid AND status='OPEN' AND settlement_id IS NULL AND actor_role='RESIDENT' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_AVAILABLE'; END IF;
  rev:=coalesce(trip.updated_at,trip.created_at)::text;
  IF p_payload->>'revision' IS DISTINCT FROM rev THEN RAISE EXCEPTION 'NOTICE_CHANGED'; END IF;
  INSERT INTO public.tower_trip_notice_reads_257(user_id,trip_id,revision) VALUES(actor.user_id,trip.trip_id,rev)
   ON CONFLICT(user_id,trip_id) DO UPDATE SET revision=EXCLUDED.revision,read_at=now();
  RETURN jsonb_build_object('success',true);
 END IF;
 SELECT coalesce(jsonb_agg(n ORDER BY n->>'createdAt' DESC,n->>'entityId'),'[]') INTO result FROM (
  SELECT jsonb_build_object('notificationId','trip:'||t.trip_id::text,'entity','trip','entityId',t.trip_id,'unitId',t.unit_id,
   'title','مشوار من الساكن','body','وحدة '||u.unit_number::text||' · مشوار مفتوح',
   'createdAt',coalesce(t.updated_at,t.created_at),'revision',coalesce(t.updated_at,t.created_at)::text,'source','trip',
   'status',CASE WHEN r.revision=coalesce(t.updated_at,t.created_at)::text THEN 'READ' ELSE 'UNREAD' END) n
  FROM public.tower_trips t JOIN public.tower_units u ON u.unit_id=t.unit_id
  LEFT JOIN public.tower_trip_notice_reads_257 r ON r.trip_id=t.trip_id AND r.user_id=actor.user_id
  WHERE t.status='OPEN' AND t.settlement_id IS NULL AND t.actor_role='RESIDENT'
 ) rows;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_trip_notices_257(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_trip_notices_257(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.4.0 - SQL_257.
Code End
*/
