/*
Tower App V3.8.1 - SQL_138 - READ ONLY AUDIT.
___________________________
*/
-- Read-only catalog inspection. Does not invoke any application function,
-- read user rows, send messages/PDFs, or insert migration execution records.
WITH requested(name) AS (
 VALUES ('tower_telegram_pdf_claim'),('tower_telegram_pdf_start'),
        ('tower_telegram_pdf_release_claim'),('tower_telegram_pdf_finish'),
        ('tower_migration_registry_read')
), functions AS (
 SELECT r.name,p.oid,pg_get_function_identity_arguments(p.oid) AS arguments,
        p.prosecdef AS security_definer,p.proconfig AS settings,
        pg_get_functiondef(p.oid) AS definition
 FROM requested r
 LEFT JOIN (pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public' AND p.prokind='f')
 ON p.proname=r.name
), tables AS (
 SELECT c.oid,c.relname,c.relrowsecurity
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p')
 AND c.relname IN ('tower_telegram_pdf_jobs','tower_schema_migration_registry','tower_schema_migrations')
)
SELECT jsonb_build_object(
 'scope','SQL138_CURRENT_SCHEMA_READ_ONLY',
 'evidenceKind','CURRENT_DEFINITIONS_NOT_HISTORICAL_EXECUTION_PROOF',
 'readOnly',true,
 'functions',(SELECT jsonb_agg(jsonb_build_object(
   'name',name,'exists',oid IS NOT NULL,'arguments',arguments,
   'securityDefiner',security_definer,'settings',settings,'definition',definition
 ) ORDER BY name,oid) FROM functions),
 'tables',coalesce((SELECT jsonb_agg(jsonb_build_object(
   'name',t.relname,'rlsEnabled',t.relrowsecurity,
   'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull) ORDER BY a.attnum)
              FROM pg_attribute a WHERE a.attrelid=t.oid AND a.attnum>0 AND NOT a.attisdropped),
   'constraints',(SELECT jsonb_agg(jsonb_build_object('name',k.conname,'definition',pg_get_constraintdef(k.oid)) ORDER BY k.conname)
                  FROM pg_constraint k WHERE k.conrelid=t.oid)
 ) ORDER BY t.relname) FROM tables t),'[]'::jsonb)
) AS report;
/*
___________________________
Tower App V3.8.1 - SQL_138 - READ ONLY AUDIT.
Code End
*/
