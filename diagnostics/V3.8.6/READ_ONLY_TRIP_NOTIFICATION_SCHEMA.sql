/*
Tower App V3.8.6 - SQL_267.
___________________________
Read-only metadata; no user rows or mutations.
*/
SELECT jsonb_build_object(
 'scope','READ_ONLY_TRIP_NOTIFICATION_SCHEMA',
 'columns',(SELECT coalesce(jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'type',data_type) ORDER BY table_name,ordinal_position),'[]'::jsonb)
 FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('tower_trips','tower_users','tower_units')),
 'functions',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid)) ORDER BY p.proname),'[]'::jsonb)
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('tower_trip_action','tower_guard_trip_context'))
) AS report;
/*
___________________________
Tower App V3.8.6 - SQL_267.
Code End
*/
