/*
Tower App V3.5.0 - SQL_260.
___________________________
*/
-- Complements SQL258: exact generators and their direct due-creation helpers only.
SELECT coalesce(jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid)) ORDER BY p.proname),'[]') AS report
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prokind='f' AND (
 p.proname IN('tower_charges_action','tower_generate_service_dues','tower_add_service_subscribers')
 OR p.proname ~ '^tower_(issue|create|generate|renew).*due');
/*
___________________________
Tower App V3.5.0 - SQL_260.
Code End
*/
