/* Tower App V3.9.7 - SQL_277_278.
___________________________
Combined installation only; no historical notification replay or financial operation. */
BEGIN;
/* Tower App V3.9.7 - SQL_277.
___________________________
Member rejection decision notice.
   Requires the established notification schema; does not resend historical decisions. */
CREATE OR REPLACE FUNCTION public.tower_member_rejection_notice_277() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $notice$
DECLARE decision jsonb:=to_jsonb(NEW);owner_id uuid;unit_label text;reason text;message text;
BEGIN
 IF OLD.status IS DISTINCT FROM 'PENDING' OR NEW.status IS DISTINCT FROM 'REJECTED' THEN RETURN NEW;END IF;
 owner_id:=NEW.requested_by;
 IF owner_id IS NULL THEN RETURN NEW;END IF;
 IF EXISTS(SELECT 1 FROM public.tower_notifications n WHERE n.user_id=owner_id AND n.entity='member_request' AND n.entity_id=NEW.request_id::text AND n.title='تم رفض طلب إضافة عضو') THEN RETURN NEW;END IF;
 SELECT unit_number INTO unit_label FROM public.tower_units WHERE unit_id=NEW.unit_id;
 reason:=btrim(CASE WHEN decision ? 'decision_notes' THEN coalesce(decision->>'decision_notes','') WHEN decision ? 'review_notes' THEN coalesce(decision->>'review_notes','') ELSE coalesce(decision->>'notes','') END);
 message:='تم رفض طلب إضافة '||left(coalesce(nullif(NEW.candidate_name,''),'العضو'),100)||CASE WHEN unit_label IS NOT NULL THEN ' إلى الوحدة '||left(unit_label,40) ELSE '' END||'.';
 IF reason<>'' THEN message:=message||E'\nسبب الرفض: '||left(reason,300);END IF;
 BEGIN
  INSERT INTO public.tower_notifications(user_id,unit_id,type,title,body,entity,entity_id)
   VALUES(owner_id,NEW.unit_id,'MEMBERSHIP','تم رفض طلب إضافة عضو',message,'member_request',NEW.request_id::text);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO public.tower_notifications(user_id,unit_id,type,title,body,entity,entity_id)
   VALUES(owner_id,NEW.unit_id,'SERVICE','تم رفض طلب إضافة عضو',message,'member_request',NEW.request_id::text);
 END;
 RETURN NEW;
END $notice$;
REVOKE ALL ON FUNCTION public.tower_member_rejection_notice_277() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER IF EXISTS tower_member_rejection_notice_277 ON public.tower_member_requests;
CREATE TRIGGER tower_member_rejection_notice_277 AFTER UPDATE OF status ON public.tower_member_requests FOR EACH ROW EXECUTE FUNCTION public.tower_member_rejection_notice_277();

/*
___________________________
Tower App V3.9.7 - SQL_277.
Code End
*/

/* Tower App V3.9.7 - SQL_278.
___________________________
Welcome prayer configuration only. No financial writes, session replacement, or message delivery.
Stored with existing protected presentation settings to preserve backup/reset table contracts. */
ALTER TABLE public.tower_brand_presentation_251 ADD COLUMN IF NOT EXISTS welcome_prayers_278 jsonb DEFAULT '{"revision":1,"rows":[{"id":"27800000-0000-4000-8000-000000000001","text":"اللهم بارك لنا في بيوتنا وأهلنا.","enabled":true},{"id":"27800000-0000-4000-8000-000000000002","text":"اللهم اجعل بيوتنا عامرة بالمودة والسكينة.","enabled":true},{"id":"27800000-0000-4000-8000-000000000003","text":"اللهم ارزقنا حسن الجوار وطيب العشرة.","enabled":true},{"id":"27800000-0000-4000-8000-000000000004","text":"اللهم احفظ أهلنا وأحبابنا من كل سوء.","enabled":true},{"id":"27800000-0000-4000-8000-000000000005","text":"اللهم ارزقنا راحة القلب وطمأنينة النفس.","enabled":true},{"id":"27800000-0000-4000-8000-000000000006","text":"اللهم اجعل لنا في كل يوم خيرًا وبركة.","enabled":true}]}'::jsonb;
INSERT INTO public.tower_brand_presentation_251(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;
CREATE OR REPLACE FUNCTION public.tower_welcome_prayers_278(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $prayer$
DECLARE actor public.tower_users;state jsonb;rows jsonb;prayer_id uuid;body text;enabled boolean;revision bigint;found_id boolean;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action NOT IN('active','list','save','toggle','delete') OR p_action IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 IF p_action<>'active' AND actor.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IN('save','toggle','delete') THEN
  PERFORM pg_advisory_xact_lock(7391278);
  INSERT INTO public.tower_brand_presentation_251(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;
  SELECT welcome_prayers_278 INTO state FROM public.tower_brand_presentation_251 WHERE singleton FOR UPDATE;
 ELSE SELECT welcome_prayers_278 INTO state FROM public.tower_brand_presentation_251 WHERE singleton;
 END IF;
 state:=coalesce(state,'{"revision":0,"rows":[]}'::jsonb);rows:=coalesce(state->'rows','[]'::jsonb);revision:=coalesce((state->>'revision')::bigint,0);
 IF jsonb_typeof(rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'PRAYER_DATA_INVALID';END IF;
 IF p_action='active' THEN
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',x->>'id','text',x->>'text') ORDER BY ord),'[]'::jsonb) FROM jsonb_array_elements(rows) WITH ORDINALITY r(x,ord) WHERE x->>'enabled'='true');
 END IF;
 IF p_action='list' THEN RETURN jsonb_build_object('revision',revision,'rows',rows);END IF;
 IF p_payload->>'revision' IS DISTINCT FROM revision::text THEN RAISE EXCEPTION 'PRAYER_CHANGED';END IF;
 prayer_id:=(p_payload->>'id')::uuid;
 IF prayer_id IS NULL THEN RAISE EXCEPTION 'PRAYER_REQUIRED';END IF;
 found_id:=EXISTS(SELECT 1 FROM jsonb_array_elements(rows)x WHERE x->>'id'=prayer_id::text);
 IF p_action IN('toggle','delete') AND NOT found_id THEN RAISE EXCEPTION 'PRAYER_NOT_FOUND';END IF;
 IF p_action='save' THEN
  body:=btrim(p_payload->>'text');
  IF body IS NULL OR length(body) NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'INVALID_PRAYER_TEXT';END IF;
  IF jsonb_typeof(p_payload->'enabled') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_PRAYER_STATE';END IF;
  enabled:=(p_payload->>'enabled')::boolean;
  IF NOT found_id AND jsonb_array_length(rows)>=100 THEN RAISE EXCEPTION 'PRAYER_LIMIT_REACHED';END IF;
 ELSIF p_action='toggle' THEN
  IF jsonb_typeof(p_payload->'enabled') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_PRAYER_STATE';END IF;
  enabled:=(p_payload->>'enabled')::boolean;
 END IF;
 IF p_action='delete' THEN
  SELECT coalesce(jsonb_agg(x ORDER BY ord),'[]'::jsonb) INTO rows FROM jsonb_array_elements(rows) WITH ORDINALITY r(x,ord) WHERE x->>'id'<>prayer_id::text;
 ELSIF found_id THEN
  SELECT jsonb_agg(CASE WHEN x->>'id'=prayer_id::text THEN x||jsonb_build_object('enabled',enabled)||CASE WHEN p_action='save' THEN jsonb_build_object('text',body) ELSE '{}'::jsonb END ELSE x END ORDER BY ord) INTO rows FROM jsonb_array_elements(rows) WITH ORDINALITY r(x,ord);
 ELSE rows:=rows||jsonb_build_array(jsonb_build_object('id',prayer_id,'text',body,'enabled',enabled));
 END IF;
 UPDATE public.tower_brand_presentation_251 SET welcome_prayers_278=jsonb_build_object('revision',revision+1,'rows',rows) WHERE singleton;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'WELCOME_PRAYER_'||upper(p_action),'SYSTEM_SETTINGS',prayer_id::text);
 RETURN jsonb_build_object('success',true,'revision',revision+1,'rows',rows);
END $prayer$;
REVOKE ALL ON FUNCTION public.tower_welcome_prayers_278(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_welcome_prayers_278(text,text,jsonb) TO service_role;
/*
___________________________
Tower App V3.9.7 - SQL_278.
Code End
*/

NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.9.7 - SQL_277_278.
Code End
*/
