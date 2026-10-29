/*
Tower App V3.5.0 - SQL_263.
___________________________
*/
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_backup_fingerprint_263() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
 SELECT md5(coalesce(string_agg(v,E'\n' ORDER BY v),'')) FROM (
  SELECT format('%s:%s:%s:%s:%s:%s',c.relname,a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attidentity,coalesce(pg_get_expr(d.adbin,d.adrelid),'')) v FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname LIKE 'tower\_%' ESCAPE '\'
  UNION ALL SELECT c.relname||':'||con.conname||':'||pg_get_constraintdef(con.oid) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'tower\_%' ESCAPE '\'
 ) s
$f$;
CREATE OR REPLACE FUNCTION public.tower_admin_data_263(p_token text,p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $f$
DECLARE actor public.tower_users;t text;tables text[];n bigint;rows jsonb;data jsonb:='{}';counts jsonb:='[]';backup jsonb;fingerprint text;edges jsonb;review jsonb:='[]';kept jsonb:='[]';deletes jsonb:='[]';cols text[];row_data jsonb;
 remove_tables constant text[]:=ARRAY[
 'tower_payment_attachments','tower_building_payments','tower_building_allocations','tower_building_charges','tower_charge_history_240','tower_charge_requests_240',
 'tower_collection_lines','tower_collection_reports','tower_collection_batches_233','tower_fund_entries',
 'tower_finance_advance_subscription_links','tower_finance_advance_use_subscriptions','tower_finance_advance_uses','tower_finance_applications','tower_finance_cash_movements','tower_finance_dues','tower_finance_mixed_collections','tower_finance_receipt_portions','tower_finance_receipts','tower_finance_refund_authorizations','tower_finance_refund_movements',
 'tower_service_change_requests','tower_service_subscriptions',
 'tower_trip_change_history','tower_trip_settlement_details','tower_trip_payments','tower_trips','tower_trip_settlements','tower_trip_notice_reads_257',
 'tower_notifications','tower_notification_reads','tower_notice_history_259','tower_telegram_delivery_log','tower_telegram_pdf_jobs',
 'tower_task_adjustments','tower_task_adjustment_lines','tower_task_agreements','tower_task_allocation_snapshots','tower_task_advance_refund_allocations','tower_task_credit_refunds','tower_task_credit_reversals','tower_task_donations','tower_task_donation_returns','tower_task_due_credits','tower_task_due_installments','tower_task_event_reads','tower_task_events','tower_task_expense_disbursements','tower_task_expenses','tower_task_fund_contributions','tower_task_fund_receipts','tower_task_interests','tower_task_projects','tower_task_requests_236','tower_task_workflow'];
 keep_tables constant text[]:=ARRAY[
 'tower_audit','tower_brand_assets','tower_brand_presentation_251','tower_collection_categories','tower_daily_digest_schedule','tower_login_attempts','tower_member_requests','tower_members','tower_pin_reset_requests','tower_registration_requests','tower_schema_baselines','tower_schema_migration_registry','tower_schema_migrations','tower_services','tower_service_edit_history_230','tower_sessions','tower_system_settings','tower_telegram_accounts','tower_telegram_cron_health','tower_telegram_links','tower_telegram_pdf_preferences','tower_telegram_pdf_schedule','tower_titles','tower_trip_settings','tower_ui_preferences','tower_unit_fund_visibility','tower_unit_types','tower_units','tower_users','tower_welcome_progress','tower_personal_ui_preferences_248','tower_unit_states_262','tower_trip_unit_preferences_242','tower_finance_accounts','tower_finance_service_beneficiaries'];
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF p_action NOT IN ('backup','restorePreview','resetPreview') OR p_action IS NULL THEN RAISE EXCEPTION 'DATA_EXECUTION_REQUIRES_REVIEWED_SCOPE';END IF;
 SELECT array_agg(c.relname ORDER BY c.relname) INTO tables FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN('r','p') AND c.relname LIKE 'tower\_%' ESCAPE '\';
 -- One transaction, all table writers paused before snapshotting any rows. No external sends or writes.
 IF p_action='backup' THEN EXECUTE 'LOCK TABLE '||(SELECT string_agg(format('public.%I',x),',' ORDER BY x) FROM unnest(tables) x)||' IN SHARE MODE';END IF;
 fingerprint:=public.tower_backup_fingerprint_263();
 IF p_action='restorePreview' THEN
  backup:=p_payload->'backup';
  IF backup->>'format' IS DISTINCT FROM 'TOWER_ACCOUNT_BACKUP_263' OR backup->>'version' IS DISTINCT FROM '3.5.0' OR backup->>'schemaFingerprint' IS DISTINCT FROM fingerprint OR jsonb_typeof(backup->'data') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'BACKUP_SCHEMA_OR_VERSION_MISMATCH';END IF;
  IF ARRAY(SELECT jsonb_object_keys(backup->'data') ORDER BY 1) IS DISTINCT FROM tables THEN RAISE EXCEPTION 'BACKUP_TABLE_SET_MISMATCH';END IF;
 END IF;
 FOREACH t IN ARRAY tables LOOP
  EXECUTE format('SELECT count(*) FROM public.%I',t) INTO n;
  IF p_action='backup' THEN
   EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) FROM public.%I r',t) INTO rows;
   data:=data||jsonb_build_object(t,rows);counts:=counts||jsonb_build_array(jsonb_build_object('table',t,'count',n));
  ELSIF p_action='restorePreview' THEN
   rows:=backup->'data'->t;
   IF jsonb_typeof(rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_BACKUP_TABLE';END IF;
   SELECT array_agg(attname::text ORDER BY attname) INTO cols FROM pg_attribute WHERE attrelid=format('public.%I',t)::regclass AND attnum>0 AND NOT attisdropped;
   FOR row_data IN SELECT value FROM jsonb_array_elements(rows) LOOP
    IF jsonb_typeof(row_data) IS DISTINCT FROM 'object' OR ARRAY(SELECT jsonb_object_keys(row_data) ORDER BY 1) IS DISTINCT FROM cols THEN RAISE EXCEPTION 'INVALID_BACKUP_COLUMNS: %',t;END IF;
   END LOOP;
   counts:=counts||jsonb_build_array(jsonb_build_object('table',t,'currentCount',n,'backupCount',jsonb_array_length(rows)));
  ELSE
   rows:=jsonb_build_array(jsonb_build_object('table',t,'count',n));
   IF t=ANY(remove_tables) THEN deletes:=deletes||rows;ELSIF t=ANY(keep_tables) THEN kept:=kept||rows;ELSE review:=review||rows;END IF;
  END IF;
 END LOOP;
 IF p_action='backup' THEN
  IF octet_length(data::text)>30*1024*1024 THEN RAISE EXCEPTION 'BACKUP_TOO_LARGE';END IF;
  RETURN jsonb_build_object('format','TOWER_ACCOUNT_BACKUP_263','version','3.5.0','createdAt',now(),'schemaFingerprint',fingerprint,'tableCounts',counts,'data',data,'scope','ALL_PUBLIC_TOWER_TABLES','containsCredentials',true,'externalCloudflareBindingsIncluded',false);
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('child',child.relname,'parent',parent.relname,'constraint',con.conname,'definition',pg_get_constraintdef(con.oid)) ORDER BY child.relname,con.conname),'[]') INTO edges FROM pg_constraint con JOIN pg_class child ON child.oid=con.conrelid JOIN pg_class parent ON parent.oid=con.confrelid JOIN pg_namespace n ON n.oid=child.relnamespace WHERE con.contype='f' AND n.nspname='public' AND (child.relname=ANY(tables) OR parent.relname=ANY(tables));
 RETURN jsonb_build_object('scope',CASE WHEN p_action='resetPreview' THEN 'OPERATIONAL_RESET_PROPOSAL_263' ELSE 'RESTORE_REVIEW_263' END,'readOnly',true,'previewOnly',true,'executionEnabled',false,'reviewRequired',true,'schemaFingerprint',fingerprint,'tables',CASE WHEN p_action='resetPreview' THEN deletes ELSE counts END,'protectedTables',kept,'reviewTables',review,'foreignKeys',edges,'backupCreated',false,
  'requiredDecisions',jsonb_build_array('مراجعة قائمة الحذف كاملة وعلاقاتها، بما فيها حسابات المهمات والصندوق والمشاوير','الاحتفاظ بتعريفات الخدمات وحساباتها مع إعادة فتح التسجيل للمهمات بعد التصفير','الاستعادة تعيد كل بيانات الحسابات والمرفقات؛ الجلسات القديمة لا يعاد تنشيطها','إيقاف جدولة الإرسال أثناء الاستعادة وتحديد مصير طوابير الإرسال القديمة','تنفيذ تجربة استعادة ورجوع كاملة على قاعدة مستقلة قبل إتاحة زر التنفيذ'));
END $f$;
REVOKE ALL ON FUNCTION public.tower_backup_fingerprint_263(),public.tower_admin_data_263(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_admin_data_263(text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.5.0 - SQL_263.
Code End
*/
