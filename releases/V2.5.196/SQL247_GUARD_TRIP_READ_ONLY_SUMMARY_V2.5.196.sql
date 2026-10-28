/*
Tower App V2.5.196 - SQL_247.

___________________________
*/
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_guard_trip_summary_247(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO public,pg_temp AS $f$
DECLARE actor public.tower_users;day_cairo date;
 start_at timestamptz;end_at timestamptz;result jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF actor.role<>'OPERATOR' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 day_cairo:=(statement_timestamp() AT TIME ZONE 'Africa/Cairo')::date;
 start_at:=day_cairo::timestamp AT TIME ZONE 'Africa/Cairo';
 end_at:=(day_cairo+1)::timestamp AT TIME ZONE 'Africa/Cairo';
 -- One statement snapshot; no client date, list limit, or resident fees enter these totals.
 WITH trip_stats AS (
  SELECT coalesce(sum(purchases_total) FILTER (
    WHERE status IN ('OPEN','SETTLED') AND created_at>=start_at AND created_at<end_at),0) AS today_purchases,
   coalesce(sum(purchases_total) FILTER (WHERE status='OPEN' AND settlement_id IS NULL),0) AS open_purchases,
   count(*) FILTER (WHERE status='OPEN' AND settlement_id IS NULL) AS open_count
  FROM public.tower_trips
 ), settlement_stats AS (
  SELECT coalesce(sum(purchases_total),0) AS today_purchases,count(*) AS today_count
  FROM public.tower_trip_settlements
  WHERE status='ACTIVE' AND settled_at>=start_at AND settled_at<end_at
 )
 SELECT jsonb_build_object('scope','GUARD_TRIP_SUMMARY','schemaVersion',1,
  'readOnly',true,'purchasesOnly',true,'timeZone','Africa/Cairo','day',day_cairo,
  'asOf',statement_timestamp(),'todayPurchases',t.today_purchases,
  'todaySettlementPurchases',s.today_purchases,'todaySettlementCount',s.today_count,
  'openPurchases',t.open_purchases,'openTripCount',t.open_count)
 INTO result FROM trip_stats t CROSS JOIN settlement_stats s;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_guard_trip_summary_247(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_guard_trip_summary_247(text) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.196 - SQL_247.

Code End
*/
