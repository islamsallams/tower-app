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
COMMIT;
/*
___________________________

Tower App V2.5.182 - SQL_237.

Code End
*/
