/*
Tower App V3.17.0 - SQL_290.
___________________________
*/
BEGIN;
CREATE SCHEMA IF NOT EXISTS tower_reset290;
REVOKE ALL ON SCHEMA tower_reset290 FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS tower_reset290.report_tickets (
 ticket_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL,
 session_hash text NOT NULL, proof text NOT NULL, options jsonb NOT NULL,
 state text NOT NULL DEFAULT 'READY' CHECK(state IN ('READY','SENDING','FAILED','SENT','SKIPPED','CONSUMED')),
 pdf_hash text, delivered uuid[] NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '20 minutes'
);
CREATE TABLE IF NOT EXISTS tower_reset290.automatic_barrier (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), reset_at timestamptz NOT NULL
);
REVOKE ALL ON ALL TABLES IN SCHEMA tower_reset290 FROM PUBLIC,anon,authenticated;
-- Keep the installed reset engine, its scope, proof, references and rollback rules intact.
DO $install$
BEGIN
 IF to_regprocedure('tower_reset290.reset_base(text,text,jsonb)') IS NULL THEN
  IF to_regprocedure('public.tower_operational_reset_393(text,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'RESET_BASE_MISSING';END IF;
  ALTER FUNCTION public.tower_operational_reset_393(text,text,jsonb) SET SCHEMA tower_reset290;
  ALTER FUNCTION tower_reset290.tower_operational_reset_393(text,text,jsonb) RENAME TO reset_base;
 END IF;
END $install$;
REVOKE ALL ON FUNCTION tower_reset290.reset_base(text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_reset_report_290(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users; r tower_reset290.report_tickets; preview jsonb; opts jsonb; k text;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.role<>'ADMIN' OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 IF p_action='prepare' THEN
  PERFORM pg_advisory_xact_lock(73912023);
  opts:='{}'::jsonb;
  FOREACH k IN ARRAY ARRAY['deleteTrips','deleteServices','deleteTasks','deleteUnits','deleteResidents','deleteStaff','resetWelcome'] LOOP
   opts:=opts||jsonb_build_object(k,coalesce((p_payload->'options'->>k)::boolean,false));
  END LOOP;
  preview:=tower_reset290.reset_base(p_token,'preview',opts);
  IF preview->>'executionEnabled' IS DISTINCT FROM 'true' OR preview->>'previewToken' IS DISTINCT FROM p_payload->>'previewToken' THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
  DELETE FROM tower_reset290.report_tickets WHERE expires_at<now()-interval '1 day';
  INSERT INTO tower_reset290.report_tickets(actor_id,session_hash,proof,options)
  VALUES(a.user_id,md5(p_token),preview->>'previewToken',opts) RETURNING * INTO r;
 ELSE
  SELECT * INTO r FROM tower_reset290.report_tickets WHERE ticket_id=(p_payload->>'ticketId')::uuid FOR UPDATE;
  IF NOT FOUND OR r.actor_id<>a.user_id OR r.session_hash<>md5(p_token) OR r.expires_at<=now() OR r.state='CONSUMED' THEN RAISE EXCEPTION 'RESET_REPORT_EXPIRED';END IF;
  IF p_action IN ('claim','skip') THEN
   PERFORM pg_advisory_xact_lock(73912023);
   preview:=tower_reset290.reset_base(p_token,'preview',r.options);
   IF preview->>'executionEnabled' IS DISTINCT FROM 'true' OR preview->>'previewToken' IS DISTINCT FROM r.proof THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
  END IF;
  IF p_action='claim' THEN
   IF r.state NOT IN ('READY','FAILED') THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
   IF coalesce(p_payload->>'pdfHash','') !~ '^[0-9a-f]{64}$' OR (r.pdf_hash IS NOT NULL AND r.pdf_hash IS DISTINCT FROM p_payload->>'pdfHash') THEN RAISE EXCEPTION 'RESET_REPORT_FILE_CHANGED';END IF;
   UPDATE tower_reset290.report_tickets SET pdf_hash=p_payload->>'pdfHash',state='SENDING' WHERE ticket_id=r.ticket_id RETURNING * INTO r;
  ELSIF p_action='authorize' THEN
   IF r.state<>'SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
  ELSIF p_action='delivered' THEN
   IF r.state<>'SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
   UPDATE tower_reset290.report_tickets SET delivered=ARRAY(SELECT DISTINCT x FROM unnest(delivered||ARRAY[(p_payload->>'userId')::uuid]) x)
   WHERE ticket_id=r.ticket_id RETURNING * INTO r;
  ELSIF p_action='finish' THEN
   IF r.state<>'SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
   UPDATE tower_reset290.report_tickets SET state=CASE WHEN p_payload->>'success'='true' AND cardinality(delivered)>0 THEN 'SENT' ELSE 'FAILED' END
   WHERE ticket_id=r.ticket_id RETURNING * INTO r;
  ELSIF p_action='skip' THEN
   IF p_payload->>'acknowledged' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'RESET_REPORT_SKIP_CONFIRMATION_REQUIRED';END IF;
   UPDATE tower_reset290.report_tickets SET state='SKIPPED' WHERE ticket_id=r.ticket_id RETURNING * INTO r;
  ELSE RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 END IF;
 RETURN jsonb_build_object('ticketId',r.ticket_id,'state',r.state,'delivered',r.delivered,'createdAt',r.created_at);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_operational_reset_393(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE a public.tower_users; r tower_reset290.report_tickets; result jsonb; preview jsonb; saved_pdf jsonb; saved_digest jsonb; restored_count bigint:=0; inserted_count bigint; k text; opts jsonb:='{}';
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.role<>'ADMIN' OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action='preview' THEN RETURN tower_reset290.reset_base(p_token,p_action,p_payload)||jsonb_build_object('reportGuard290',true);END IF;
 IF p_action IS DISTINCT FROM 'execute' THEN RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 SELECT * INTO r FROM tower_reset290.report_tickets WHERE ticket_id=(p_payload->>'reportTicket')::uuid FOR UPDATE;
 IF NOT FOUND OR r.actor_id<>a.user_id OR r.session_hash<>md5(p_token) OR r.expires_at<=now() THEN RAISE EXCEPTION 'RESET_REPORT_REQUIRED';END IF;
 IF r.state NOT IN ('SENT','SKIPPED') THEN RAISE EXCEPTION 'RESET_REPORT_REQUIRED';END IF;
 IF r.proof IS DISTINCT FROM p_payload->>'previewToken' THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
 FOREACH k IN ARRAY ARRAY['deleteTrips','deleteServices','deleteTasks','deleteUnits','deleteResidents','deleteStaff','resetWelcome'] LOOP
  opts:=opts||jsonb_build_object(k,coalesce((p_payload->>k)::boolean,false));
 END LOOP;
 IF opts IS DISTINCT FROM r.options THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
 -- Preview locks and validates all public reset tables for this transaction.
 preview:=tower_reset290.reset_base(p_token,'preview',p_payload);
 IF preview->>'previewToken' IS DISTINCT FROM r.proof THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
 IF to_regclass('public.tower_telegram_pdf_jobs') IS NOT NULL THEN
  EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(j)),''[]''::jsonb) FROM public.tower_telegram_pdf_jobs j WHERE status=''SENT''' INTO saved_pdf;
 END IF;
 IF to_regclass('public.tower_telegram_delivery_log') IS NOT NULL THEN
  EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(j)),''[]''::jsonb) FROM public.tower_telegram_delivery_log j WHERE status=''SENT'' AND event_key ~ ''^digest:[0-9]{4}-[0-9]{2}-[0-9]{2}$''' INTO saved_digest;
 END IF;
 result:=tower_reset290.reset_base(p_token,p_action,p_payload);
 IF result->>'success' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'RESET_NOT_CONFIRMED';END IF;
 -- Retain genuine completed markers only, never invent a SENT record or restore pending messages.
 IF saved_pdf IS NOT NULL THEN
  EXECUTE 'INSERT INTO public.tower_telegram_pdf_jobs OVERRIDING SYSTEM VALUE SELECT j.* FROM jsonb_populate_recordset(NULL::public.tower_telegram_pdf_jobs,$1) j JOIN public.tower_users u ON u.user_id=j.user_id ON CONFLICT DO NOTHING' USING saved_pdf;
  GET DIAGNOSTICS inserted_count=ROW_COUNT;restored_count:=restored_count+inserted_count;
 END IF;
 IF saved_digest IS NOT NULL THEN
  EXECUTE 'INSERT INTO public.tower_telegram_delivery_log OVERRIDING SYSTEM VALUE SELECT j.* FROM jsonb_populate_recordset(NULL::public.tower_telegram_delivery_log,$1) j JOIN public.tower_users u ON u.user_id=j.user_id ON CONFLICT DO NOTHING' USING saved_digest;
  GET DIAGNOSTICS inserted_count=ROW_COUNT;restored_count:=restored_count+inserted_count;
 END IF;
 INSERT INTO tower_reset290.automatic_barrier(singleton,reset_at) VALUES(true,now()) ON CONFLICT(singleton) DO UPDATE SET reset_at=EXCLUDED.reset_at;
 UPDATE tower_reset290.report_tickets SET state='CONSUMED' WHERE ticket_id=r.ticket_id;
 RETURN result||jsonb_build_object('deletedRows',greatest(coalesce((result->>'deletedRows')::bigint,0)-restored_count,0),'retainedDeliveryMarkers',restored_count,'preResetReport',CASE WHEN r.state='SENT' THEN 'SENT' ELSE 'SKIPPED' END);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_reset_automatic_allowed_290()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE t text; present boolean;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM tower_reset290.automatic_barrier) THEN RETURN jsonb_build_object('allowed',true);END IF;
 FOREACH t IN ARRAY ARRAY['tower_fund_entries','tower_building_charges','tower_building_payments','tower_service_subscriptions','tower_finance_dues','tower_finance_cash_movements'] LOOP
  IF to_regclass(format('public.%I',t)) IS NOT NULL THEN
   EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I LIMIT 1)',t) INTO present;
   IF present THEN RETURN jsonb_build_object('allowed',true);END IF;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('allowed',false,'reason','EMPTY_AFTER_RESET');
END $f$;
REVOKE ALL ON FUNCTION public.tower_reset_report_290(text,text,jsonb),public.tower_operational_reset_393(text,text,jsonb),public.tower_reset_automatic_allowed_290() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_reset_report_290(text,text,jsonb),public.tower_operational_reset_393(text,text,jsonb),public.tower_reset_automatic_allowed_290() TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
/*
Tower App V3.17.0 - SQL_290.
___________________________
Code End
*/
