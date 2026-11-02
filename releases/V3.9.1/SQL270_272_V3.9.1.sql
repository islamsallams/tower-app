/*
Tower App V3.9.1 - SQL_272.
___________________________
Combined SQL270 and SQL272 installation in one transaction. No reset or billing runs on installation.
*/
BEGIN;
/*
Tower App V3.9.1 - SQL_270.
___________________________
Explicit operational reset. Installation does not delete any application rows.
*/
CREATE OR REPLACE FUNCTION public.tower_operational_reset_391(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
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
 -- Never CASCADE into an unapproved table, including tables outside public.
 SELECT EXISTS(SELECT 1 FROM pg_constraint f WHERE f.contype='f' AND f.confrelid IN(SELECT to_regclass(format('public.%I',x)) FROM unnest(deletes)x) AND f.conrelid NOT IN(SELECT to_regclass(format('public.%I',x)) FROM unnest(deletes)x)) INTO blocked;
 proof:=md5(actor.user_id::text||':'||public.tower_backup_fingerprint_263()||':'||hashes);
 report:=jsonb_build_object('scope','OPERATIONAL_RESET_391','executionEnabled',jsonb_array_length(unknowns)=0 AND NOT blocked,'previewToken',proof,'totalRows',total,'tableCount',cardinality(deletes),'protectedCount',jsonb_array_length(kept),'tables',rows_json,'protectedTables',kept,'reviewTables',unknowns,'blockedRelations',blocked,'backupCreated',false);
 IF p_action='preview' THEN RETURN report;END IF;
 IF p_payload->>'confirmation' IS DISTINCT FROM 'RESET TOWER APP' OR p_payload->>'acknowledgeNoBackup' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'RESET_CONFIRMATION_REQUIRED';END IF;
 IF p_payload->>'previewToken' IS DISTINCT FROM proof THEN RAISE EXCEPTION 'RESET_PREVIEW_CHANGED';END IF;
 IF jsonb_array_length(unknowns)>0 OR blocked OR cardinality(deletes)=0 THEN RAISE EXCEPTION 'RESET_SCOPE_REVIEW_REQUIRED';END IF;
 -- Preserve task definitions while resetting participation, deadlines and execution state.
 IF to_regclass('public.tower_task_projects') IS NOT NULL THEN
  SELECT coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('phase','PARTICIPATION','closure_note','','deadline',NULL,'agreed_amounts','[]'::jsonb,'version',coalesce((to_jsonb(p)->>'version')::bigint,0)+1,'updated_by',actor.user_id,'updated_at',now())),'[]') INTO project_templates FROM public.tower_task_projects p;
 END IF;
 IF to_regclass('public.tower_task_workflow') IS NOT NULL THEN
  SELECT coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('stage','COLLECT_SUBSCRIBERS','execution_date',NULL,'first_due_date',NULL,'execution_percent',0,'fund_contribution_proposed',0,'revision',coalesce((to_jsonb(w)->>'revision')::bigint,0)+1,'updated_by',actor.user_id,'updated_at',now())),'[]') INTO workflow_templates FROM public.tower_task_workflow w;
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
 UPDATE public.tower_services SET enrollment_status='OPEN',updated_at=now() WHERE pricing_mode='SHARED_TOTAL';
 IF p_payload->>'resetWelcome'='true' AND to_regclass('public.tower_welcome_progress') IS NOT NULL THEN DELETE FROM public.tower_welcome_progress;END IF;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'OPERATIONAL_RESET_391','SYSTEM','391');
 RETURN jsonb_build_object('success',true,'deletedRows',total,'backupCreated',false);
END $f$;
REVOKE ALL ON FUNCTION public.tower_operational_reset_391(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_operational_reset_391(text,text,jsonb) TO service_role;
/*
___________________________
Tower App V3.9.1 - SQL_270.
Code End
*/

/*
Tower App V3.9.1 - SQL_272.
___________________________
Monthly renewal and prospective cancellation. Installation never clears debts.
*/
CREATE SCHEMA IF NOT EXISTS tower_services391;
REVOKE ALL ON SCHEMA tower_services391 FROM PUBLIC,anon,authenticated;
ALTER TABLE public.tower_service_subscriptions ADD COLUMN IF NOT EXISTS cancel_effective_at_391 date;
ALTER TABLE public.tower_service_subscriptions ADD COLUMN IF NOT EXISTS quantity_effective_at_391 date;
ALTER TABLE public.tower_service_subscriptions ADD COLUMN IF NOT EXISTS next_quantity_391 integer;
CREATE OR REPLACE FUNCTION tower_services391.today() RETURNS date LANGUAGE sql STABLE SET search_path=pg_catalog AS $f$ SELECT (now() AT TIME ZONE 'Africa/Cairo')::date $f$;
CREATE OR REPLACE FUNCTION tower_services391.subscription_defaults() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=NEW.service_id AND service_kind='RECURRING') THEN
  IF NEW.status IN ('ACTIVE','PENDING') THEN NEW.auto_renew:=true;END IF;
  IF NEW.status='ACTIVE' AND (TG_OP='INSERT' OR OLD.status='PENDING') THEN
   NEW.started_at:=coalesce(NEW.started_at,now());
   NEW.next_renewal_at:=date_trunc('month',tower_services391.today())::date;
   NEW.billing_timing:='PREPAID';
  END IF;
 END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_recurring_defaults_391 ON public.tower_service_subscriptions;
CREATE TRIGGER tower_recurring_defaults_391 BEFORE INSERT OR UPDATE ON public.tower_service_subscriptions FOR EACH ROW EXECUTE FUNCTION tower_services391.subscription_defaults();
CREATE OR REPLACE FUNCTION tower_services391.generate(p_as_of date DEFAULT NULL,p_actor uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE sub record;bill_date date;period_date date;next_date date;v_period text;v_amount numeric;v_charge uuid;v_account uuid;accounts int;v_actor uuid;created int:=0;skipped int:=0;advanced int:=0;handled int:=0;exists_due boolean;
BEGIN
 p_as_of:=coalesce(p_as_of,tower_services391.today());
 IF p_as_of>tower_services391.today() THEN RAISE EXCEPTION 'INVALID_RUN_DATE';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 FOR sub IN SELECT x.*,s.name service_name FROM public.tower_service_subscriptions x JOIN public.tower_services s ON s.service_id=x.service_id WHERE x.status='ACTIVE' AND s.service_kind='RECURRING' AND x.next_renewal_at<=p_as_of ORDER BY x.next_renewal_at,x.subscription_id FOR UPDATE OF x LOOP
  period_date:=date_trunc('month',sub.next_renewal_at)::date;
  WHILE period_date<=p_as_of AND handled<1200 LOOP
   handled:=handled+1;
   IF sub.cancel_effective_at_391 IS NOT NULL AND period_date>=sub.cancel_effective_at_391 THEN
    UPDATE public.tower_service_subscriptions SET status='ENDED',ended_at=(sub.cancel_effective_at_391::timestamp AT TIME ZONE 'Africa/Cairo'),next_renewal_at=NULL,updated_at=now() WHERE subscription_id=sub.subscription_id;
    EXIT;
   END IF;
   IF sub.quantity_effective_at_391 IS NOT NULL AND period_date>=sub.quantity_effective_at_391 THEN
    IF sub.next_quantity_391 IS NULL OR sub.next_quantity_391<1 OR sub.next_quantity_391>99 THEN RAISE EXCEPTION 'INVALID_SCHEDULED_QUANTITY';END IF;
    sub.quantity:=sub.next_quantity_391;sub.amount_snapshot:=round(sub.unit_price_snapshot*sub.quantity,2);
    UPDATE public.tower_service_subscriptions SET quantity=sub.quantity,amount_snapshot=sub.amount_snapshot,quantity_effective_at_391=NULL,next_quantity_391=NULL,updated_at=now() WHERE subscription_id=sub.subscription_id;
    sub.quantity_effective_at_391:=NULL;
   END IF;
   bill_date:=greatest(period_date,coalesce((sub.started_at AT TIME ZONE 'Africa/Cairo')::date,period_date));
   v_amount:=sub.amount_snapshot;v_period:=to_char(period_date,'MM/YYYY');v_actor:=p_actor;
   SELECT EXISTS(SELECT 1 FROM public.tower_building_charges c JOIN public.tower_building_allocations al ON al.charge_id=c.charge_id WHERE (c.subscription_id=sub.subscription_id OR (c.service_id=sub.service_id AND al.unit_id=sub.unit_id)) AND c.period_label=v_period)
    OR EXISTS(SELECT 1 FROM public.tower_finance_dues d WHERE d.subscription_id=sub.subscription_id AND date_trunc('month',d.due_date)::date=period_date) INTO exists_due;
   IF exists_due OR public.tower_unit_exempt_262(sub.unit_id,'SERVICE') OR v_amount=0 THEN skipped:=skipped+1;
   ELSE
    IF v_amount IS NULL OR v_amount<0 THEN RAISE EXCEPTION 'SERVICE_AMOUNT_INVALID';END IF;
    SELECT count(*) INTO accounts FROM public.tower_finance_accounts WHERE service_id=sub.service_id AND account_kind='PERSONAL_SERVICE';
    IF accounts>1 THEN RAISE EXCEPTION 'SERVICE_ACCOUNT_CONFLICT';END IF;
    IF accounts=1 THEN
     SELECT account_id INTO v_account FROM public.tower_finance_accounts WHERE service_id=sub.service_id AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE';
     IF v_account IS NULL THEN RAISE EXCEPTION 'SERVICE_ACCOUNT_INACTIVE';END IF;
     PERFORM * FROM public.tower_finance_issue_personal_due_internal(sub.subscription_id,v_account,bill_date,v_amount);
    ELSE
     INSERT INTO public.tower_building_charges(title,category,due_date,total_amount,distribution,policy_snapshot,notes,period_label,created_by,service_id,subscription_id)
     VALUES('اشتراك '||sub.service_name,'خدمات',bill_date,v_amount,'CUSTOM',jsonb_build_object('distribution','CUSTOM','subscriptionId',sub.subscription_id,'unitId',sub.unit_id,'quantity',sub.quantity,'unitPrice',sub.unit_price_snapshot,'billingTiming','PREPAID'),'اشتراك شهري مستحق أول الشهر',v_period,v_actor,sub.service_id,sub.subscription_id) RETURNING charge_id INTO v_charge;
     INSERT INTO public.tower_building_allocations(charge_id,unit_id,amount,base_amount,deferred,status) VALUES(v_charge,sub.unit_id,v_amount,v_amount,false,'ACTIVE');
    END IF;
    created:=created+1;
    INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(v_actor,CASE WHEN p_actor IS NULL THEN 'AUTO_SERVICE_DUE_391' ELSE 'CREATE_SERVICE_DUE' END,'SERVICE_SUBSCRIPTION',sub.subscription_id::text);
   END IF;
   next_date:=(period_date+interval '1 month')::date;
   UPDATE public.tower_service_subscriptions SET auto_renew=true,next_renewal_at=next_date,updated_at=now() WHERE subscription_id=sub.subscription_id;
   advanced:=advanced+1;period_date:=next_date;
  END LOOP;
 END LOOP;
 RETURN jsonb_build_object('success',true,'created',created,'skipped',skipped,'advanced',advanced,'asOf',p_as_of);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_generate_service_dues(p_token text,p_as_of date DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 RETURN tower_services391.generate(p_as_of,actor.user_id);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_service_monthly_tick_391() RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$ SELECT tower_services391.generate(NULL,NULL) $f$;
CREATE OR REPLACE FUNCTION public.tower_recurring_admin_391(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users;sub public.tower_service_subscriptions;first_day date:=date_trunc('month',tower_services391.today())::date;next_month date:=(date_trunc('month',tower_services391.today())+interval '1 month')::date;v_record uuid;v_paid numeric;v_date date;v_charge uuid;v_unit uuid;v_period text;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 PERFORM pg_advisory_xact_lock(73912023);
 SELECT * INTO sub FROM public.tower_service_subscriptions WHERE subscription_id=(p_payload->>'subscriptionId')::uuid FOR UPDATE;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=sub.service_id AND service_kind='RECURRING') THEN RAISE EXCEPTION 'RECURRING_SUBSCRIPTION_REQUIRED';END IF;
 PERFORM 1 FROM public.tower_units WHERE unit_id=sub.unit_id FOR UPDATE;
 IF p_action='cancel' THEN
  IF sub.status<>'ACTIVE' THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE';END IF;
  IF sub.cancel_effective_at_391 IS NOT NULL THEN RETURN jsonb_build_object('success',true,'effectiveAt',sub.cancel_effective_at_391,'duplicate',true);END IF;
  UPDATE public.tower_service_subscriptions SET cancel_effective_at_391=next_month,updated_at=now() WHERE subscription_id=sub.subscription_id;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'SCHEDULE_SERVICE_CANCELLATION','SERVICE_SUBSCRIPTION',sub.subscription_id::text);
  RETURN jsonb_build_object('success',true,'effectiveAt',next_month);
 ELSIF p_action='waiveCurrent' THEN
  v_record:=(p_payload->>'recordId')::uuid;
  IF p_payload->>'source'='FUND' THEN
   SELECT al.paid,c.due_date,c.charge_id,al.unit_id,c.period_label INTO v_paid,v_date,v_charge,v_unit,v_period FROM public.tower_building_allocations al JOIN public.tower_building_charges c ON c.charge_id=al.charge_id WHERE al.allocation_id=v_record AND c.subscription_id=sub.subscription_id AND al.unit_id=sub.unit_id AND c.status='ACTIVE' AND al.status IN ('ACTIVE','OPEN') FOR UPDATE OF al,c;
   IF NOT FOUND THEN RAISE EXCEPTION 'CURRENT_DUE_NOT_FOUND';END IF;
   IF v_date<first_day OR v_date>=next_month OR v_period IS DISTINCT FROM to_char(first_day,'MM/YYYY') THEN RAISE EXCEPTION 'ONLY_CURRENT_MONTH_DUE';END IF;
   IF v_paid<>0 THEN RAISE EXCEPTION 'PAID_DUE_REQUIRES_FINANCIAL_REVIEW';END IF;
   UPDATE public.tower_building_allocations SET status='CANCELED' WHERE allocation_id=v_record;
   IF NOT EXISTS(SELECT 1 FROM public.tower_building_allocations WHERE charge_id=v_charge AND status IN ('ACTIVE','OPEN')) THEN UPDATE public.tower_building_charges SET status='CANCELED' WHERE charge_id=v_charge;END IF;
  ELSIF p_payload->>'source'='PERSONAL' THEN
   SELECT due_date,unit_id INTO v_date,v_unit FROM public.tower_finance_dues WHERE due_id=v_record AND subscription_id=sub.subscription_id AND unit_id=sub.unit_id AND status='OPEN' FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'CURRENT_DUE_NOT_FOUND';END IF;
   IF v_date<first_day OR v_date>=next_month THEN RAISE EXCEPTION 'ONLY_CURRENT_MONTH_DUE';END IF;
   IF public.tower_task_due_paid_internal(v_record)<>0 THEN RAISE EXCEPTION 'PAID_DUE_REQUIRES_FINANCIAL_REVIEW';END IF;
   UPDATE public.tower_finance_dues SET status='CANCELLED' WHERE due_id=v_record;
  ELSE RAISE EXCEPTION 'INVALID_DUE_SOURCE';END IF;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(actor.user_id,'WAIVE_CURRENT_SERVICE_DUE','SERVICE_SUBSCRIPTION',sub.subscription_id::text);
  RETURN jsonb_build_object('success',true,'previousMonthsUnchanged',true);
 END IF;
 RAISE EXCEPTION 'INVALID_ACTION';
END $f$;
-- Patch only recurring approval/reduction branches; ONE_TIME task behavior is preserved.
DO $install$
DECLARE def text;changed text;
BEGIN
 SELECT pg_get_functiondef('public.tower_service_change_action(text,text,jsonb)'::regprocedure) INTO def;
 IF position('RECURRING_CHANGE_391' IN def)=0 THEN
  changed:=replace(def,'update public.tower_service_subscriptions set quantity=q.requested_quantity,', $patch$
   -- RECURRING_CHANGE_391: an approved reduction starts next month, never edits old dues.
   IF q.type='REDUCE' AND EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=q.service_id AND service_kind='RECURRING') THEN
    IF sub.cancel_effective_at_391 IS NOT NULL OR sub.quantity_effective_at_391 IS NOT NULL THEN RAISE EXCEPTION 'SERVICE_CHANGE_ALREADY_SCHEDULED';END IF;
    UPDATE public.tower_service_subscriptions SET
     cancel_effective_at_391=CASE WHEN q.requested_quantity=0 THEN (date_trunc('month',tower_services391.today())+interval '1 month')::date ELSE NULL END,
     quantity_effective_at_391=CASE WHEN q.requested_quantity>0 THEN (date_trunc('month',tower_services391.today())+interval '1 month')::date ELSE NULL END,
     next_quantity_391=CASE WHEN q.requested_quantity>0 THEN q.requested_quantity ELSE NULL END,updated_at=now() WHERE subscription_id=q.subscription_id;
   ELSE
   update public.tower_service_subscriptions set quantity=q.requested_quantity,
  $patch$);
  IF changed=def THEN RAISE EXCEPTION 'SERVICE_CHANGE_DEFINITION_NOT_RECOGNIZED';END IF;
  changed:=replace(changed,$literal$if sub.status<>'ACTIVE' then raise exception 'SUBSCRIPTION_NOT_ACTIVE'; end if;$literal$,$literal$if sub.status<>'ACTIVE' then raise exception 'SUBSCRIPTION_NOT_ACTIVE'; end if; IF sub.cancel_effective_at_391 IS NOT NULL OR sub.quantity_effective_at_391 IS NOT NULL THEN RAISE EXCEPTION 'SERVICE_CHANGE_ALREADY_SCHEDULED';END IF;$literal$);
  changed:=replace(changed,'updated_at=now() where subscription_id=q.subscription_id;', 'updated_at=now() where subscription_id=q.subscription_id; END IF;');
  EXECUTE changed;
 END IF;
 SELECT pg_get_functiondef('public.tower_services_action(text,text,jsonb)'::regprocedure) INTO def;
 IF position('RECURRING_APPROVAL_391' IN def)=0 THEN
  changed:=replace(def,$literal$return jsonb_build_object('success',true,'status',case when v_decision='APPROVE' then 'ACTIVE' else 'REJECTED' end);$literal$, $patch$
   -- RECURRING_APPROVAL_391
   IF v_decision='APPROVE' AND EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=sub.service_id AND service_kind='RECURRING') THEN PERFORM tower_services391.generate(NULL,a.user_id);END IF;
   return jsonb_build_object('success',true,'status',case when v_decision='APPROVE' then 'ACTIVE' else 'REJECTED' end);
  $patch$);
  IF changed=def THEN RAISE EXCEPTION 'SERVICE_APPROVAL_DEFINITION_NOT_RECOGNIZED';END IF;
  changed:=replace(changed,$literal$if p_action='review' then$literal$,$literal$if p_action='review' then
  perform pg_advisory_xact_lock(73912023);$literal$);
  EXECUTE changed;
 END IF;
 SELECT pg_get_functiondef('public.tower_service_workspace_read_232(text,uuid,uuid)'::regprocedure) INTO def;
 IF position('cancelEffectiveAt' IN def)=0 THEN
  changed:=replace(def,$literal$'nextRenewalAt',x.next_renewal_at,$literal$, $literal$'nextRenewalAt',x.next_renewal_at,'cancelEffectiveAt',x.cancel_effective_at_391,'quantityEffectiveAt',x.quantity_effective_at_391,'nextQuantity',x.next_quantity_391,$literal$);
  IF changed=def THEN RAISE EXCEPTION 'SERVICE_READ_DEFINITION_NOT_RECOGNIZED';END IF;
  changed:=replace(changed,$literal$al.status='ACTIVE'$literal$,$literal$al.status IN ('ACTIVE','OPEN')$literal$);
  EXECUTE changed;
 END IF;
END $install$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tower_services391 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_service_monthly_tick_391(),public.tower_recurring_admin_391(text,text,jsonb),public.tower_generate_service_dues(text,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_service_monthly_tick_391(),public.tower_recurring_admin_391(text,text,jsonb),public.tower_generate_service_dues(text,date) TO service_role;
/*
___________________________
Tower App V3.9.1 - SQL_272.
Code End
*/

NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.9.1 - SQL_272.
Code End
*/
