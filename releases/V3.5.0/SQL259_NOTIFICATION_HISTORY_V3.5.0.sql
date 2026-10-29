/*
Tower App V3.5.0 - SQL_259.
___________________________
*/
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_notice_history_259(
 user_id uuid NOT NULL REFERENCES public.tower_users(user_id),
 notice_key text NOT NULL,revision text NOT NULL,
 title text NOT NULL,body text NOT NULL DEFAULT '',entity text NOT NULL,entity_id text NOT NULL,unit_id uuid,
 created_at timestamptz NOT NULL,read_at timestamptz,
 PRIMARY KEY(user_id,notice_key)
);
ALTER TABLE public.tower_notice_history_259 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tower_notice_history_259 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_notice_history_259(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;n jsonb;result jsonb;rev text;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IS NULL OR p_action NOT IN('list','read','readAll','readSource') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 IF actor.role='OPERATOR' THEN
  FOR n IN SELECT value FROM jsonb_array_elements(public.tower_trip_notices_257(p_token,'list','{}')) LOOP
   INSERT INTO public.tower_notice_history_259(user_id,notice_key,revision,title,body,entity,entity_id,unit_id,created_at,read_at)
    VALUES(actor.user_id,n->>'notificationId',n->>'revision',n->>'title',n->>'body','trip',n->>'entityId',(n->>'unitId')::uuid,(n->>'createdAt')::timestamptz,CASE WHEN n->>'status'='READ' THEN now() END)
    ON CONFLICT(user_id,notice_key) DO UPDATE SET revision=EXCLUDED.revision,title=EXCLUDED.title,body=EXCLUDED.body,created_at=EXCLUDED.created_at,
     read_at=CASE WHEN tower_notice_history_259.revision=EXCLUDED.revision THEN coalesce(tower_notice_history_259.read_at,EXCLUDED.read_at) ELSE EXCLUDED.read_at END;
  END LOOP;
 END IF;
 IF p_action='read' THEN
  UPDATE public.tower_notice_history_259 SET read_at=coalesce(read_at,now()) WHERE user_id=actor.user_id AND notice_key=p_payload->>'noticeKey' AND revision=p_payload->>'revision';
  IF NOT FOUND THEN RAISE EXCEPTION 'NOTICE_CHANGED';END IF;
 ELSIF p_action='readAll' THEN
  UPDATE public.tower_notice_history_259 SET read_at=coalesce(read_at,now()) WHERE user_id=actor.user_id;
 ELSIF p_action='readSource' THEN
  UPDATE public.tower_notice_history_259 SET read_at=coalesce(read_at,now()) WHERE user_id=actor.user_id AND entity=p_payload->>'entity' AND entity_id=p_payload->>'entityId';
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('notificationId',notice_key,'revision',revision,'title',title,'body',body,'entity',entity,'entityId',entity_id,'unitId',unit_id,'createdAt',created_at,'source','trip','status',CASE WHEN read_at IS NULL THEN 'UNREAD' ELSE 'READ' END) ORDER BY created_at DESC,notice_key),'[]') INTO result FROM public.tower_notice_history_259 WHERE user_id=actor.user_id;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_notice_history_259(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_notice_history_259(text,text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.tower_notifications_259(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $n$
DECLARE actor public.tower_users;rows jsonb;trips jsonb;id text:=p_payload->>'entityId';ent text:=lower(p_payload->>'entity');affected integer;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IS NULL OR p_action NOT IN('list','read','readSource','readAll') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 IF p_action<>'list' THEN
  INSERT INTO public.tower_notification_reads(notification_id,user_id)
  SELECT n.notification_id,actor.user_id FROM public.tower_notifications n WHERE
   (n.user_id=actor.user_id OR (n.user_id IS NULL AND n.unit_id IS NOT NULL AND actor.role='RESIDENT' AND EXISTS(SELECT 1 FROM public.tower_members m WHERE m.unit_id=n.unit_id AND m.user_id=actor.user_id AND m.ended_at IS NULL)) OR (n.user_id IS NULL AND n.unit_id IS NULL AND n.target_role=actor.role))
   AND (p_action='readAll' OR p_action='read' AND n.notification_id::text=p_payload->>'notificationId'
    OR p_action='readSource' AND (lower(n.entity)=ent AND n.entity_id=id OR ent IN('service','task') AND (
      n.entity IN('service','task','task_project') AND n.entity_id=id
      OR n.entity='service_subscription' AND EXISTS(SELECT 1 FROM public.tower_service_subscriptions x WHERE x.subscription_id::text=n.entity_id AND x.service_id::text=id)
      OR n.entity='service_change' AND EXISTS(SELECT 1 FROM public.tower_service_change_requests x WHERE x.request_id::text=n.entity_id AND x.service_id::text=id))))
  ON CONFLICT(notification_id,user_id) DO NOTHING;
  GET DIAGNOSTICS affected=ROW_COUNT;
  IF p_action IN('readSource','readAll') THEN PERFORM public.tower_notice_history_259(p_token,p_action,p_payload);END IF;
  IF p_action='read' AND NOT EXISTS(SELECT 1 FROM public.tower_notification_reads r WHERE r.user_id=actor.user_id AND r.notification_id::text=p_payload->>'notificationId') THEN RAISE EXCEPTION 'NOTIFICATION_NOT_FOUND';END IF;
  RETURN jsonb_build_object('success',true,'readCount',affected);
 END IF;
 trips:=public.tower_notice_history_259(p_token,'list','{}');
 SELECT coalesce(jsonb_agg(jsonb_build_object('notificationId',n.notification_id,'userId',n.user_id,'unitId',n.unit_id,'targetRole',n.target_role,'type',n.type,'title',n.title,'body',n.body,'entity',n.entity,'entityId',n.entity_id,'status',CASE WHEN r.user_id IS NULL THEN 'UNREAD' ELSE 'READ' END,'createdAt',n.created_at,'readAt',r.read_at,
 'serviceId',CASE WHEN n.entity='service_subscription' THEN (SELECT x.service_id FROM public.tower_service_subscriptions x WHERE x.subscription_id::text=n.entity_id) WHEN n.entity='service_change' THEN (SELECT x.service_id FROM public.tower_service_change_requests x WHERE x.request_id::text=n.entity_id) END) ORDER BY n.created_at DESC,n.notification_id DESC),'[]') INTO rows
 FROM public.tower_notifications n LEFT JOIN public.tower_notification_reads r ON r.notification_id=n.notification_id AND r.user_id=actor.user_id
 WHERE n.user_id=actor.user_id OR (n.user_id IS NULL AND n.unit_id IS NOT NULL AND actor.role='RESIDENT' AND EXISTS(SELECT 1 FROM public.tower_members m WHERE m.unit_id=n.unit_id AND m.user_id=actor.user_id AND m.ended_at IS NULL)) OR (n.user_id IS NULL AND n.unit_id IS NULL AND n.target_role=actor.role);
 RETURN jsonb_build_object('scope','NOTIFICATION_CENTER','notifications',rows,'trips',trips,'unavailable','[]'::jsonb,'limited',false);
END $n$;
REVOKE ALL ON FUNCTION public.tower_notifications_259(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_notifications_259(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.5.0 - SQL_259.
Code End
*/
