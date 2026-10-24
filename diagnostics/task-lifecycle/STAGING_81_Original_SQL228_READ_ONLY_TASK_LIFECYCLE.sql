/*
Tower App - STAGING 81 / Original SQL228 - READ-ONLY TASK LIFECYCLE DIAGNOSTIC
Run once in the Supabase SQL editor and export the single result table as CSV.
This reads schema/function definitions only. It reads no user ledger rows and
creates or changes no table, function, grant, subscription, due, receipt or balance.
SQL227 was already installed and verified online. SQL228 only reads definitions.
This file is a diagnostic, not a migration. It does not execute financial workflows.
*/
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '3s';

WITH wanted_functions(name) AS (
 SELECT DISTINCT p.proname::text
 FROM pg_catalog.pg_proc p
 JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f'
 AND (p.proname ~ '^tower_(task|finance|service|unit_services|services|shared)'
      OR p.proname IN ('tower_session_user','tower_unit_task_balances_read_for_unit'))
), relevant_relations AS (
 SELECT c.oid, n.nspname, c.relname, c.relkind,
        c.relrowsecurity, c.relforcerowsecurity
 FROM pg_catalog.pg_class c
 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
   AND c.relkind IN ('r', 'p', 'v', 'm')
   AND c.relname LIKE 'tower\_%' ESCAPE '\'
   AND (
    c.relname ~ '(service|finance|due|receipt|application|account|allocation|installment|task|building|audit)'
    OR c.relname IN ('tower_members', 'tower_units', 'tower_users', 'tower_sessions')
   )
), checks AS (
 SELECT '01_read_only_transaction'::text AS check_name,
        CASE WHEN current_setting('transaction_read_only') = 'on'
             THEN 'PASS' ELSE 'FAIL' END::text AS result,
        jsonb_build_object(
         'transaction_read_only', current_setting('transaction_read_only'),
         'database', current_database(),
         'server_version', current_setting('server_version'),
         'scope', 'SCHEMA_AND_FUNCTION_DEFINITIONS_ONLY',
         'ledger_rows_read', false,
         'writes_performed', false
        ) AS details
 UNION ALL
 SELECT '02_function:' || w.name,
        CASE WHEN count(p.oid) > 0 THEN 'FOUND' ELSE 'MISSING' END,
        jsonb_build_object(
         'name', w.name,
         'overloads', coalesce(
          jsonb_agg(jsonb_build_object(
           'identity_arguments', pg_get_function_identity_arguments(p.oid),
           'result_type', pg_get_function_result(p.oid),
           'security_definer', p.prosecdef,
           'configuration', p.proconfig,
           'acl', p.proacl::text,
           'definition', pg_get_functiondef(p.oid)
          ) ORDER BY p.oid) FILTER (WHERE p.oid IS NOT NULL),
          '[]'::jsonb
         )
        )
 FROM wanted_functions w
 LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = 'public'
 LEFT JOIN pg_catalog.pg_proc p
        ON p.pronamespace = n.oid AND p.proname = w.name AND p.prokind = 'f'
 GROUP BY w.name
 UNION ALL
 SELECT '03_relation:' || r.nspname || '.' || r.relname,
        'FOUND',
        jsonb_build_object(
         'schema', r.nspname,
         'name', r.relname,
         'kind', r.relkind,
         'row_security', r.relrowsecurity,
         'force_row_security', r.relforcerowsecurity,
         'columns', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
           'name', a.attname,
           'type', format_type(a.atttypid, a.atttypmod),
           'not_null', a.attnotnull
          ) ORDER BY a.attnum), '[]'::jsonb)
          FROM pg_catalog.pg_attribute a
          WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
         ),
         'constraints', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
           'name', con.conname,
           'type', con.contype,
           'definition', pg_get_constraintdef(con.oid, true)
          ) ORDER BY con.conname), '[]'::jsonb)
          FROM pg_catalog.pg_constraint con WHERE con.conrelid = r.oid
         ),
         'indexes', (
          SELECT coalesce(jsonb_agg(pg_get_indexdef(idx.indexrelid)
                                   ORDER BY idx.indexrelid), '[]'::jsonb)
          FROM pg_catalog.pg_index idx WHERE idx.indrelid = r.oid
         ),
         'triggers', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
           'name', t.tgname,
           'definition', pg_get_triggerdef(t.oid, true),
           'function_definition', pg_get_functiondef(t.tgfoid)
          ) ORDER BY t.tgname), '[]'::jsonb)
          FROM pg_catalog.pg_trigger t
          WHERE t.tgrelid=r.oid AND NOT t.tgisinternal
         ),
         'view_definition', CASE WHEN r.relkind IN ('v', 'm')
                                THEN pg_get_viewdef(r.oid, true) ELSE NULL END
        )
 FROM relevant_relations r
 UNION ALL
 SELECT '04_scope_summary', 'INFO',
        jsonb_build_object(
         'relevant_relation_count', (SELECT count(*) FROM relevant_relations),
         'wanted_function_count', (SELECT count(*) FROM wanted_functions),
         'application_version_reference', 'V2.5.171',
         'financial_cycle_tests', 'DEFERRED_NOT_RUN',
         'note', 'FOUND describes existence only; it is not a PASS of function behavior.'
        )
)
SELECT check_name, result, details
FROM checks
ORDER BY check_name;

COMMIT;
/*__________________________________ End of code...*/
