/*
Tower App V3.8.6 - SQL_268.
___________________________
Trip notification projection only. No trip, tariff, account or settlement engine changes.
*/
BEGIN;
CREATE OR REPLACE FUNCTION tower_push383.notice_text_386(p_value text,p_limit integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $n$
 SELECT left(btrim(regexp_replace(coalesce(p_value,''),'[[:space:][:cntrl:]]+',' ','g')),greatest(0,least(p_limit,500)))
$n$;
CREATE OR REPLACE FUNCTION tower_push383.trip_content_386(p_trip uuid,p_recipient uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $n$
DECLARE result jsonb;names text;cnt integer;sender text;unit_number text;note text;trip_items jsonb;first_name text;person_title text;
BEGIN
 -- This source is operator-only, exactly like SQL257. A manager name is never substituted for the requester.
 IF NOT EXISTS(SELECT 1 FROM public.tower_users a WHERE a.user_id=p_recipient AND a.role='OPERATOR' AND a.status='ACTIVE' AND NOT a.must_change_pin) THEN RETURN NULL;END IF;
 SELECT t.items,tower_push383.notice_text_386(t.notes,100),tower_push383.notice_text_386(u.unit_number,32),
 coalesce(nullif(btrim(p.first_name_261),''),nullif(split_part(btrim(regexp_replace(coalesce(p.name,''),'[[:space:]]+',' ','g')),' ',1),'')),coalesce(nullif(p.custom_title,''),p.title)
 INTO trip_items,note,unit_number,first_name,person_title
 FROM public.tower_trips t JOIN public.tower_units u ON u.unit_id=t.unit_id LEFT JOIN public.tower_users p ON p.user_id=t.created_by
 WHERE t.trip_id=p_trip AND t.status='OPEN' AND t.settlement_id IS NULL AND t.actor_role='RESIDENT';
 IF NOT FOUND THEN RETURN NULL;END IF;
 sender:=CASE WHEN first_name IS NULL THEN 'ساكن' ELSE tower_push383.notice_text_386(concat_ws(' ',CASE WHEN btrim(person_title)='بدون لقب' THEN NULL ELSE coalesce(nullif(btrim(person_title),''),'أ.') END,first_name),70) END;
 WITH entries AS (
  SELECT ord,tower_push383.notice_text_386(x->>'name',45) name FROM jsonb_array_elements(CASE WHEN jsonb_typeof(trip_items)='array' THEN trip_items ELSE '[]'::jsonb END) WITH ORDINALITY AS e(x,ord)
  WHERE jsonb_typeof(x)='object' AND jsonb_typeof(x->'name')='string'
 ), named AS (SELECT row_number() OVER(ORDER BY ord) rn,name FROM entries WHERE name<>'')
 SELECT string_agg(name,'، ' ORDER BY rn) FILTER(WHERE rn<=5),count(*) INTO names,cnt FROM named;
 names:=coalesce(names,'افتح المشوار لعرض الطلب')||CASE WHEN cnt>5 THEN '…' ELSE '' END;
 -- Whitelisted presentation only: never serialize the trip row, distance, fees, totals, settings or item prices.
 result:=jsonb_build_object('title','مشوار من '||sender||' وحدة '||unit_number,
 'body',left(names||CASE WHEN note<>'' THEN E'\nملاحظة: '||note ELSE '' END,500),
 'target',jsonb_build_object('entity','trip','entityId',p_trip));
 RETURN result;
END $n$;
REVOKE ALL ON FUNCTION tower_push383.notice_text_386(text,integer),tower_push383.trip_content_386(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
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
   'title',c.content->>'title','body',c.content->>'body',
   'createdAt',coalesce(t.updated_at,t.created_at),'revision',coalesce(t.updated_at,t.created_at)::text,'source','trip',
   'status',CASE WHEN r.revision=coalesce(t.updated_at,t.created_at)::text THEN 'READ' ELSE 'UNREAD' END) n
  FROM public.tower_trips t JOIN public.tower_units u ON u.unit_id=t.unit_id
  CROSS JOIN LATERAL (SELECT tower_push383.trip_content_386(t.trip_id,actor.user_id) content) c
  LEFT JOIN public.tower_trip_notice_reads_257 r ON r.trip_id=t.trip_id AND r.user_id=actor.user_id
  WHERE t.status='OPEN' AND t.settlement_id IS NULL AND t.actor_role='RESIDENT'
 ) rows;
 RETURN result;
END $f$;

REVOKE ALL ON FUNCTION public.tower_trip_notices_257(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_trip_notices_257(text,text,jsonb) TO service_role;
-- Keep SQL266 claim/lease/retry/permission logic unchanged. This wrapper adds safe presentation to claimed trips only.
CREATE OR REPLACE FUNCTION public.tower_push_queue_386(p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $q$
DECLARE result jsonb;row jsonb;content jsonb;safe_rows jsonb:='[]'::jsonb;trip uuid;
BEGIN
 result:=public.tower_push_queue_383(p_action,p_payload);
 IF p_action<>'claim' THEN RETURN result;END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(result) LOOP
  IF row->>'source'='trip' THEN
   SELECT j.source_id::uuid INTO trip FROM tower_push383.jobs j
    WHERE j.job_id=(row->>'jobId')::uuid AND j.lease_nonce=(row->>'nonce')::uuid AND j.state='SENDING' AND j.source='trip';
   content:=tower_push383.trip_content_386(trip,(row->>'userId')::uuid);
   IF content IS NULL THEN
    PERFORM public.tower_push_queue_383('finish',jsonb_build_object('jobId',row->>'jobId','nonce',row->>'nonce','outcome','failed','code',-18));
    CONTINUE;
   END IF;
   row:=row||content;
  END IF;
  safe_rows:=safe_rows||jsonb_build_array(row);
 END LOOP;
 RETURN safe_rows;
END $q$;
REVOKE ALL ON FUNCTION public.tower_push_queue_386(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_push_queue_386(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.8.6 - SQL_268.
Code End
*/
