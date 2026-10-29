/*
Tower App V3.5.0 - SQL_258.
___________________________
*/
-- Read only: schema definitions, no application/user rows and no mutation.
SELECT jsonb_build_object(
 'scope','READ_ONLY_ADMIN_SCHEMA_REVIEW',
 'tables',(SELECT jsonb_agg(jsonb_build_object('name',c.relname,
 'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
 'constraints',(SELECT jsonb_agg(jsonb_build_object('name',k.conname,'kind',k.contype,'parent',CASE WHEN k.confrelid<>0 THEN k.confrelid::regclass::text END,'definition',pg_get_constraintdef(k.oid))) FROM pg_constraint k WHERE k.conrelid=c.oid),
 'triggers',(SELECT jsonb_agg(jsonb_build_object('name',t.tgname,'definition',pg_get_triggerdef(t.oid))) FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal)) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN('r','p') AND c.relname LIKE 'tower\_%' ESCAPE '\'),
 'functions',(SELECT jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid)) ORDER BY p.proname, p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND p.proname ~ '^tower_(building|finance|service|task|unit|user|admin_create_user|bulk|onboarding|notification|operational|ui_preferences|notify|person)')
) AS report;
/*
___________________________
Tower App V3.5.0 - SQL_258.
Code End
*/
