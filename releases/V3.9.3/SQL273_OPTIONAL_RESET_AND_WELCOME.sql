/*
Tower App V3.9.3 - SQL_273.
___________________________
Explicit operational reset. Installation does not delete any application rows.
*/
BEGIN;
ALTER TABLE public.tower_services ADD COLUMN IF NOT EXISTS reset_beneficiary_required_393 boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.tower_operational_reset_393(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users; t text; all_tables text[]; deletes text[]:=ARRAY[]::text[];
 remove_tables constant text[]:=ARRAY[
 'tower_payment_attachments','tower_building_payments','tower_building_allocations','tower_building_charges','tower_charge_history_240','tower_charge_requests_240',
 'tower_collection_lines','tower_collection_reports','tower_collection_batches_233','tower_fund_entries',
 'tower_finance_advance_subscription_links','tower_finance_advance_use_subscriptions','tower_finance_advance_uses','tower_finance_applications','tower_finance_cash_movements','tower_finance_dues','tower_finance_mixed_collections','tower_finance_receipt_portions','tower_finance_receipts','tower_finance_refund_authorizations','tower_finance_refund_movements',
 'tower_service_change_requests','tower_service_subscriptions',
 'tower_trip_change_history','tower_trip_settlement_details','tower_trip_payments','tower_trips','tower_trip_settlements','tower_trip_notice_reads_257',
 'tower_notifications','tower_notification_reads','tower_notice_history_259','tower_telegram_delivery_log','tower_telegram_pdf_jobs',
 'tower_task_adjustments','tower_task_adjustment_lines','tower_task_agreements','tower_task_allocation_snapshots','tower_task_advance_refund_allocations','tower_task_credit_refunds','tower_task_credit_reversals','tower_task_donations','tower_task_donation_returns','tower_task_due_credits','tower_task_due_installments','tower_task_event_reads','tower_task_events','tower_task_expense_disbursements','tower_task_expenses','tower_task_fund_contributions','tower_task_fund_receipts','tower_task_interests','tower_task_projects','tower_task_requests_236','tower_task_workflow','tower_trip_close_requests_244','tower_trip_settlement_options_244'];
 keep_tables constant text[]:=ARRAY[
 'tower_audit','tower_brand_assets','tower_brand_presentation_251','tower_collection_categories','tower_daily_digest_schedule','tower_login_attempts','tower_member_requests','tower_members','tower_pin_reset_requests','tower_registration_requests','tower_schema_baselines','tower_schema_migration_registry','tower_schema_migrations','tower_services','tower_service_edit_history_230','tower_sessions','tower_system_settings','tower_telegram_accounts','tower_telegram_cron_health','tower_telegram_links','tower_telegram_pdf_preferences','tower_telegram_pdf_schedule','tower_titles','tower_trip_settings','tower_ui_preferences','tower_unit_fund_visibility','tower_unit_types','tower_units','tower_users','tower_welcome_progress','tower_personal_ui_preferences_248','tower_unit_states_262','tower_trip_unit_preferences_242','tower_finance_accounts','tower_finance_service_beneficiaries','tower_trip_alert_preferences_242'];
 opts jsonb:=jsonb_build_object('deleteServices',coalesce((p_payload->>'deleteServices')::boolean,false),'deleteTasks',coalesce((p_payload->>'deleteTasks')::boolean,false),'deleteUnits',coalesce((p_payload->>'deleteUnits')::boolean,false),'deleteResidents',coalesce((p_payload->>'deleteResidents')::boolean,false),'deleteStaff',coalesce((p_payload->>'deleteStaff')::boolean,false),'resetWelcome',coalesce((p_payload->>'resetWelcome')::boolean,false));
 f record; q record; affected bigint; added bigint; join_sql text; cols_sql text; dependencies jsonb:='[]'; blockers jsonb:='[]'; identity_hash text:=''; extra_total bigint:=0; remaining bigint;
 -- Only these retained tables may lose dependent rows. Financial accounts require selected service ownership.
 dependent_tables constant text[]:=ARRAY['tower_members','tower_member_requests','tower_sessions','tower_login_attempts','tower_pin_reset_requests','tower_registration_requests','tower_ui_preferences','tower_personal_ui_preferences_248','tower_welcome_progress','tower_telegram_accounts','tower_telegram_links','tower_telegram_pdf_preferences','tower_telegram_pdf_schedule','tower_unit_fund_visibility','tower_trip_unit_preferences_242','tower_trip_alert_preferences_242','tower_service_edit_history_230','tower_finance_service_beneficiaries'];
 rows_json jsonb:='[]';kept jsonb:='[]';unknowns jsonb:='[]';n bigint;total bigint:=0;hashes text:='';row_hash text;proof text;blocked boolean:=false;report jsonb;project_templates jsonb:='[]';workflow_templates jsonb:='[]';
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action IS NULL OR p_action NOT IN ('preview','execute') THEN RAISE EXCEPTION 'INVALID_ACTION';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 PERFORM pg_advisory_xact_lock(hashtext('tower-operational-reset-391'));
 SELECT array_agg(c.relname ORDER BY c.relname) INTO all_tables FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname='public' AND c.relkind IN ('r','p') AND c.relname LIKE 'tower\_%' ESCAPE '\';
 -- Stable counts, full row fingerprints and FK checks in the same transaction as deletion.
 EXECUTE 'LOCK TABLE '||(SELECT string_agg(format('public.%I',x),',' ORDER BY x) FROM unnest(all_tables) x)||' IN SHARE ROW EXCLUSIVE MODE';
 FOREACH t IN ARRAY all_tables LOOP
  EXECUTE format('SELECT count(*) FROM public.%I',t) INTO n;
  IF t=ANY(remove_tables) THEN
   deletes:=array_append(deletes,t);total:=total+n;
   EXECUTE format('SELECT md5(coalesce(string_agg(to_jsonb(r)::text,E''\n'' ORDER BY to_jsonb(r)::text),'''')) FROM public.%I r',t) INTO row_hash;
   hashes:=hashes||t||':'||n||':'||row_hash||';';
   rows_json:=rows_json||jsonb_build_array(jsonb_build_object('table',t,'count',n));
  ELSIF t=ANY(keep_tables) THEN kept:=kept||jsonb_build_array(jsonb_build_object('table',t,'count',n));
  ELSE unknowns:=unknowns||jsonb_build_array(jsonb_build_object('table',t,'count',n));END IF;
 END LOOP;

 -- A row-level dependency plan, bound to the full retained state and exact options.
 DROP TABLE IF EXISTS pg_temp.tower_reset_rows393;
 DROP TABLE IF EXISTS pg_temp.tower_reset_null393;
 CREATE TEMP TABLE tower_reset_null393(rel oid,row_tid tid,col name,PRIMARY KEY(rel,row_tid,col)) ON COMMIT DROP;
 CREATE TEMP TABLE tower_reset_rows393(rel oid,row_tid tid,depth integer,PRIMARY KEY(rel,row_tid)) ON COMMIT DROP;
 INSERT INTO tower_reset_rows393 SELECT 'public.tower_services'::regclass,ctid,0 FROM public.tower_services
 WHERE CASE WHEN pricing_mode='SHARED_TOTAL' THEN (opts->>'deleteTasks')::boolean ELSE (opts->>'deleteServices')::boolean END;
 IF (opts->>'deleteUnits')::boolean THEN INSERT INTO tower_reset_rows393 SELECT 'public.tower_units'::regclass,ctid,0 FROM public.tower_units;END IF;
 INSERT INTO tower_reset_rows393 SELECT 'public.tower_users'::regclass,ctid,0 FROM public.tower_users WHERE user_id<>actor.user_id
 AND CASE WHEN role='RESIDENT' THEN (opts->>'deleteResidents')::boolean ELSE (opts->>'deleteStaff')::boolean END;
 -- Empty financial accounts also reset when their beneficiary is selected for deletion.
 IF to_regclass('public.tower_finance_accounts') IS NOT NULL THEN
  INSERT INTO tower_reset_rows393 SELECT 'public.tower_finance_accounts'::regclass,a.ctid,1 FROM public.tower_finance_accounts a JOIN public.tower_services s ON s.service_id=a.service_id
  JOIN tower_reset_rows393 p ON p.rel='public.tower_services'::regclass AND p.row_tid=s.ctid ON CONFLICT DO NOTHING;
  INSERT INTO tower_reset_rows393 SELECT 'public.tower_finance_accounts'::regclass,a.ctid,1 FROM public.tower_finance_accounts a JOIN public.tower_users u ON u.user_id=a.beneficiary_user_id
  JOIN tower_reset_rows393 p ON p.rel='public.tower_users'::regclass AND p.row_tid=u.ctid ON CONFLICT DO NOTHING;
 END IF;
 LOOP
  added:=0;
  FOR f IN SELECT c.*,ns.nspname child_schema,cl.relname child_table FROM pg_constraint c JOIN pg_class cl ON cl.oid=c.conrelid JOIN pg_namespace ns ON ns.oid=cl.relnamespace
   WHERE c.contype='f' AND c.confrelid IN(SELECT rel FROM tower_reset_rows393) AND ns.nspname='public' AND cl.relname=ANY(dependent_tables) LOOP
   SELECT string_agg(format('ch.%I=pa.%I',ca.attname,ra.attname),' AND ' ORDER BY k.ord) INTO join_sql
   FROM unnest(f.conkey,f.confkey) WITH ORDINALITY k(ca,ra,ord) JOIN pg_attribute ca ON ca.attrelid=f.conrelid AND ca.attnum=k.ca JOIN pg_attribute ra ON ra.attrelid=f.confrelid AND ra.attnum=k.ra;
   EXECUTE format('INSERT INTO tower_reset_rows393 SELECT %s,ch.ctid,p.depth+1 FROM %s ch JOIN %s pa ON %s JOIN tower_reset_rows393 p ON p.rel=%s AND p.row_tid=pa.ctid ON CONFLICT DO NOTHING',f.conrelid,f.conrelid::regclass,f.confrelid::regclass,join_sql,f.confrelid);
   GET DIAGNOSTICS affected=ROW_COUNT;added:=added+affected;
  END LOOP;
  EXIT WHEN added=0;
 END LOOP;
 -- Every retained row is fingerprinted, including FK links and user role changes.
 FOREACH t IN ARRAY all_tables LOOP
  IF NOT t=ANY(deletes) THEN
   EXECUTE format('SELECT md5(coalesce(string_agg(to_jsonb(r)::text,E''\n'' ORDER BY to_jsonb(r)::text),'''')) FROM public.%I r',t) INTO row_hash;
   identity_hash:=identity_hash||t||':'||row_hash||';';
  END IF;
 END LOOP;
 FOR q IN SELECT rel,count(*) n FROM tower_reset_rows393 GROUP BY rel ORDER BY rel::regclass::text LOOP
  dependencies:=dependencies||jsonb_build_array(jsonb_build_object('table',q.rel::regclass::text,'count',q.n));extra_total:=extra_total+q.n;
 END LOOP;
 -- References in retained business objects cannot silently erase objects the user chose to keep.
 FOR f IN SELECT c.*,ns.nspname child_schema,cl.relname child_table FROM pg_constraint c JOIN pg_class cl ON cl.oid=c.conrelid JOIN pg_namespace ns ON ns.oid=cl.relnamespace
  WHERE c.contype='f' AND c.confrelid IN(SELECT rel FROM tower_reset_rows393) LOOP
  IF f.child_schema='public' AND f.child_table=ANY(deletes) THEN CONTINUE;END IF;
  IF f.child_schema IN ('tower_android390','tower_push383') THEN CONTINUE;END IF;
  SELECT string_agg(format('ch.%I=pa.%I',ca.attname,ra.attname),' AND ' ORDER BY k.ord) INTO join_sql
  FROM unnest(f.conkey,f.confkey) WITH ORDINALITY k(ca,ra,ord) JOIN pg_attribute ca ON ca.attrelid=f.conrelid AND ca.attnum=k.ca JOIN pg_attribute ra ON ra.attrelid=f.confrelid AND ra.attnum=k.ra;
  EXECUTE format('SELECT count(*) FROM %s ch JOIN %s pa ON %s JOIN tower_reset_rows393 p ON p.rel=%s AND p.row_tid=pa.ctid WHERE NOT EXISTS(SELECT 1 FROM tower_reset_rows393 d WHERE d.rel=%s AND d.row_tid=ch.ctid)',f.conrelid::regclass,f.confrelid::regclass,join_sql,f.confrelid,f.conrelid) INTO affected;
  IF affected>0 AND f.child_schema='public' AND f.child_table='tower_audit' AND cardinality(f.conkey)=1 AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=f.conrelid AND attnum=f.conkey[1] AND NOT attnotnull) THEN
   SELECT attname INTO cols_sql FROM pg_attribute WHERE attrelid=f.conrelid AND attnum=f.conkey[1];
   EXECUTE format('INSERT INTO tower_reset_null393 SELECT %s,ch.ctid,%L FROM %s ch JOIN %s pa ON %s JOIN tower_reset_rows393 p ON p.rel=%s AND p.row_tid=pa.ctid ON CONFLICT DO NOTHING',f.conrelid,cols_sql,f.conrelid::regclass,f.confrelid::regclass,join_sql,f.confrelid);
   CONTINUE;
  END IF;
  IF affected>0 THEN blockers:=blockers||jsonb_build_array(jsonb_build_object('table',f.child_table,'references',affected));END IF;
 END LOOP;
 -- Never CASCADE into an unapproved table, including tables outside public.
 SELECT EXISTS(SELECT 1 FROM pg_constraint fk WHERE fk.contype='f' AND fk.confrelid IN(SELECT to_regclass(format('public.%I',x)) FROM unnest(deletes)x) AND fk.conrelid NOT IN(SELECT to_regclass(format('public.%I',x)) FROM unnest(deletes)x)) INTO blocked;
 proof:=md5(actor.user_id::text||':'||public.tower_backup_fingerprint_263()||':'||hashes||':'||identity_hash||':'||opts::text);
 report:=jsonb_build_object('scope','OPERATIONAL_RESET_393','options',opts,'selectedTables',dependencies,'blockedReferences',blockers,'selectedRows',extra_total,'servicesAwaitingBeneficiary',(SELECT count(*) FROM public.tower_finance_accounts a JOIN tower_reset_rows393 d ON d.rel='public.tower_finance_accounts'::regclass AND d.row_tid=a.ctid JOIN public.tower_services s ON s.service_id=a.service_id WHERE NOT EXISTS(SELECT 1 FROM tower_reset_rows393 x WHERE x.rel='public.tower_services'::regclass AND x.row_tid=s.ctid)),'auditReferencesCleared',(SELECT count(*) FROM tower_reset_null393),'executionEnabled',jsonb_array_length(unknowns)=0 AND NOT blocked AND jsonb_array_length(blockers)=0,'previewToken',proof,'totalRows',total+extra_total,'tableCount',cardinality(deletes),'protectedCount',jsonb_array_length(kept),'tables',rows_json,'protectedTables',kept,'reviewTables',unknowns,'blockedRelations',blocked,'backupCreated',false);
 IF p_action='preview' THEN RETURN report;END IF;
 IF p_payload->>'confirmation' IS DISTINCT FROM 'RESET TOWER APP' OR p_payload->>'acknowledgeNoBackup' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'RESET_CONFIRMATION_REQUIRED';END IF;
 IF p_payload->>'previewToken' IS DISTINCT FROM proof THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
 IF jsonb_array_length(unknowns)>0 OR blocked OR jsonb_array_length(blockers)>0 OR cardinality(deletes)=0 THEN RAISE EXCEPTION 'RESET_SCOPE_REVIEW_REQUIRED';END IF;
 -- Preserve task definitions while resetting participation, deadlines and execution state.
 IF to_regclass('public.tower_task_projects') IS NOT NULL THEN
  SELECT coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('target_units',CASE WHEN (opts->>'deleteUnits')::boolean THEN '[]'::jsonb ELSE coalesce(to_jsonb(p)->'target_units','[]'::jsonb) END,'phase','PARTICIPATION','closure_note','','deadline',NULL,'agreed_amounts','[]'::jsonb,'version',coalesce((to_jsonb(p)->>'version')::bigint,0)+1,'updated_by',actor.user_id,'updated_at',now())),'[]') INTO project_templates FROM public.tower_task_projects p WHERE NOT EXISTS(SELECT 1 FROM public.tower_services s JOIN tower_reset_rows393 d ON d.rel='public.tower_services'::regclass AND d.row_tid=s.ctid WHERE s.service_id=p.service_id);
 END IF;
 IF to_regclass('public.tower_task_workflow') IS NOT NULL THEN
  SELECT coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('stage','COLLECT_SUBSCRIBERS','execution_date',NULL,'first_due_date',NULL,'execution_percent',0,'fund_contribution_proposed',0,'revision',coalesce((to_jsonb(w)->>'revision')::bigint,0)+1,'updated_by',actor.user_id,'updated_at',now())),'[]') INTO workflow_templates FROM public.tower_task_workflow w WHERE NOT EXISTS(SELECT 1 FROM public.tower_services s JOIN tower_reset_rows393 d ON d.rel='public.tower_services'::regclass AND d.row_tid=s.ctid WHERE s.service_id=w.service_id);
 END IF;
 IF to_regprocedure('tower_push383.pause_restore()') IS NOT NULL THEN EXECUTE 'SELECT tower_push383.pause_restore()';END IF;
 IF to_regprocedure('tower_android390.pause_restore()') IS NOT NULL THEN EXECUTE 'SELECT tower_android390.pause_restore()';END IF;
 EXECUTE 'TRUNCATE TABLE '||(SELECT string_agg(format('public.%I',x),',' ORDER BY x) FROM unnest(deletes)x)||' CONTINUE IDENTITY RESTRICT';
 IF to_regclass('public.tower_task_projects') IS NOT NULL THEN
  INSERT INTO public.tower_task_projects SELECT * FROM jsonb_populate_recordset(NULL::public.tower_task_projects,project_templates);
 END IF;
 IF to_regclass('public.tower_task_workflow') IS NOT NULL THEN
  INSERT INTO public.tower_task_workflow SELECT * FROM jsonb_populate_recordset(NULL::public.tower_task_workflow,workflow_templates);
 END IF;

 -- Keep personal revenue classification while detaching the deleted beneficiary. No conversion to FUND.
 UPDATE public.tower_services s SET reset_beneficiary_required_393=true,status='INACTIVE',updated_at=now()
 WHERE EXISTS(SELECT 1 FROM public.tower_finance_accounts a JOIN tower_reset_rows393 d ON d.rel='public.tower_finance_accounts'::regclass AND d.row_tid=a.ctid WHERE a.service_id=s.service_id)
 AND NOT EXISTS(SELECT 1 FROM tower_reset_rows393 x WHERE x.rel='public.tower_services'::regclass AND x.row_tid=s.ctid);
 FOR q IN SELECT * FROM tower_reset_null393 LOOP EXECUTE format('UPDATE %s SET %I=NULL WHERE ctid=$1',q.rel::regclass,q.col) USING q.row_tid;END LOOP;
 LOOP
  added:=0;
  FOR q IN SELECT * FROM tower_reset_rows393 ORDER BY depth DESC,rel,row_tid LOOP
   BEGIN
    EXECUTE format('DELETE FROM %s WHERE ctid=$1',q.rel::regclass) USING q.row_tid;
    DELETE FROM tower_reset_rows393 WHERE rel=q.rel AND row_tid=q.row_tid;added:=added+1;
   EXCEPTION WHEN foreign_key_violation THEN NULL;
   END;
  END LOOP;
  SELECT count(*) INTO remaining FROM tower_reset_rows393;
  EXIT WHEN remaining=0;
  IF added=0 THEN RAISE EXCEPTION 'RESET_DEPENDENCY_REVIEW_REQUIRED';END IF;
 END LOOP;
 UPDATE public.tower_services SET enrollment_status='OPEN',updated_at=now() WHERE pricing_mode='SHARED_TOTAL';
 IF p_payload->>'resetWelcome'='true' AND to_regclass('public.tower_welcome_progress') IS NOT NULL THEN DELETE FROM public.tower_welcome_progress;END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'OPERATIONAL_RESET_393','SYSTEM','393');
 RETURN jsonb_build_object('success',true,'deletedRows',total+extra_total,'backupCreated',false);
END $f$;
REVOKE ALL ON FUNCTION public.tower_operational_reset_393(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_operational_reset_393(text,text,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.tower_finish_welcome_pin_393(p_token text,p_old text,p_new text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $p$
DECLARE a public.tower_users;ok boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin OR a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 PERFORM public.tower_welcome_action(p_token,'save',jsonb_build_object('step',4,'complete',true));
 SELECT public.tower_change_pin(p_token,p_old,p_new) INTO ok;
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'PIN_CHANGE_FAILED';END IF;
 RETURN jsonb_build_object('success',true);
END $p$;
REVOKE ALL ON FUNCTION public.tower_finish_welcome_pin_393(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_finish_welcome_pin_393(text,text,text) TO service_role;


-- A retained definition with a deleted personal beneficiary stays inactive until explicitly configured.
CREATE OR REPLACE FUNCTION public.tower_service_reset_guard_393() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $g$
BEGIN
 IF NEW.reset_beneficiary_required_393 AND NEW.status='ACTIVE' THEN RAISE EXCEPTION 'SERVICE_BENEFICIARY_REQUIRED_AFTER_RESET';END IF;
 RETURN NEW;
END $g$;
DROP TRIGGER IF EXISTS tower_service_reset_guard_393 ON public.tower_services;
CREATE TRIGGER tower_service_reset_guard_393 BEFORE INSERT OR UPDATE ON public.tower_services FOR EACH ROW EXECUTE FUNCTION public.tower_service_reset_guard_393();
CREATE OR REPLACE FUNCTION public.tower_subscription_reset_guard_393() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $sg$
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=NEW.service_id AND reset_beneficiary_required_393) THEN RAISE EXCEPTION 'SERVICE_BENEFICIARY_REQUIRED_AFTER_RESET';END IF;
 RETURN NEW;
END $sg$;
DROP TRIGGER IF EXISTS tower_subscription_reset_guard_393 ON public.tower_service_subscriptions;
CREATE TRIGGER tower_subscription_reset_guard_393 BEFORE INSERT OR UPDATE ON public.tower_service_subscriptions FOR EACH ROW EXECUTE FUNCTION public.tower_subscription_reset_guard_393();
CREATE OR REPLACE FUNCTION public.tower_service_list_393(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $l$
DECLARE v jsonb;
BEGIN
 v:=public.tower_service_finance_action(p_token,'list','{}');
 RETURN coalesce((SELECT jsonb_agg(CASE WHEN s.reset_beneficiary_required_393 THEN x||jsonb_build_object('beneficiaryRequiredAfterReset',true,'revenueKind','PERSONAL_SERVICE','beneficiaryUserId',NULL,'beneficiaryName',NULL) ELSE x END ORDER BY ord)
 FROM jsonb_array_elements(v) WITH ORDINALITY e(x,ord) JOIN public.tower_services s ON s.service_id=(x->>'serviceId')::uuid),'[]');
END $l$;
CREATE OR REPLACE FUNCTION public.tower_service_reset_beneficiary_393(p_token text,p_service uuid,p_beneficiary uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $b$
DECLARE a public.tower_users;sid uuid;aid uuid;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.role NOT IN ('ADMIN','UNION') OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 SELECT service_id INTO sid FROM public.tower_services WHERE service_id=p_service AND reset_beneficiary_required_393 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SERVICE_NOT_AWAITING_BENEFICIARY';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_users WHERE user_id=p_beneficiary AND status='ACTIVE') THEN RAISE EXCEPTION 'INVALID_BENEFICIARY';END IF;
 IF EXISTS(SELECT 1 FROM public.tower_finance_accounts WHERE service_id=p_service) OR EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service) OR EXISTS(SELECT 1 FROM public.tower_building_charges WHERE service_id=p_service) THEN RAISE EXCEPTION 'SERVICE_RESET_CHANGED_REFRESH';END IF;
 INSERT INTO public.tower_finance_accounts(account_kind,service_id,beneficiary_user_id,status) VALUES('PERSONAL_SERVICE',p_service,p_beneficiary,'ACTIVE') RETURNING account_id INTO aid;
 INSERT INTO public.tower_finance_service_beneficiaries(service_id,account_id,effective_from,assigned_by) VALUES(p_service,aid,current_date,a.user_id);
 UPDATE public.tower_services SET reset_beneficiary_required_393=false,updated_at=now() WHERE service_id=p_service;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'SERVICE_RESET_BENEFICIARY_393','SERVICE',p_service::text);
 RETURN jsonb_build_object('success',true,'serviceId',p_service);
END $b$;
REVOKE ALL ON FUNCTION public.tower_service_list_393(text),public.tower_service_reset_beneficiary_393(text,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_list_393(text),public.tower_service_reset_beneficiary_393(text,uuid,uuid) TO service_role;

NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.9.3 - SQL_273.
Code End
*/
