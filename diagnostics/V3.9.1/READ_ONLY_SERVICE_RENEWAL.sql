/* Tower App V3.9.1 - SQL_271.
___________________________
Read-only definitions only. No user rows, tokens, PINs or modifications.
*/
BEGIN READ ONLY;
SELECT jsonb_build_object('scope','SERVICE_RENEWAL_SCHEMA_391',
'functions',(SELECT jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid))) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='public' AND (p.proname IN ('tower_generate_service_dues','tower_services_action','tower_service_change_action','tower_service_finance_action','tower_finance_issue_personal_due_internal','tower_operational_reset','tower_service_workspace_read_232') OR p.proname ILIKE '%subscription%' OR p.proname ILIKE '%cancel%due%')),
'columns',(SELECT jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'type',data_type,'default',column_default)) FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('tower_services','tower_service_subscriptions','tower_service_change_requests','tower_building_charges','tower_building_allocations','tower_finance_dues','tower_finance_applications','tower_finance_advance_uses')),
'constraints',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'definition',pg_get_constraintdef(k.oid))) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname='public' AND c.relname IN ('tower_services','tower_service_subscriptions','tower_service_change_requests','tower_building_charges','tower_building_allocations','tower_finance_dues')),
 'triggers',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'definition',pg_get_triggerdef(t.oid),'function',pg_get_functiondef(t.tgfoid))) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname='public' AND NOT t.tgisinternal AND c.relname IN ('tower_services','tower_service_subscriptions','tower_service_change_requests','tower_finance_dues'))
) AS report;
ROLLBACK;
/*
___________________________
Tower App V3.9.1 - SQL_271.
Code End
*/
