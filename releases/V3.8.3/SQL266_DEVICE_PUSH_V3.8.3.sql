/*
Tower App V3.8.3 - SQL_266.
___________________________
*/
BEGIN;
CREATE SCHEMA IF NOT EXISTS tower_push383;
REVOKE ALL ON SCHEMA tower_push383 FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE IF NOT EXISTS tower_push383.config(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),public_key text NOT NULL,private_jwk jsonb NOT NULL,
 origin text NOT NULL,paused boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS tower_push383.devices(
 device_id uuid PRIMARY KEY,user_id uuid NOT NULL,endpoint text NOT NULL,endpoint_hash text NOT NULL UNIQUE,
 p256dh text NOT NULL,auth text NOT NULL,enabled boolean NOT NULL DEFAULT true,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS tower_push383.jobs(
 job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),device_id uuid NOT NULL REFERENCES tower_push383.devices(device_id) ON DELETE CASCADE,
 source text NOT NULL,source_id text NOT NULL,revision text NOT NULL DEFAULT '',state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','SENDING','SENT','FAILED','CANCELLED')),
 attempts int NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),lease_nonce uuid,lease_until timestamptz,
 next_attempt_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),last_code int,
 UNIQUE(device_id,source,source_id,revision));
CREATE INDEX IF NOT EXISTS tower_push_device_user_383 ON tower_push383.devices(user_id);
CREATE INDEX IF NOT EXISTS tower_push_job_ready_383 ON tower_push383.jobs(state,next_attempt_at);
CREATE INDEX IF NOT EXISTS tower_push_job_device_383 ON tower_push383.jobs(device_id,created_at DESC);
-- Runtime device state deliberately has no inbound FK to public application tables.
-- Restore can revoke it atomically without changing SQL263's backup table set or fingerprint.
ALTER TABLE tower_push383.config ENABLE ROW LEVEL SECURITY;
ALTER TABLE tower_push383.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE tower_push383.jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA tower_push383 FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tower_push383.pending_allowed(p_user uuid,p_source text,p_id text) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $f$
 WITH actor AS(SELECT * FROM public.tower_users WHERE user_id=p_user AND status='ACTIVE' AND NOT must_change_pin),
 managed AS(SELECT m.unit_id FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE' WHERE m.user_id=p_user AND m.member_role='MANAGER' AND m.ended_at IS NULL),
 responsible AS(SELECT s.service_id FROM public.tower_services s JOIN public.tower_finance_accounts ac ON ac.service_id=s.service_id WHERE ac.beneficiary_user_id=p_user AND ac.account_kind='PERSONAL_SERVICE' AND ac.status='ACTIVE' AND s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL' AND s.status='ACTIVE' AND (SELECT count(*) FROM public.tower_finance_accounts x WHERE x.service_id=s.service_id AND x.account_kind='PERSONAL_SERVICE' AND x.status='ACTIVE')=1)
 SELECT EXISTS(SELECT 1 FROM actor a WHERE
 p_source='registration' AND EXISTS(SELECT 1 FROM public.tower_registration_requests r WHERE r.request_id::text=p_id AND r.status='PENDING' AND (a.role IN('ADMIN','UNION') OR a.role='RESIDENT' AND r.unit_id IN(SELECT unit_id FROM managed) AND coalesce(to_jsonb(r)->>'manager_opinion','') NOT IN('SUPPORT','OBJECT'))) OR
 p_source='membership' AND EXISTS(SELECT 1 FROM public.tower_member_requests r WHERE r.request_id::text=p_id AND r.status='PENDING' AND (a.role IN('ADMIN','UNION') OR a.role='RESIDENT' AND r.unit_id IN(SELECT unit_id FROM managed) AND coalesce(to_jsonb(r)->>'manager_opinion','') NOT IN('SUPPORT','OBJECT'))) OR
 p_source='subscription' AND EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub JOIN public.tower_services s ON s.service_id=sub.service_id LEFT JOIN public.tower_task_projects pr ON pr.service_id=s.service_id WHERE sub.subscription_id::text=p_id AND sub.status='PENDING' AND (s.service_kind<>'ONE_TIME' OR coalesce(pr.phase,'') NOT IN('CANCELLED','FINANCIAL_CLOSED')) AND (a.role IN('ADMIN','UNION') OR sub.service_id IN(SELECT service_id FROM responsible))) OR
 p_source='serviceChange' AND a.role IN('ADMIN','UNION') AND EXISTS(SELECT 1 FROM public.tower_service_change_requests r WHERE r.request_id::text=p_id AND r.status='PENDING') OR
 p_source='taskManagement' AND a.role IN('ADMIN','UNION') AND EXISTS(SELECT 1 FROM public.tower_task_requests_236 r JOIN public.tower_task_projects pr ON pr.service_id=r.service_id WHERE coalesce(to_jsonb(r)->>'request_id',to_jsonb(r)->>'reference')=p_id AND r.state='PENDING' AND pr.phase NOT IN('CANCELLED','FINANCIAL_CLOSED')) OR
 p_source='pin' AND a.role IN('ADMIN','UNION') AND EXISTS(SELECT 1 FROM public.tower_pin_reset_requests r WHERE coalesce(to_jsonb(r)->>'request_id',to_jsonb(r)->>'reset_id')=p_id AND r.status='PENDING') OR
 p_source='collections' AND a.role IN('ADMIN','UNION') AND EXISTS(SELECT 1 FROM public.tower_collection_reports r WHERE r.report_id::text=p_id AND r.status='PENDING_APPROVAL'))
$f$;
CREATE OR REPLACE FUNCTION tower_push383.pending_enqueue() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE js jsonb:=to_jsonb(NEW);old_state text;new_state text;expected text;key text;
BEGIN
 IF coalesce((SELECT paused FROM tower_push383.config WHERE singleton),true) THEN RETURN NEW;END IF;
 expected:=CASE WHEN TG_ARGV[0]='collections' THEN 'PENDING_APPROVAL' ELSE 'PENDING' END;new_state:=coalesce(js->>'status',js->>'state');
 IF new_state IS DISTINCT FROM expected THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' THEN old_state:=coalesce(to_jsonb(OLD)->>'status',to_jsonb(OLD)->>'state');IF old_state=expected THEN RETURN NEW;END IF;END IF;
 key:=coalesce(js->>'request_id',js->>'subscription_id',js->>'report_id',js->>'reset_id',js->>'reference');IF key IS NULL THEN RETURN NEW;END IF;
 INSERT INTO tower_push383.jobs(device_id,source,source_id,revision)
 SELECT d.device_id,TG_ARGV[0],key,now()::text FROM tower_push383.devices d WHERE d.enabled AND tower_push383.pending_allowed(d.user_id,TG_ARGV[0],key)
 ON CONFLICT(device_id,source,source_id,revision) DO NOTHING;
 RETURN NEW;
END $f$;
DO $triggers$
DECLARE item record;
BEGIN
 FOR item IN SELECT * FROM (VALUES('tower_registration_requests','registration'),('tower_member_requests','membership'),('tower_service_subscriptions','subscription'),('tower_service_change_requests','serviceChange'),('tower_task_requests_236','taskManagement'),('tower_pin_reset_requests','pin'),('tower_collection_reports','collections')) AS v(tab,source) LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS tower_pending_push_383 ON public.%I',item.tab);
  EXECUTE format('CREATE TRIGGER tower_pending_push_383 AFTER INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION tower_push383.pending_enqueue(%L)',item.tab,item.source);
 END LOOP;
END $triggers$;

CREATE OR REPLACE FUNCTION tower_push383.allowed(p_user uuid,p_source text,p_id text) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $f$
 SELECT EXISTS(SELECT 1 FROM public.tower_users u WHERE u.user_id=p_user AND u.status='ACTIVE' AND NOT u.must_change_pin AND (
 p_source='test' OR tower_push383.pending_allowed(p_user,p_source,p_id) OR
 p_source='notification' AND EXISTS(SELECT 1 FROM public.tower_notifications n WHERE n.notification_id::text=p_id AND NOT EXISTS(SELECT 1 FROM public.tower_notification_reads nr WHERE nr.notification_id=n.notification_id AND nr.user_id=u.user_id) AND NOT(u.role='OPERATOR' AND lower(coalesce(n.entity,''))='trip' AND EXISTS(SELECT 1 FROM public.tower_trips dt WHERE dt.trip_id::text=n.entity_id AND dt.status='OPEN' AND dt.settlement_id IS NULL AND dt.actor_role='RESIDENT')) AND
  (n.user_id=u.user_id OR n.user_id IS NULL AND n.unit_id IS NOT NULL AND u.role='RESIDENT' AND EXISTS(SELECT 1 FROM public.tower_members m WHERE m.user_id=u.user_id AND m.unit_id=n.unit_id AND m.ended_at IS NULL)
  OR n.user_id IS NULL AND n.unit_id IS NULL AND n.target_role=u.role)) OR
 p_source='trip' AND u.role='OPERATOR' AND EXISTS(SELECT 1 FROM public.tower_trips t WHERE t.trip_id::text=p_id AND t.status='OPEN' AND t.settlement_id IS NULL AND t.actor_role='RESIDENT' AND NOT EXISTS(SELECT 1 FROM public.tower_trip_notice_reads_257 tr WHERE tr.user_id=u.user_id AND tr.trip_id=t.trip_id AND tr.revision=coalesce(t.updated_at,t.created_at)::text))))
$f$;
CREATE OR REPLACE FUNCTION tower_push383.enqueue() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE v_source text;v_key text;v_rev text:='';
BEGIN
 IF coalesce((SELECT paused FROM tower_push383.config WHERE singleton),true) THEN RETURN NEW;END IF;
 IF TG_TABLE_NAME='tower_notifications' THEN v_source:='notification';v_key:=NEW.notification_id::text;
 ELSE
  IF NEW.status<>'OPEN' OR NEW.settlement_id IS NOT NULL OR NEW.actor_role<>'RESIDENT' THEN RETURN NEW;END IF;
  IF TG_OP='UPDATE' AND to_jsonb(OLD) IS NOT DISTINCT FROM to_jsonb(NEW) THEN RETURN NEW;END IF;
  v_source:='trip';v_key:=NEW.trip_id::text;v_rev:=coalesce(NEW.updated_at,NEW.created_at)::text;
 END IF;
 INSERT INTO tower_push383.jobs(device_id,source,source_id,revision)
 SELECT d.device_id,v_source,v_key,v_rev FROM tower_push383.devices d
 WHERE d.enabled AND tower_push383.allowed(d.user_id,v_source,v_key)
 ON CONFLICT(device_id,source,source_id,revision) DO NOTHING;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_device_push_383 ON public.tower_notifications;
CREATE TRIGGER tower_device_push_383 AFTER INSERT ON public.tower_notifications FOR EACH ROW EXECUTE FUNCTION tower_push383.enqueue();
DROP TRIGGER IF EXISTS tower_trip_push_383 ON public.tower_trips;
CREATE TRIGGER tower_trip_push_383 AFTER INSERT OR UPDATE ON public.tower_trips FOR EACH ROW EXECUTE FUNCTION tower_push383.enqueue();

CREATE OR REPLACE FUNCTION public.tower_push_keys_383(p_config jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE c tower_push383.config;
BEGIN
 PERFORM pg_advisory_xact_lock(73912383);
 SELECT * INTO c FROM tower_push383.config WHERE singleton;
 IF NOT FOUND AND p_config IS NOT NULL THEN
  IF length(p_config->>'publicKey')<>87 OR p_config->>'origin' !~ '^https://[^/[:space:]]+$' OR jsonb_typeof(p_config->'privateJwk')<>'object' THEN RAISE EXCEPTION 'INVALID_PUSH_CONFIG';END IF;
  INSERT INTO tower_push383.config(public_key,private_jwk,origin) VALUES(p_config->>'publicKey',p_config->'privateJwk',p_config->>'origin') RETURNING * INTO c;
 END IF;
 IF c.public_key IS NULL THEN RETURN NULL;END IF;
 RETURN jsonb_build_object('publicKey',c.public_key,'privateJwk',c.private_jwk,'origin',c.origin,'paused',c.paused);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_push_device_383(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users;dev uuid;ep text;sub jsonb;last_job jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status IS DISTINCT FROM 'ACTIVE' OR a.must_change_pin IS DISTINCT FROM false THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF p_action NOT IN('status','subscribe','unsubscribe','test') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 dev:=(p_payload->>'deviceId')::uuid;IF dev IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE';END IF;
 IF p_action='subscribe' THEN
  PERFORM pg_advisory_xact_lock(73912383);
  IF NOT EXISTS(SELECT 1 FROM tower_push383.config) THEN RAISE EXCEPTION 'PUSH_SETUP_REQUIRED';END IF;
  sub:=p_payload->'subscription';ep:=sub->>'endpoint';
  IF ep !~ '^https://' OR length(ep)>4096 OR length(sub#>>'{keys,p256dh}')<>87 OR length(sub#>>'{keys,auth}')<>22 THEN RAISE EXCEPTION 'INVALID_PUSH_SUBSCRIPTION';END IF;
  IF EXISTS(SELECT 1 FROM tower_push383.devices d WHERE (d.device_id=dev OR d.endpoint_hash=encode(sha256(convert_to(ep,'UTF8')),'hex')) AND d.user_id<>a.user_id AND (d.endpoint<>ep OR d.p256dh IS DISTINCT FROM sub#>>'{keys,p256dh}' OR d.auth IS DISTINCT FROM sub#>>'{keys,auth}')) THEN RAISE EXCEPTION 'PUSH_DEVICE_IN_USE';END IF;
  DELETE FROM tower_push383.devices WHERE device_id=dev OR endpoint_hash=encode(sha256(convert_to(ep,'UTF8')),'hex');
  IF (SELECT count(*) FROM tower_push383.devices WHERE user_id=a.user_id)>=10 THEN RAISE EXCEPTION 'PUSH_DEVICE_LIMIT';END IF;
  INSERT INTO tower_push383.devices(device_id,user_id,endpoint,endpoint_hash,p256dh,auth)
  VALUES(dev,a.user_id,ep,encode(sha256(convert_to(ep,'UTF8')),'hex'),sub#>>'{keys,p256dh}',sub#>>'{keys,auth}');
  UPDATE tower_push383.config SET paused=false WHERE singleton;
 ELSIF p_action='unsubscribe' THEN
  DELETE FROM tower_push383.devices WHERE device_id=dev AND user_id=a.user_id;
 ELSIF p_action='test' THEN
  IF NOT EXISTS(SELECT 1 FROM tower_push383.devices WHERE device_id=dev AND user_id=a.user_id AND enabled) THEN RAISE EXCEPTION 'PUSH_DEVICE_REQUIRED';END IF;
  IF EXISTS(SELECT 1 FROM tower_push383.jobs WHERE device_id=dev AND source='test' AND created_at>now()-interval '1 minute') THEN RAISE EXCEPTION 'PUSH_TEST_COOLDOWN';END IF;
  INSERT INTO tower_push383.jobs(device_id,source,source_id) VALUES(dev,'test',gen_random_uuid()::text);
 END IF;
 SELECT jsonb_build_object('state',j.state,'attempts',j.attempts,'code',j.last_code,'at',j.updated_at) INTO last_job FROM tower_push383.jobs j WHERE j.device_id=dev AND EXISTS(SELECT 1 FROM tower_push383.devices d WHERE d.device_id=dev AND d.user_id=a.user_id) ORDER BY created_at DESC,job_id DESC LIMIT 1;
 RETURN jsonb_build_object('configured',EXISTS(SELECT 1 FROM tower_push383.config),'enabled',EXISTS(SELECT 1 FROM tower_push383.devices WHERE device_id=dev AND user_id=a.user_id AND enabled),'lastDelivery',last_job);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_push_queue_383(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE result jsonb;j tower_push383.jobs;
BEGIN
 IF coalesce((SELECT paused FROM tower_push383.config WHERE singleton),true) THEN RETURN CASE WHEN p_action='claim' THEN '[]'::jsonb ELSE 'false'::jsonb END;END IF;
 IF p_action='claim' THEN
  -- Expired jobs and lost recipient access are cancelled rather than delivered later.
  UPDATE tower_push383.jobs x SET state='CANCELLED',updated_at=now() FROM tower_push383.devices d WHERE x.device_id=d.device_id AND x.state IN('PENDING','SENDING') AND (x.created_at<now()-interval '1 day' OR NOT d.enabled OR NOT tower_push383.allowed(d.user_id,x.source,x.source_id));
  UPDATE tower_push383.jobs SET state='FAILED',updated_at=now() WHERE state='SENDING' AND attempts>=5 AND lease_until<now();
  WITH selected AS (
   SELECT x.job_id FROM tower_push383.jobs x JOIN tower_push383.devices d ON d.device_id=x.device_id
   WHERE x.attempts<5 AND x.created_at>=now()-interval '1 day' AND d.enabled AND tower_push383.allowed(d.user_id,x.source,x.source_id)
   AND (x.state='PENDING' AND x.next_attempt_at<=now() OR x.state='SENDING' AND x.lease_until<now())
   ORDER BY x.created_at,x.job_id FOR UPDATE OF x SKIP LOCKED LIMIT 12
  ), claimed AS (
   UPDATE tower_push383.jobs x SET state='SENDING',attempts=x.attempts+1,lease_nonce=gen_random_uuid(),lease_until=now()+interval '2 minutes',updated_at=now() FROM selected s WHERE x.job_id=s.job_id RETURNING x.*
  ) SELECT coalesce(jsonb_agg(jsonb_build_object('jobId',x.job_id,'nonce',x.lease_nonce,'userId',d.user_id,'endpoint',d.endpoint,'p256dh',d.p256dh,'auth',d.auth,'source',x.source,'title',CASE WHEN x.source='notification' THEN n.title WHEN x.source='trip' THEN 'مشوار من الساكن' WHEN x.source='test' THEN 'تجربة إشعارات الجهاز' ELSE CASE x.source WHEN 'registration' THEN 'طلب تسجيل جديد' WHEN 'membership' THEN 'طلب عضوية جديد' WHEN 'subscription' THEN 'طلب اشتراك جديد' WHEN 'serviceChange' THEN 'طلب تعديل اشتراك' WHEN 'taskManagement' THEN 'طلب إدارة مهمة' WHEN 'pin' THEN 'طلب استرجاع PIN' ELSE 'تحصيل ينتظر الاعتماد' END END,'body',CASE WHEN x.source='notification' THEN n.body WHEN x.source='trip' THEN 'الوحدة '||un.unit_number||' · مشوار مفتوح' WHEN x.source='test' THEN 'إشعار تجريبي للجهاز الذي فعّلته.' ELSE 'طلب جديد يحتاج مراجعتك داخل التطبيق.' END)),'[]') INTO result FROM claimed x JOIN tower_push383.devices d ON d.device_id=x.device_id LEFT JOIN public.tower_notifications n ON x.source='notification' AND n.notification_id::text=x.source_id LEFT JOIN public.tower_trips tr ON x.source='trip' AND tr.trip_id::text=x.source_id LEFT JOIN public.tower_units un ON un.unit_id=tr.unit_id;
  RETURN result;
 END IF;
 SELECT * INTO j FROM tower_push383.jobs WHERE job_id=(p_payload->>'jobId')::uuid AND lease_nonce=(p_payload->>'nonce')::uuid AND state='SENDING' FOR UPDATE;
 IF NOT FOUND THEN RETURN 'false';END IF;
 IF p_action='validate' THEN RETURN to_jsonb(EXISTS(SELECT 1 FROM tower_push383.devices d WHERE d.device_id=j.device_id AND d.enabled AND tower_push383.allowed(d.user_id,j.source,j.source_id)) AND j.lease_until>now());END IF;
 IF p_action<>'finish' THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 IF p_payload->>'outcome'='expired' THEN DELETE FROM tower_push383.devices WHERE device_id=j.device_id;
 ELSE UPDATE tower_push383.jobs SET state=CASE WHEN p_payload->>'outcome'='sent' THEN 'SENT' WHEN attempts>=5 OR p_payload->>'outcome'='failed' THEN 'FAILED' ELSE 'PENDING' END,
 next_attempt_at=now()+make_interval(secs=>least(1800,60*(2^attempts)::int)),lease_until=NULL,last_code=(p_payload->>'code')::int,updated_at=now() WHERE job_id=j.job_id;END IF;
 DELETE FROM tower_push383.jobs WHERE state IN('SENT','FAILED','CANCELLED') AND created_at<now()-interval '7 days';
 RETURN 'true';
END $f$;
CREATE OR REPLACE FUNCTION tower_push383.pause_restore() RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $f$
BEGIN
 UPDATE tower_push383.config SET paused=true WHERE singleton;
 DELETE FROM tower_push383.devices; -- cascades runtime jobs; never replays an old device queue.
END $f$;
DO $patch$
DECLARE original text;body text;changed text;
BEGIN
 SELECT prosrc INTO body FROM pg_proc WHERE oid=to_regprocedure('tower_restore265.apply(jsonb,jsonb)');
 IF body IS NULL THEN RAISE EXCEPTION 'RESTORE_SQL265_REQUIRED';END IF;
 IF strpos(body,'PERFORM tower_push383.pause_restore();')=0 THEN
  changed:=regexp_replace(body,'\mBEGIN\M',E'BEGIN\n PERFORM tower_push383.pause_restore();');
  IF changed=body THEN RAISE EXCEPTION 'RESTORE_HOOK_NOT_INSTALLED';END IF;
  original:=pg_get_functiondef('tower_restore265.apply(jsonb,jsonb)'::regprocedure);
  EXECUTE replace(original,body,changed);
 END IF;
END $patch$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tower_push383 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_push_keys_383(jsonb),public.tower_push_device_383(text,text,jsonb),public.tower_push_queue_383(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_push_keys_383(jsonb),public.tower_push_device_383(text,text,jsonb),public.tower_push_queue_383(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.8.3 - SQL_266.
Code End
*/
