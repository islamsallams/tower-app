/*
Tower App V3.9.0 - SQL_269.
___________________________
Android notification delivery only; no trip, account, tariff or settlement engine changes.
*/
BEGIN;
DO $check$ BEGIN
 IF to_regprocedure('tower_push383.trip_content_386(uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'TRIP_NOTIFICATION_CONTENT_REQUIRED';END IF;
END $check$;
CREATE SCHEMA IF NOT EXISTS tower_android390;
REVOKE ALL ON SCHEMA tower_android390 FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE IF NOT EXISTS tower_android390.devices(
 installation_id uuid PRIMARY KEY,user_id uuid NOT NULL,fcm_token text NOT NULL UNIQUE,secret_hash text NOT NULL,credential_version integer NOT NULL,
 enabled boolean NOT NULL DEFAULT true,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS tower_android390.jobs(
 job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),installation_id uuid NOT NULL REFERENCES tower_android390.devices ON DELETE CASCADE,
 source text NOT NULL,source_id text NOT NULL,revision text NOT NULL DEFAULT '',state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','SENDING','SENT','FAILED','CANCELLED')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),nonce uuid,lease_until timestamptz,next_attempt_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),last_code integer,
 UNIQUE(installation_id,source,source_id,revision));
ALTER TABLE tower_android390.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE tower_android390.jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA tower_android390 FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX IF NOT EXISTS tower_android_user_390 ON tower_android390.devices(user_id);
CREATE INDEX IF NOT EXISTS tower_android_queue_390 ON tower_android390.jobs(state,next_attempt_at);
CREATE OR REPLACE FUNCTION tower_android390.allowed(p_install uuid,p_source text,p_id text) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $f$
 SELECT coalesce((SELECT tower_push383.allowed(d.user_id,p_source,p_id) FROM tower_android390.devices d JOIN public.tower_users u ON u.user_id=d.user_id
 WHERE d.installation_id=p_install AND d.enabled AND u.credential_version=d.credential_version),false)
$f$;
CREATE OR REPLACE FUNCTION tower_android390.enqueue() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE source_value text;key_value text;rev_value text:='';v jsonb:=to_jsonb(NEW);state_value text;
BEGIN
 IF TG_ARGV[0]='notification' THEN source_value:='notification';key_value:=v->>'notification_id';
 ELSIF TG_ARGV[0]='trip' THEN
  IF NEW.status<>'OPEN' OR NEW.settlement_id IS NOT NULL OR NEW.actor_role<>'RESIDENT' THEN RETURN NEW;END IF;
  IF TG_OP='UPDATE' AND to_jsonb(OLD) IS NOT DISTINCT FROM v THEN RETURN NEW;END IF;
  source_value:='trip';key_value:=NEW.trip_id::text;rev_value:=coalesce(NEW.updated_at,NEW.created_at)::text;
 ELSE
  source_value:=TG_ARGV[0];state_value:=coalesce(v->>'status',v->>'state');
  IF state_value NOT IN('PENDING','PENDING_APPROVAL') OR state_value IS NULL THEN RETURN NEW;END IF;
  IF TG_OP='UPDATE' AND coalesce(to_jsonb(OLD)->>'status',to_jsonb(OLD)->>'state') IS NOT DISTINCT FROM state_value THEN RETURN NEW;END IF;
  key_value:=coalesce(v->>'request_id',v->>'subscription_id',v->>'report_id',v->>'reset_id',v->>'reference');rev_value:=now()::text;
 END IF;
 IF key_value IS NULL THEN RETURN NEW;END IF;
 INSERT INTO tower_android390.jobs(installation_id,source,source_id,revision)
 SELECT d.installation_id,source_value,key_value,rev_value FROM tower_android390.devices d
 WHERE d.enabled AND tower_android390.allowed(d.installation_id,source_value,key_value)
 ON CONFLICT(installation_id,source,source_id,revision) DO NOTHING;
 RETURN NEW;
END $f$;
DO $triggers$
DECLARE t text;s text;
BEGIN
 FOR t,s IN SELECT * FROM (VALUES ('tower_notifications','notification'),('tower_trips','trip'),('tower_registration_requests','registration'),('tower_member_requests','membership'),('tower_service_subscriptions','subscription'),('tower_service_change_requests','serviceChange'),('tower_task_requests_236','taskManagement'),('tower_pin_reset_requests','pin'),('tower_collection_reports','collections')) AS x(t,s) LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS tower_android_notice_390 ON public.%I',t);
  EXECUTE format('CREATE TRIGGER tower_android_notice_390 AFTER INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION tower_android390.enqueue(%L)',t,s);
 END LOOP;
END $triggers$;
CREATE OR REPLACE FUNCTION public.tower_android_device_390(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users;installation uuid;secret text;token_value text;hash_value text;last_job jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IS NULL OR p_action NOT IN('status','subscribe','unsubscribe','test') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 installation:=(p_payload->>'installationId')::uuid;secret:=p_payload->>'secret';
 IF installation IS NULL OR secret IS NULL OR secret !~ '^[a-fA-F0-9-]{64,128}$' THEN RAISE EXCEPTION 'INVALID_ANDROID_DEVICE';END IF;
 hash_value:=encode(sha256(convert_to(secret,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(7391390);
 IF p_action='subscribe' THEN
  token_value:=p_payload->>'fcmToken';
  IF token_value IS NULL OR length(token_value) NOT BETWEEN 20 AND 4096 OR token_value !~ '^[A-Za-z0-9_:.-]+$' THEN RAISE EXCEPTION 'INVALID_ANDROID_TOKEN';END IF;
  IF EXISTS(SELECT 1 FROM tower_android390.devices d WHERE (d.installation_id=installation OR d.fcm_token=token_value) AND d.secret_hash<>hash_value) THEN RAISE EXCEPTION 'ANDROID_DEVICE_IN_USE';END IF;
  DELETE FROM tower_android390.devices WHERE installation_id=installation OR fcm_token=token_value;
  IF (SELECT count(*) FROM tower_android390.devices WHERE user_id=actor.user_id)>=10 THEN RAISE EXCEPTION 'PUSH_DEVICE_LIMIT';END IF;
  INSERT INTO tower_android390.devices(installation_id,user_id,fcm_token,secret_hash,credential_version) VALUES(installation,actor.user_id,token_value,hash_value,actor.credential_version);
 ELSIF p_action='unsubscribe' THEN
  DELETE FROM tower_android390.devices WHERE installation_id=installation AND user_id=actor.user_id AND secret_hash=hash_value;
 ELSIF p_action='test' THEN
  IF NOT EXISTS(SELECT 1 FROM tower_android390.devices WHERE installation_id=installation AND user_id=actor.user_id AND secret_hash=hash_value AND credential_version=actor.credential_version AND enabled) THEN RAISE EXCEPTION 'PUSH_DEVICE_REQUIRED';END IF;
  IF EXISTS(SELECT 1 FROM tower_android390.jobs WHERE installation_id=installation AND source='test' AND created_at>now()-interval '1 minute') THEN RAISE EXCEPTION 'PUSH_TEST_COOLDOWN';END IF;
  INSERT INTO tower_android390.jobs(installation_id,source,source_id) VALUES(installation,'test',gen_random_uuid()::text);
 END IF;
 SELECT jsonb_build_object('state',j.state,'attempts',j.attempts,'code',j.last_code,'at',j.updated_at) INTO last_job
 FROM tower_android390.jobs j JOIN tower_android390.devices d USING(installation_id)
 WHERE j.installation_id=installation AND d.user_id=actor.user_id AND d.secret_hash=hash_value ORDER BY j.created_at DESC,j.job_id DESC LIMIT 1;
 RETURN jsonb_build_object('userId',actor.user_id,'enabled',EXISTS(SELECT 1 FROM tower_android390.devices WHERE installation_id=installation AND user_id=actor.user_id AND secret_hash=hash_value AND credential_version=actor.credential_version AND enabled),'lastDelivery',last_job);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_android_queue_390(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE result jsonb:='[]'::jsonb;j tower_android390.jobs;r record;content jsonb;
BEGIN
 IF p_action='claim' THEN
  UPDATE tower_android390.jobs x SET state='CANCELLED',updated_at=now() FROM tower_android390.devices d
   WHERE x.installation_id=d.installation_id AND x.state IN('PENDING','SENDING') AND (x.created_at<now()-interval '1 day' OR NOT d.enabled OR NOT tower_android390.allowed(d.installation_id,x.source,x.source_id));
  UPDATE tower_android390.jobs SET state='FAILED',updated_at=now() WHERE state='SENDING' AND attempts>=5 AND lease_until<now();
  FOR r IN WITH selected AS (
   SELECT x.job_id FROM tower_android390.jobs x JOIN tower_android390.devices d USING(installation_id)
   WHERE x.attempts<5 AND x.created_at>=now()-interval '1 day' AND d.enabled AND tower_android390.allowed(d.installation_id,x.source,x.source_id)
    AND (x.state='PENDING' AND x.next_attempt_at<=now() OR x.state='SENDING' AND x.lease_until<now())
   ORDER BY x.created_at,x.job_id FOR UPDATE OF x SKIP LOCKED LIMIT 4
  ), leased AS (
   UPDATE tower_android390.jobs x SET state='SENDING',attempts=x.attempts+1,nonce=gen_random_uuid(),lease_until=now()+interval '2 minutes',updated_at=now() FROM selected s WHERE s.job_id=x.job_id RETURNING x.*
  ) SELECT x.*,d.user_id,d.fcm_token FROM leased x JOIN tower_android390.devices d USING(installation_id)
  LOOP
   IF r.source='trip' THEN content:=tower_push383.trip_content_386(r.source_id::uuid,r.user_id);
   ELSIF r.source='notification' THEN SELECT jsonb_build_object('title',n.title,'body',n.body) INTO content FROM public.tower_notifications n WHERE n.notification_id::text=r.source_id;
   ELSE content:=jsonb_build_object('title',CASE r.source WHEN 'test' THEN 'تجربة إشعارات التطبيق' WHEN 'registration' THEN 'طلب تسجيل جديد' WHEN 'membership' THEN 'طلب عضوية جديد' WHEN 'subscription' THEN 'طلب اشتراك جديد' WHEN 'serviceChange' THEN 'طلب تعديل اشتراك' WHEN 'taskManagement' THEN 'طلب إدارة مهمة' WHEN 'pin' THEN 'طلب استرجاع PIN' ELSE 'تحصيل ينتظر الاعتماد' END,'body',CASE WHEN r.source='test' THEN 'إشعار تجريبي لهذا التطبيق فقط.' ELSE 'عندك طلب جديد يحتاج مراجعتك داخل التطبيق.' END);END IF;
   IF content IS NULL THEN UPDATE tower_android390.jobs SET state='CANCELLED',updated_at=now() WHERE job_id=r.job_id;CONTINUE;END IF;
   result:=result||jsonb_build_array(content||jsonb_build_object('jobId',r.job_id,'nonce',r.nonce,'userId',r.user_id,'fcmToken',r.fcm_token));
  END LOOP;
  RETURN result;
 END IF;
 IF p_action IS NULL OR p_action NOT IN('validate','finish') THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 SELECT * INTO j FROM tower_android390.jobs WHERE job_id=(p_payload->>'jobId')::uuid AND nonce=(p_payload->>'nonce')::uuid AND state='SENDING' FOR UPDATE;
 IF NOT FOUND THEN RETURN 'false';END IF;
 IF p_action='validate' THEN RETURN to_jsonb(j.lease_until>now() AND EXISTS(SELECT 1 FROM tower_android390.devices d WHERE d.installation_id=j.installation_id AND d.enabled AND tower_android390.allowed(d.installation_id,j.source,j.source_id)));END IF;
 IF p_payload->>'outcome'='expired' THEN DELETE FROM tower_android390.devices WHERE installation_id=j.installation_id;
 ELSE UPDATE tower_android390.jobs SET state=CASE WHEN p_payload->>'outcome'='sent' THEN 'SENT' WHEN attempts>=5 OR p_payload->>'outcome'='failed' THEN 'FAILED' ELSE 'PENDING' END,
 next_attempt_at=now()+make_interval(secs=>least(1800,60*(2^attempts)::int)),lease_until=NULL,last_code=(p_payload->>'code')::integer,updated_at=now() WHERE job_id=j.job_id;END IF;
 DELETE FROM tower_android390.jobs WHERE state IN('SENT','FAILED','CANCELLED') AND created_at<now()-interval '7 days';RETURN 'true';
END $f$;
CREATE OR REPLACE FUNCTION tower_android390.pause_restore() RETURNS void LANGUAGE sql SET search_path=pg_catalog AS $f$ DELETE FROM tower_android390.devices $f$;
DO $restore$
DECLARE body text;definition text;
BEGIN
 SELECT p.prosrc,pg_get_functiondef(p.oid) INTO body,definition FROM pg_proc p WHERE p.oid=to_regprocedure('tower_restore265.apply(jsonb,jsonb)');
 IF body IS NULL THEN RAISE EXCEPTION 'RESTORE_HELPER_REQUIRED';END IF;
 IF position('PERFORM tower_android390.pause_restore();' in body)=0 THEN
  body:=regexp_replace(body,'\mBEGIN\M',E'BEGIN\n PERFORM tower_android390.pause_restore();','i');
  EXECUTE replace(definition,(SELECT prosrc FROM pg_proc WHERE oid=to_regprocedure('tower_restore265.apply(jsonb,jsonb)')),body);
 END IF;
END $restore$;
-- Optional bounded Web Push claim keeps both transports below the free Worker subrequest budget.
DO $budget$
DECLARE body text;definition text;old_text text:='FOR UPDATE OF x SKIP LOCKED LIMIT 12';new_text text:=$limit$FOR UPDATE OF x SKIP LOCKED LIMIT least(12,greatest(1,coalesce((p_payload->>'limit')::integer,12)))$limit$;
BEGIN
 SELECT p.prosrc,pg_get_functiondef(p.oid) INTO body,definition FROM pg_proc p WHERE p.oid=to_regprocedure('public.tower_push_queue_383(text,jsonb)');
 IF body IS NULL THEN RAISE EXCEPTION 'WEB_PUSH_QUEUE_REQUIRED';END IF;
 IF position(new_text in body)=0 THEN
  IF position(old_text in body)=0 THEN RAISE EXCEPTION 'WEB_PUSH_QUEUE_SHAPE_CHANGED';END IF;
  EXECUTE replace(definition,body,replace(body,old_text,new_text));
 END IF;
END $budget$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tower_android390 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_android_device_390(text,text,jsonb),public.tower_android_queue_390(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_android_device_390(text,text,jsonb),public.tower_android_queue_390(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.9.0 - SQL_269.
Code End
*/
