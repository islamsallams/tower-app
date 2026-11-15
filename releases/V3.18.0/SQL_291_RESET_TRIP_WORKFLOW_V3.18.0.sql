-- Tower App V3.18.0 | SQL 291 - classify the two SQL288 trip workflow tables
-- __________________
BEGIN;
DO $fix$
DECLARE base_oid regprocedure; definition text; parts text[]; declaration text; replacement text; body text; name text;
BEGIN
 base_oid:=to_regprocedure('tower_reset290.reset_base(text,text,jsonb)');
 IF base_oid IS NULL THEN RAISE EXCEPTION 'SQL290_RESET_GUARD_REQUIRED';END IF;
 FOREACH name IN ARRAY ARRAY['tower_trip_workflow_288','tower_trip_workflow_events_288'] LOOP
  IF to_regclass(format('public.%I',name)) IS NULL OR NOT EXISTS(
   SELECT 1 FROM pg_constraint WHERE contype='f' AND conrelid=to_regclass(format('public.%I',name))
    AND confrelid=to_regclass('public.tower_trips') AND confdeltype='c'
  ) THEN RAISE EXCEPTION 'TRIP_WORKFLOW_RELATION_REVIEW_REQUIRED: %',name;END IF;
 END LOOP;
 definition:=pg_get_functiondef(base_oid);
 -- Change only this installed function's explicit removal-list declaration.
 parts:=regexp_match(definition,'(remove_tables[[:space:]]+constant[[:space:]]+text\[\][[:space:]]*:=[[:space:]]*ARRAY\[)([^;]*)(\];)','i');
 IF parts IS NULL THEN RAISE EXCEPTION 'RESET_REMOVAL_LIST_REVIEW_REQUIRED';END IF;
 declaration:=parts[1]||parts[2]||parts[3];body:=parts[2];
 FOREACH name IN ARRAY ARRAY['tower_trip_workflow_288','tower_trip_workflow_events_288'] LOOP
  IF position(quote_literal(name) IN body)=0 THEN body:=body||','||quote_literal(name);END IF;
 END LOOP;
 replacement:=parts[1]||body||parts[3];
 IF declaration IS DISTINCT FROM replacement THEN EXECUTE replace(definition,declaration,replacement);END IF;
 -- Preserve SQL290's private boundary; the original generic FK and unknown-table guards stay intact.
 REVOKE ALL ON FUNCTION tower_reset290.reset_base(text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
END $fix$;
NOTIFY pgrst,'reload schema';
COMMIT;
-- __________________
-- Code Ended
-- SQL 291
