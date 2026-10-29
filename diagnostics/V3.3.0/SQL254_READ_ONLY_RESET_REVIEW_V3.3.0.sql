/*
Tower App V3.3.0 - SQL_254.
___________________________
Read-only diagnostic. Does not call preview/execute or touch user rows.
*/
BEGIN READ ONLY;
SELECT jsonb_build_object(
 'scope','READ_ONLY_OPERATIONAL_RESET_REVIEW',
 'functions',coalesce((SELECT jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid)) ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND (p.proname LIKE '%operational_reset%' OR p.proname LIKE '%reset%manifest%' OR p.proname LIKE '%reset%schema%')),'[]'::jsonb),
 'tables',coalesce((SELECT jsonb_agg(c.relname ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN('r','p') AND c.relname LIKE 'tower_%'),'[]'::jsonb)
) AS report;
COMMIT;
/*
___________________________
Tower App V3.3.0 - SQL_254.
Code End
*/
