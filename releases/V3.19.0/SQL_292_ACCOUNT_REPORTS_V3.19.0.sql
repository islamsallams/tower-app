-- Tower App V3.19.0 | SQL 292 - private per-account pre-reset reports
-- __________________
BEGIN;
DO $$BEGIN IF to_regprocedure('tower_reset290.reset_base(text,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'RESET_GUARD_REQUIRED';END IF;END$$;
ALTER TABLE tower_reset290.report_tickets ADD COLUMN IF NOT EXISTS audience_hash292 text;
CREATE TABLE IF NOT EXISTS tower_reset290.account_reports292 (
 ticket_id uuid NOT NULL REFERENCES tower_reset290.report_tickets ON DELETE CASCADE,
 user_id uuid NOT NULL, role text NOT NULL, label text NOT NULL, chat_id text,
 scope jsonb NOT NULL, data jsonb NOT NULL, state text NOT NULL DEFAULT 'READY'
 CHECK(state IN ('READY','SENDING','SENT','FAILED')), pdf_hash text,
 PRIMARY KEY(ticket_id,user_id)
);
ALTER TABLE tower_reset290.account_reports292 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tower_reset290.account_reports292 FROM PUBLIC,anon,authenticated,service_role;
-- Completed resets retain delivery receipts, not another copy of deleted financial data.
CREATE OR REPLACE FUNCTION tower_reset290.scrub292() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$BEGIN
 IF NEW.state='CONSUMED' THEN
  UPDATE tower_reset290.account_reports292 SET data='{}',scope='{}',chat_id=NULL;
  UPDATE tower_reset290.report_tickets SET state='SKIPPED' WHERE ticket_id<>NEW.ticket_id AND state NOT IN ('CONSUMED','SKIPPED');
 END IF;RETURN NEW;
END$$;
REVOKE ALL ON FUNCTION tower_reset290.scrub292() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER IF EXISTS scrub_accounts292 ON tower_reset290.report_tickets;
CREATE TRIGGER scrub_accounts292 AFTER UPDATE OF state ON tower_reset290.report_tickets FOR EACH ROW WHEN(NEW.state='CONSUMED') EXECUTE FUNCTION tower_reset290.scrub292();
CREATE OR REPLACE FUNCTION tower_reset290.scope292(p_user uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('role',u.role,'chat',t.chat_id::text,
 'enabled',u.status='ACTIVE' AND NOT u.must_change_pin AND coalesce(t.enabled,false) AND coalesce(t.show_amounts,false) AND t.chat_id IS NOT NULL,
 'units',coalesce((SELECT jsonb_agg(DISTINCT m.unit_id::text ORDER BY m.unit_id::text) FROM public.tower_members m WHERE m.user_id=u.user_id AND m.ended_at IS NULL),'[]'::jsonb),
 'financeUnits',coalesce((SELECT jsonb_agg(DISTINCT m.unit_id::text ORDER BY m.unit_id::text) FROM public.tower_members m LEFT JOIN public.tower_unit_fund_visibility v ON v.unit_id=m.unit_id WHERE m.user_id=u.user_id AND m.ended_at IS NULL AND (m.member_role='MANAGER' OR coalesce(v.members_can_view,true))),'[]'::jsonb))
 FROM public.tower_users u LEFT JOIN public.tower_telegram_accounts t ON t.user_id=u.user_id WHERE u.user_id=p_user
$$;
CREATE OR REPLACE FUNCTION tower_reset290.audience292() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('userId',u.user_id,'role',u.role,'label',coalesce(nullif(to_jsonb(u)->>'name',''),'حساب'),
 'eligible',coalesce((s.v->>'enabled')::boolean,false) AND (u.role<>'RESIDENT' OR jsonb_array_length(s.v->'units')>0),
 'reason',CASE WHEN t.chat_id IS NULL THEN 'غير مرتبط بتليجرام' WHEN NOT coalesce(t.enabled,false) THEN 'إرسال تليجرام متوقف' WHEN NOT coalesce(t.show_amounts,false) THEN 'إظهار المبالغ متوقف' WHEN u.role='RESIDENT' AND jsonb_array_length(s.v->'units')=0 THEN 'لا توجد عضوية حالية' ELSE '' END)
 ORDER BY u.role,u.user_id),'[]'::jsonb)
 FROM public.tower_users u LEFT JOIN public.tower_telegram_accounts t ON t.user_id=u.user_id CROSS JOIN LATERAL(SELECT tower_reset290.scope292(u.user_id) v)s
 WHERE u.status='ACTIVE' AND NOT u.must_change_pin AND u.role IN ('ADMIN','UNION','RESIDENT','OPERATOR')
$$;
CREATE OR REPLACE FUNCTION tower_reset290.audience_proof292() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT md5(tower_reset290.audience292()::text||coalesce((SELECT jsonb_agg(tower_reset290.scope292(user_id) ORDER BY user_id)::text FROM public.tower_users WHERE status='ACTIVE' AND NOT must_change_pin AND role IN ('ADMIN','UNION','RESIDENT','OPERATOR')),'[]'))
$$;
REVOKE ALL ON FUNCTION tower_reset290.audience_proof292() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_reset_accounts_292(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users; ticket tower_reset290.report_tickets; target tower_reset290.account_reports292;
 opts jsonb; option_key text; prepared jsonb; audience jsonb; person jsonb; sc jsonb; snapshot jsonb; trips jsonb; settlements jsonb; payments jsonb; datum jsonb; result jsonb; x jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.role<>'ADMIN' OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action='audience' THEN
 UPDATE tower_reset290.account_reports292 r SET data='{}',scope='{}',chat_id=NULL FROM tower_reset290.report_tickets t WHERE r.ticket_id=t.ticket_id AND t.expires_at<=now();
 RETURN jsonb_build_object('recipients',tower_reset290.audience292(),'accountReports292',true,'audienceHash',tower_reset290.audience_proof292());END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 IF p_action='prepare' THEN
  IF p_payload->>'audienceHash' IS DISTINCT FROM tower_reset290.audience_proof292() THEN RAISE EXCEPTION 'RESET_AUDIENCE_CHANGED';END IF;
  opts:='{}'::jsonb;
  FOREACH option_key IN ARRAY ARRAY['deleteTrips','deleteServices','deleteTasks','deleteUnits','deleteResidents','deleteStaff','resetWelcome'] LOOP opts:=opts||jsonb_build_object(option_key,coalesce((p_payload->'options'->>option_key)::boolean,false));END LOOP;
  result:=tower_reset290.reset_base(p_token,'preview',opts);
  IF result->>'executionEnabled' IS DISTINCT FROM 'true' OR result->>'previewToken' IS DISTINCT FROM p_payload->>'previewToken' THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
  SELECT * INTO ticket FROM tower_reset290.report_tickets WHERE actor_id=actor.user_id AND session_hash=md5(p_token) AND proof=result->>'previewToken' AND options=opts AND audience_hash292=p_payload->>'audienceHash' AND expires_at>now() AND state NOT IN ('CONSUMED','SKIPPED') ORDER BY created_at DESC,ticket_id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
   prepared:=public.tower_reset_report_290(p_token,'prepare',p_payload);
   UPDATE tower_reset290.report_tickets SET audience_hash292=p_payload->>'audienceHash' WHERE ticket_id=(prepared->>'ticketId')::uuid RETURNING * INTO ticket;
  END IF;
  RETURN jsonb_build_object('ticketId',ticket.ticket_id,'createdAt',ticket.created_at,'state',ticket.state);
 END IF;
 SELECT * INTO ticket FROM tower_reset290.report_tickets WHERE ticket_id=(p_payload->>'ticketId')::uuid FOR UPDATE;
 IF NOT FOUND OR ticket.actor_id<>actor.user_id OR ticket.session_hash<>md5(p_token) OR ticket.expires_at<=now() OR ticket.state IN ('CONSUMED','SKIPPED') THEN RAISE EXCEPTION 'RESET_REPORT_EXPIRED';END IF;
 IF p_action='freeze' AND NOT EXISTS(SELECT 1 FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id) THEN
  IF ticket.state<>'READY' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
  IF p_payload->>'audienceHash' IS DISTINCT FROM tower_reset290.audience_proof292() THEN RAISE EXCEPTION 'RESET_AUDIENCE_CHANGED';END IF;
  result:=tower_reset290.reset_base(p_token,'preview',ticket.options);
  IF result->>'executionEnabled' IS DISTINCT FROM 'true' OR result->>'previewToken' IS DISTINCT FROM ticket.proof THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
  -- Capture all role-scoped data before any document is forwarded. Existing reset locks remain held.
  audience:=tower_reset290.audience292();
  snapshot:=public.tower_building_financial_snapshot(p_token);
  IF snapshot->>'scope' IS DISTINCT FROM 'BUILDING_ONLY' OR snapshot->>'schemaVersion' IS DISTINCT FROM '1' OR jsonb_typeof(snapshot#>'{fund,entries}') IS DISTINCT FROM 'array' OR jsonb_typeof(snapshot#>'{buildingDues,rows}') IS DISTINCT FROM 'array' OR jsonb_typeof(snapshot#>'{buildingPayments,rows}') IS DISTINCT FROM 'array' OR jsonb_typeof(snapshot#>'{subscriptions,rows}') IS DISTINCT FROM 'array' OR snapshot#>>'{privateGuardAccounts,included}' IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'RESET_SNAPSHOT_UNSUPPORTED';END IF;
  FOR person IN SELECT value FROM jsonb_array_elements(audience) WHERE value->>'eligible'='true' LOOP
   sc:=tower_reset290.scope292((person->>'userId')::uuid);
   datum:=jsonb_build_object('role',person->>'role','label',person->>'label','createdAt',ticket.created_at);
   IF person->>'role' IN ('ADMIN','UNION') THEN datum:=datum||jsonb_build_object('building',snapshot);
   ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object('unit',to_jsonb(u)->>'unit_number','date',t.created_at,'status',coalesce(w.stage,t.status),'items',t.items,'purchases',public.tower_trip_amount_288(t.trip_id,t.purchases_total))
      ||CASE WHEN person->>'role'='RESIDENT' THEN jsonb_build_object('fees',public.tower_trip_amount_288(t.trip_id,t.distance_fee+t.extra_fee),'total',public.tower_trip_amount_288(t.trip_id,t.total_due)) ELSE '{}'::jsonb END ORDER BY t.created_at,t.trip_id),'[]') INTO trips
    FROM public.tower_trips t LEFT JOIN public.tower_units u ON u.unit_id=t.unit_id LEFT JOIN public.tower_trip_workflow_288 w ON w.trip_id=t.trip_id
    WHERE person->>'role'='OPERATOR' OR sc->'units' ? t.unit_id::text;
    SELECT coalesce(jsonb_agg(jsonb_build_object('unit',to_jsonb(u)->>'unit_number','date',s.settled_at,'status',s.status,'purchases',s.purchases_total)
      ||CASE WHEN person->>'role'='RESIDENT' THEN jsonb_build_object('fees',to_jsonb(s)->'fees_total','total',to_jsonb(s)->'gross_total','previous',to_jsonb(s)->'prior_payments','paid',to_jsonb(s)->'closing_payment','credit',to_jsonb(s)->'credit_after') ELSE '{}'::jsonb END ORDER BY s.settled_at,s.settlement_id),'[]') INTO settlements
    FROM public.tower_trip_settlements s LEFT JOIN public.tower_units u ON u.unit_id=s.unit_id WHERE person->>'role'='OPERATOR' OR sc->'units' ? s.unit_id::text;
    datum:=datum||jsonb_build_object('trips',trips,'settlements',settlements);
    IF person->>'role'='RESIDENT' THEN
     SELECT coalesce(jsonb_agg(jsonb_build_object('unit',to_jsonb(u)->>'unit_number','date',coalesce(to_jsonb(t)->'paid_at',to_jsonb(t)->'created_at'),'source',to_jsonb(t)->>'source','amount',to_jsonb(t)->'amount','status',to_jsonb(t)->'status') ORDER BY t.payment_id),'[]') INTO payments FROM public.tower_trip_payments t LEFT JOIN public.tower_units u ON u.unit_id=t.unit_id WHERE sc->'units' ? t.unit_id::text;
     datum:=datum||jsonb_build_object('payments',payments);
     -- Honor the same manager/membersCanView rule as the resident unit-account screen.
     FOR x IN SELECT jsonb_build_object('key',k,'rows',coalesce((SELECT jsonb_agg(row) FROM jsonb_array_elements(coalesce(snapshot->k->'rows','[]'::jsonb)) row WHERE sc->'financeUnits' ? (row->>'unitId')),'[]'::jsonb)) FROM unnest(ARRAY['buildingDues','buildingPayments','subscriptions']) k LOOP
      datum:=datum||jsonb_build_object(x->>'key',x->'rows');
     END LOOP;
    END IF;
   END IF;
   INSERT INTO tower_reset290.account_reports292(ticket_id,user_id,role,label,chat_id,scope,data) VALUES(ticket.ticket_id,(person->>'userId')::uuid,person->>'role',person->>'label',sc->>'chat',sc,datum);
  END LOOP;
 END IF;
 IF p_action IN ('freeze','list') THEN
  RETURN jsonb_build_object('recipients',coalesce((SELECT jsonb_agg(jsonb_build_object('userId',r.user_id,'label',r.label,'role',r.role,'state',r.state) ORDER BY r.role,r.user_id) FROM tower_reset290.account_reports292 r WHERE r.ticket_id=ticket.ticket_id),'[]'::jsonb));
 END IF;
 IF p_action='finish' THEN
  IF EXISTS(SELECT 1 FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id AND state='SENDING') THEN RETURN jsonb_build_object('state','UNCERTAIN');END IF;
  IF ticket.state='SENT' AND NOT EXISTS(SELECT 1 FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id AND state<>'SENT') THEN RETURN jsonb_build_object('state','SENT');END IF;
  IF ticket.state IN ('READY','FAILED') THEN RETURN jsonb_build_object('state','FAILED');END IF;
  RETURN public.tower_reset_report_290(p_token,'finish',jsonb_build_object('ticketId',ticket.ticket_id,'success',EXISTS(SELECT 1 FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id) AND NOT EXISTS(SELECT 1 FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id AND state<>'SENT')));
 END IF;
 SELECT * INTO target FROM tower_reset290.account_reports292 WHERE ticket_id=ticket.ticket_id AND user_id=(p_payload->>'userId')::uuid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'RESET_REPORT_TARGET_REQUIRED';END IF;
 IF p_action='report' THEN RETURN jsonb_build_object('data',target.data,'state',target.state);END IF;
 IF p_action='claim' THEN
  IF target.state='SENT' THEN RETURN jsonb_build_object('state','SENT');END IF;
  IF target.state='SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_UNCERTAIN';END IF;
  IF tower_reset290.scope292(target.user_id) IS DISTINCT FROM target.scope OR target.scope->>'enabled'<>'true' THEN RAISE EXCEPTION 'RESET_REPORT_SCOPE_CHANGED';END IF;
  IF coalesce(p_payload->>'pdfHash','') !~ '^[0-9a-f]{64}$' OR (target.state<>'FAILED' AND target.pdf_hash IS NOT NULL AND target.pdf_hash IS DISTINCT FROM p_payload->>'pdfHash') THEN RAISE EXCEPTION 'RESET_REPORT_FILE_CHANGED';END IF;
  IF ticket.state IN ('READY','FAILED') THEN
   PERFORM public.tower_reset_report_290(p_token,'claim',jsonb_build_object('ticketId',ticket.ticket_id,'pdfHash',repeat(md5(ticket.ticket_id::text||ticket.proof),2)));
  ELSE PERFORM public.tower_reset_report_290(p_token,'authorize',jsonb_build_object('ticketId',ticket.ticket_id));END IF;
  UPDATE tower_reset290.account_reports292 SET state='SENDING',pdf_hash=p_payload->>'pdfHash' WHERE ticket_id=ticket.ticket_id AND user_id=target.user_id;
  RETURN jsonb_build_object('state','SENDING','chatId',target.chat_id,'createdAt',ticket.created_at);
 ELSIF p_action='sent' THEN
  IF target.state<>'SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
  PERFORM public.tower_reset_report_290(p_token,'delivered',jsonb_build_object('ticketId',ticket.ticket_id,'userId',target.user_id));
  UPDATE tower_reset290.account_reports292 SET state='SENT' WHERE ticket_id=ticket.ticket_id AND user_id=target.user_id;
  RETURN jsonb_build_object('state','SENT');
 ELSIF p_action='rejected' THEN
  IF target.state<>'SENDING' THEN RAISE EXCEPTION 'RESET_REPORT_BUSY';END IF;
  UPDATE tower_reset290.account_reports292 SET state='FAILED' WHERE ticket_id=ticket.ticket_id AND user_id=target.user_id;
  RETURN jsonb_build_object('state','FAILED');
 END IF;
 RAISE EXCEPTION 'INVALID_OPERATION';
END $f$;
REVOKE ALL ON FUNCTION tower_reset290.scope292(uuid),tower_reset290.audience292() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_reset_accounts_292(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_reset_accounts_292(text,text,jsonb) TO service_role;
-- Keep all installed workflow checks and actions. Only completion gains a missing-price gate.
DO $install$BEGIN
 IF to_regprocedure('tower_reset290.workflow_base292(text,text,jsonb)') IS NULL THEN
  IF to_regprocedure('public.tower_trip_workflow_action_288(text,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'TRIP_WORKFLOW_REQUIRED';END IF;
  ALTER FUNCTION public.tower_trip_workflow_action_288(text,text,jsonb) SET SCHEMA tower_reset290;
  ALTER FUNCTION tower_reset290.tower_trip_workflow_action_288(text,text,jsonb) RENAME TO workflow_base292;
 END IF;
END $install$;
CREATE OR REPLACE FUNCTION public.tower_trip_workflow_action_288(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE result jsonb;
BEGIN
 -- The original function authorizes the actor, target, stage and action first.
 result:=tower_reset290.workflow_base292(p_token,p_action,p_payload);
 IF p_action='done' AND EXISTS(SELECT 1 FROM public.tower_trips t CROSS JOIN LATERAL jsonb_array_elements(t.items) i WHERE t.trip_id=(p_payload->>'tripId')::uuid AND btrim(coalesce(i->>'name',''))<>'' AND btrim(coalesce(i->>'price',''))='') THEN
  -- Raising rolls back the original action and its history in the same RPC transaction.
  RAISE EXCEPTION 'UNPRICED_TRIP_ITEMS';
 END IF;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION tower_reset290.workflow_base292(text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_trip_workflow_action_288(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_trip_workflow_action_288(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
-- __________________
-- Code Ended
-- SQL 292
