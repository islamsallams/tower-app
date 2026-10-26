/*
Tower App V2.5.182 - SQL_237.

___________________________
*/
BEGIN TRANSACTION READ ONLY;
-- Definitions only: no users, sessions, credentials, balances, or financial rows.
SELECT p.proname AS function_name,pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prokind='f'
 AND (p.proname IN ('tower_trip_account','tower_unit_fund_visibility_action','tower_resident_fund_overview_for_unit','tower_resident_dues_page_for_unit')
      OR p.proname ~ '^tower_.*(settlement|trip_account|unit_fund_visibility|resident_dues_page|resident_fund_overview).*')
ORDER BY p.proname,pg_get_function_identity_arguments(p.oid);
-- Metadata of trip tables only: required to identify the rejected undo write.
SELECT c.conrelid::regclass::text AS table_name,c.conname AS constraint_name,pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c WHERE c.conrelid IN ('public.tower_trip_payments'::regclass,'public.tower_trip_settlements'::regclass,'public.tower_trip_settlement_details'::regclass,'public.tower_trips'::regclass) ORDER BY 1,2;
SELECT t.tgrelid::regclass::text AS table_name,t.tgname AS trigger_name,pg_get_triggerdef(t.oid) AS trigger_definition,pg_get_functiondef(t.tgfoid) AS function_definition
FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgrelid IN ('public.tower_trip_payments'::regclass,'public.tower_trip_settlements'::regclass,'public.tower_trip_settlement_details'::regclass,'public.tower_trips'::regclass) ORDER BY 1,2;
COMMIT;
/*
___________________________

Tower App V2.5.182 - SQL_237.

Code End
*/
