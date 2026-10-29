/*
Tower App V3.8.0 - SQL_265.
___________________________
*/
BEGIN;
-- Control data lives outside public: old SQL263 backups retain their exact table set/fingerprint.
CREATE SCHEMA IF NOT EXISTS tower_restore265;
REVOKE ALL ON SCHEMA tower_restore265 FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE IF NOT EXISTS tower_restore265.plans(
 plan_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id uuid NOT NULL,
 backup_hash text NOT NULL,live_hash text NOT NULL,schema_hash text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT now()+interval '20 minutes',
 safety_nonce uuid,safety_ready boolean NOT NULL DEFAULT false,completed_at timestamptz);
REVOKE ALL ON ALL TABLES IN SCHEMA tower_restore265 FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tower_restore265.tables() RETURNS text[] LANGUAGE sql STABLE SET search_path=pg_catalog AS $f$
 SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN('r','p') AND c.relname LIKE 'tower\_%' ESCAPE '\'
$f$;
CREATE OR REPLACE FUNCTION tower_restore265.hash(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $f$ SELECT encode(sha256(convert_to(p,'UTF8')),'hex') $f$;
CREATE OR REPLACE FUNCTION tower_restore265.live_hash() RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,public AS $f$
DECLARE t text;h text;parts text:='';
BEGIN
 FOREACH t IN ARRAY tower_restore265.tables() LOOP
  -- Routine authentication/cron writes do not invalidate a reviewed business snapshot.
  IF t=ANY(ARRAY['tower_sessions','tower_login_attempts','tower_telegram_delivery_log','tower_telegram_pdf_jobs','tower_telegram_cron_health','tower_telegram_links','tower_pin_reset_requests']) THEN CONTINUE;END IF;
  EXECUTE format('SELECT tower_restore265.hash(coalesce(string_agg(to_jsonb(r)::text,E''\n'' ORDER BY to_jsonb(r)::text),'''')) FROM public.%I r',t) INTO h;
  parts:=parts||t||':'||h||E'\n';
 END LOOP;
 RETURN tower_restore265.hash(parts);
END $f$;

-- This helper is private. Its caller owns the locks and authenticates the administrator.
-- FK definitions and trigger modes are restored inside the SAME transaction. No CASCADE outside scope.
CREATE OR REPLACE FUNCTION tower_restore265.apply(p_backup jsonb,p_actor jsonb) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $f$
DECLARE tables text[]:=tower_restore265.tables();t text;r record;fks jsonb;triggers jsonb;item jsonb;rows jsonb;cols text;vals text;seq text;maxval bigint;startval bigint;inc bigint;lastval bigint;called boolean;restartval bigint;actual jsonb;expected jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_class c WHERE c.oid=ANY(SELECT format('public.%I',x)::regclass FROM unnest(tables) x) AND (c.relkind<>'r' OR c.relispartition)) OR
 EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=ANY(SELECT format('public.%I',x)::regclass FROM unnest(tables) x) OR inhparent=ANY(SELECT format('public.%I',x)::regclass FROM unnest(tables) x)) THEN RAISE EXCEPTION 'RESTORE_UNSUPPORTED_SCHEMA';END IF;
 IF EXISTS(SELECT 1 FROM pg_constraint f WHERE f.contype='f' AND f.confrelid=ANY(SELECT format('public.%I',x)::regclass FROM unnest(tables) x) AND NOT f.conrelid=ANY(SELECT format('public.%I',x)::regclass FROM unnest(tables) x)) THEN RAISE EXCEPTION 'RESTORE_EXTERNAL_DEPENDENCY';END IF;
 IF EXISTS(SELECT 1 FROM pg_rewrite w JOIN pg_class c ON c.oid=w.ev_class WHERE c.relname=ANY(tables) AND c.relnamespace='public'::regnamespace AND w.rulename<>'_RETURN') THEN RAISE EXCEPTION 'RESTORE_UNSUPPORTED_SCHEMA';END IF;
 IF EXISTS(SELECT 1 FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid WHERE f.contype='f' AND NOT f.convalidated AND c.relname=ANY(tables) AND c.relnamespace='public'::regnamespace) THEN RAISE EXCEPTION 'RESTORE_UNSUPPORTED_SCHEMA';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('table',c.relname,'name',f.conname,'def',pg_get_constraintdef(f.oid)) ORDER BY c.relname,f.conname),'[]') INTO fks
 FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid WHERE f.contype='f' AND c.relname=ANY(tables) AND c.relnamespace='public'::regnamespace;
 SELECT coalesce(jsonb_agg(jsonb_build_object('table',c.relname,'name',tr.tgname,'mode',tr.tgenabled) ORDER BY c.relname,tr.tgname),'[]') INTO triggers
 FROM pg_trigger tr JOIN pg_class c ON c.oid=tr.tgrelid WHERE NOT tr.tgisinternal AND c.relname=ANY(tables) AND c.relnamespace='public'::regnamespace;
 FOR item IN SELECT value FROM jsonb_array_elements(triggers) LOOP
  EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER %I',item->>'table',item->>'name');
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(fks) LOOP
  EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I',item->>'table',item->>'name');
 END LOOP;
 FOREACH t IN ARRAY tables LOOP EXECUTE format('DELETE FROM public.%I',t);END LOOP;
 FOREACH t IN ARRAY tables LOOP
  rows:=p_backup->'data'->t;
  IF t=ANY(ARRAY['tower_sessions','tower_telegram_links','tower_pin_reset_requests']) THEN rows:='[]';END IF;
  IF t IN ('tower_telegram_delivery_log','tower_telegram_pdf_jobs') THEN
   SELECT coalesce(jsonb_agg(x),'[]') INTO rows FROM jsonb_array_elements(rows) x WHERE x->>'status' IN ('SENT','CANCELLED');
  END IF;
  -- Never roll back the current administrator's identity/PIN or lock them out.
  IF t='tower_users' THEN
   SELECT coalesce(jsonb_agg(CASE WHEN x->>'user_id'=p_actor->>'user_id' THEN p_actor ELSE x END),'[]') INTO rows FROM jsonb_array_elements(rows) x;
  END IF;
  IF t IN ('tower_telegram_accounts','tower_telegram_pdf_preferences') THEN
   SELECT coalesce(jsonb_agg(x||jsonb_build_object('enabled',false)),'[]') INTO rows FROM jsonb_array_elements(rows) x;
  END IF;
  SELECT string_agg(format('%I',attname),',' ORDER BY attnum),string_agg(format('r.%I',attname),',' ORDER BY attnum)
   INTO cols,vals FROM pg_attribute WHERE attrelid=format('public.%I',t)::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
  IF jsonb_array_length(rows)>0 THEN
   EXECUTE format('INSERT INTO public.%I (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM jsonb_populate_recordset(NULL::public.%I,$1) r',t,cols,vals,t) USING rows;
  END IF;
  -- Verify generated values and every stored field, not just row counts (row order is irrelevant).
  SELECT coalesce(jsonb_agg(x ORDER BY x::text),'[]') INTO expected FROM jsonb_array_elements(rows) x;
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),''[]'') FROM public.%I r',t) INTO actual;
  IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'RESTORE_ROW_MISMATCH';END IF;
  FOR r IN SELECT a.attname FROM pg_attribute a WHERE a.attrelid=format('public.%I',t)::regclass AND a.attnum>0 AND NOT a.attisdropped LOOP
   seq:=pg_get_serial_sequence(format('public.%I',t),r.attname);
   IF seq IS NULL THEN CONTINUE;END IF;
   SELECT seqstart,seqincrement INTO startval,inc FROM pg_sequence WHERE seqrelid=seq::regclass;
   IF inc<>1 THEN RAISE EXCEPTION 'RESTORE_UNSUPPORTED_SEQUENCE';END IF;
   EXECUTE format('SELECT max(%I)::bigint FROM public.%I',r.attname,t) INTO maxval;
   EXECUTE format('SELECT last_value,is_called FROM %s',seq::regclass) INTO lastval,called;
   restartval:=greatest(coalesce(maxval+1,startval),lastval+CASE WHEN called THEN 1 ELSE 0 END,startval);
   -- Unlike setval, ALTER SEQUENCE RESTART rolls back on failed imports and preview.
   EXECUTE format('ALTER SEQUENCE %s RESTART WITH %s',seq::regclass,restartval);
  END LOOP;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(fks) LOOP
  EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s',item->>'table',item->>'name',item->>'def');
 END LOOP;
 -- Explicit validation also covers constraints originally declared NOT VALID.
 FOR r IN SELECT c.relname,f.conname FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid WHERE f.contype='f' AND NOT f.convalidated AND c.relname=ANY(tables) AND c.relnamespace='public'::regnamespace LOOP
  EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I',r.relname,r.conname);
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(triggers) LOOP
  EXECUTE format('ALTER TABLE public.%I %s TRIGGER %I',item->>'table',CASE item->>'mode' WHEN 'D' THEN 'DISABLE' WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA' ELSE 'ENABLE' END,item->>'name');
 END LOOP;
END $f$;

CREATE OR REPLACE FUNCTION public.tower_admin_restore_265(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users;plan tower_restore265.plans;tables text[];review jsonb;backup jsonb;fingerprint text;live text;nonce uuid;done timestamptz;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.role IS DISTINCT FROM 'ADMIN' OR actor.status IS DISTINCT FROM 'ACTIVE' OR actor.must_change_pin IS DISTINCT FROM false THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action NOT IN ('preview','safety','execute','status') OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 PERFORM pg_advisory_xact_lock(73912265);
 IF p_action='status' THEN
  SELECT completed_at INTO done FROM tower_restore265.plans WHERE plan_id=(p_payload->>'planId')::uuid AND actor_id=actor.user_id;
  RETURN jsonb_build_object('completed',done IS NOT NULL);
 END IF;
 tables:=tower_restore265.tables();
 EXECUTE 'LOCK TABLE '||(SELECT string_agg(format('public.%I',x),',' ORDER BY x) FROM unnest(tables) x)||' IN ACCESS EXCLUSIVE MODE';
 -- Revalidate after acquiring locks; a concurrent credential revocation must win.
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.role IS DISTINCT FROM 'ADMIN' OR actor.status IS DISTINCT FROM 'ACTIVE' OR actor.must_change_pin IS DISTINCT FROM false THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 fingerprint:=public.tower_backup_fingerprint_263();live:=tower_restore265.live_hash();
 IF p_action='preview' THEN
  backup:=p_payload->'backup';
  IF octet_length(backup::text)>31*1024*1024 THEN RAISE EXCEPTION 'BACKUP_TOO_LARGE';END IF;
  review:=public.tower_admin_data_263(p_token,'restorePreview',jsonb_build_object('backup',backup));
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(backup->'data'->'tower_users') x WHERE x->>'user_id'=actor.user_id::text) THEN RAISE EXCEPTION 'RESTORE_ADMIN_MISSING';END IF;
  -- A successful dry run deliberately rolls back ALL writes, DDL and sequence changes.
  BEGIN
   PERFORM tower_restore265.apply(backup,to_jsonb(actor));
   RAISE EXCEPTION USING ERRCODE='Z0265',MESSAGE='RESTORE_DRY_RUN_COMPLETE';
  EXCEPTION WHEN SQLSTATE 'Z0265' THEN NULL;
  END;
  IF public.tower_backup_fingerprint_263() IS DISTINCT FROM fingerprint OR tower_restore265.live_hash() IS DISTINCT FROM live THEN RAISE EXCEPTION 'RESTORE_PREVIEW_CHANGED_STATE';END IF;
  DELETE FROM tower_restore265.plans WHERE completed_at IS NULL AND (expires_at<now()-interval '1 day' OR actor_id=actor.user_id);
  INSERT INTO tower_restore265.plans(actor_id,backup_hash,live_hash,schema_hash) VALUES(actor.user_id,tower_restore265.hash(backup::text),live,fingerprint) RETURNING * INTO plan;
  RETURN jsonb_build_object('scope','ATOMIC_RESTORE_265','planId',plan.plan_id,'expiresAt',plan.expires_at,'tables',review->'tables','createdAt',backup->'createdAt','validated',true,'executionEnabled',true,'preservesCurrentAdmin',true,'revokesSessions',true,'pausesTelegram',true);
 END IF;
 SELECT * INTO plan FROM tower_restore265.plans WHERE plan_id=(p_payload->>'planId')::uuid AND actor_id=actor.user_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'RESTORE_PLAN_EXPIRED';END IF;
 IF plan.completed_at IS NOT NULL THEN RETURN jsonb_build_object('success',true,'alreadyCompleted',true,'logoutRequired',true);END IF;
 IF plan.expires_at<now() THEN RAISE EXCEPTION 'RESTORE_PLAN_EXPIRED';END IF;
 IF plan.schema_hash IS DISTINCT FROM fingerprint OR plan.live_hash IS DISTINCT FROM live THEN RAISE EXCEPTION 'RESTORE_DATA_CHANGED';END IF;
 IF p_action='safety' THEN
  backup:=public.tower_admin_data_263(p_token,'backup','{}');nonce:=gen_random_uuid();
  UPDATE tower_restore265.plans SET safety_ready=true,safety_nonce=nonce WHERE plan_id=plan.plan_id;
  RETURN jsonb_build_object('backup',backup,'safetyNonce',nonce,'planId',plan.plan_id);
 END IF;
 IF NOT plan.safety_ready OR plan.safety_nonce::text IS DISTINCT FROM p_payload->>'safetyNonce' OR p_payload->>'confirmation' IS DISTINCT FROM 'استعادة' OR p_payload->>'safetySaved' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'RESTORE_CONFIRMATION_REQUIRED';END IF;
 backup:=p_payload->'backup';
 IF tower_restore265.hash(backup::text) IS DISTINCT FROM plan.backup_hash THEN RAISE EXCEPTION 'RESTORE_FILE_CHANGED';END IF;
 PERFORM tower_restore265.apply(backup,to_jsonb(actor));
 IF public.tower_backup_fingerprint_263() IS DISTINCT FROM fingerprint THEN RAISE EXCEPTION 'RESTORE_UNSUPPORTED_SCHEMA';END IF;
 IF to_regclass('public.tower_audit') IS NOT NULL THEN
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'RESTORE_BACKUP_265','DATABASE',plan.plan_id::text);
 END IF;
 UPDATE tower_restore265.plans SET completed_at=now() WHERE plan_id=plan.plan_id;
 RETURN jsonb_build_object('success',true,'logoutRequired',true,'telegramPaused',true,'planId',plan.plan_id);
END $f$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tower_restore265 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_admin_restore_265(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_admin_restore_265(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.8.0 - SQL_265.
Code End
*/
