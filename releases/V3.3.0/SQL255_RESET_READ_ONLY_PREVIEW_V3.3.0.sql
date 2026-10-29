/*
Tower App V3.3.0 - SQL_255.
___________________________
Read-only review of the reported legacy reset scope. Does not replace or relax tower_operational_reset.
*/
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_operational_reset_preview_255(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;
 names constant text[]:=ARRAY['tower_payment_attachments','tower_building_payments','tower_building_allocations','tower_building_charges','tower_collection_lines','tower_collection_reports','tower_fund_entries','tower_trip_change_history','tower_trip_settlement_details','tower_trip_payments','tower_trips','tower_trip_settlements','tower_telegram_pdf_jobs','tower_service_change_requests','tower_service_subscriptions'];
 protected constant text[]:=ARRAY['tower_audit','tower_brand_assets','tower_collection_categories','tower_daily_digest_schedule','tower_login_attempts','tower_member_requests','tower_members','tower_notification_reads','tower_notifications','tower_pin_reset_requests','tower_registration_requests','tower_schema_baselines','tower_schema_migration_registry','tower_schema_migrations','tower_services','tower_sessions','tower_system_settings','tower_telegram_accounts','tower_telegram_cron_health','tower_telegram_delivery_log','tower_telegram_links','tower_telegram_pdf_preferences','tower_telegram_pdf_schedule','tower_titles','tower_trip_settings','tower_ui_preferences','tower_unit_fund_visibility','tower_unit_types','tower_units','tower_users','tower_welcome_progress'];
 t text;n bigint;total bigint:=0;rows_json jsonb:='[]';review_json jsonb:='[]';missing_json jsonb:='[]';
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin OR actor.role<>'ADMIN' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 FOREACH t IN ARRAY names||protected LOOP
  IF to_regclass(format('public.%I',t)) IS NULL THEN missing_json:=missing_json||to_jsonb(t); END IF;
 END LOOP;
 FOREACH t IN ARRAY names LOOP
  IF to_regclass(format('public.%I',t)) IS NOT NULL THEN
   EXECUTE format('SELECT count(*) FROM public.%I',t) INTO n;total:=total+n;
   rows_json:=rows_json||jsonb_build_array(jsonb_build_object('table',t,'count',n));
  END IF;
 END LOOP;
 FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname='public' AND c.relkind IN('r','p') AND c.relname LIKE 'tower_%' AND NOT(c.relname=ANY(names) OR c.relname=ANY(protected)) ORDER BY c.relname LOOP
  EXECUTE format('SELECT count(*) FROM public.%I',t) INTO n;
  review_json:=review_json||jsonb_build_array(jsonb_build_object('table',t,'count',n));
 END LOOP;
 RETURN jsonb_build_object('scope','OPERATIONAL_RESET_READ_ONLY_REVIEW','previewOnly',true,'readOnly',true,'executionEnabled',false,'reviewRequired',true,'tableCount',jsonb_array_length(rows_json),'protectedCount',array_length(protected,1),'totalRows',total,'tables',rows_json,'reviewTables',review_json,'missingTables',missing_json,'backupCreated',false);
END $f$;
REVOKE ALL ON FUNCTION public.tower_operational_reset_preview_255(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_operational_reset_preview_255(text) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________
Tower App V3.3.0 - SQL_255.
Code End
*/
