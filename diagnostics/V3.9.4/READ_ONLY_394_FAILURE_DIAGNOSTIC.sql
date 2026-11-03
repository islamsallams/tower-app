/*
Tower App V3.9.4 - SQL_275 (READ ONLY).
___________________________
Diagnostics only: no application function is invoked, no rows are changed,
no financial preview/execute/rejection is run, no notifications are sent.
Output: function/schema metadata and anonymous membership-status observations.
No names, amounts, PINs, session values, direct user/request IDs or credentials.
Run the whole file in Supabase SQL Editor and copy the single report cell.
*/
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout='30s';
WITH targets(name,signature,expected_hash,show_body) AS (VALUES
 ('tower_task_funding_394','public.tower_task_funding_394(text,uuid,text,jsonb)','9f8f03b10fef133584a6e12a17a4876b',false),
 ('tower_reject_member_394','public.tower_reject_member_394(text,uuid,text)','79c4f602e467bf0e7b673f22a20ec3ab',false),
 ('tower_task_due_amount_internal','public.tower_task_due_amount_internal(uuid)',NULL,true),
 ('tower_task_due_paid_internal','public.tower_task_due_paid_internal(uuid)',NULL,true),
 ('tower_task_subscription_balance_internal','public.tower_task_subscription_balance_internal(uuid)',NULL,true),
 ('tower_session_user','public.tower_session_user(text)',NULL,false),
 ('tower_member_request_mutate','public.tower_member_request_mutate(text,text,jsonb)',NULL,false),
 ('tower_person_action_261','public.tower_person_action_261(text,text,text,jsonb)',NULL,false)
), functions AS (
 SELECT t.*,p.oid,p.prosrc,p.proargnames,p.prosecdef,p.provolatile,p.proowner,
 md5(btrim(regexp_replace(p.prosrc,'[[:space:]]+',' ','g'))) actual_hash
 FROM targets t LEFT JOIN pg_catalog.pg_namespace n ON n.nspname='public'
 LEFT JOIN pg_catalog.pg_proc p ON p.pronamespace=n.oid AND p.proname=t.name AND p.prokind='f'
), relevant_tables AS (
 SELECT c.oid,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity
 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN (
 'tower_users','tower_member_requests','tower_members','tower_audit','tower_services',
 'tower_service_subscriptions','tower_task_projects','tower_task_workflow',
 'tower_task_adjustments','tower_task_adjustment_lines','tower_task_due_credits',
 'tower_task_credit_reversals','tower_task_fund_contributions','tower_task_fund_receipts',
 'tower_finance_accounts','tower_finance_dues','tower_finance_applications',
 'tower_finance_receipt_portions','tower_finance_receipts','tower_finance_advance_uses',
 'tower_finance_refund_authorizations','tower_finance_refund_movements',
 'tower_finance_cash_movements','tower_task_credit_refunds','tower_fund_entries')
), member_rows AS (
 SELECT to_jsonb(r) v FROM public.tower_member_requests r
), member_state AS (
 SELECT md5(coalesce(v->>'request_id','missing')) fingerprint,v->>'status' status,
 coalesce(v->>'created_at',v->>'requested_at','') sort_time,
 EXISTS(SELECT 1 FROM public.tower_audit a WHERE a.action='REJECT_MEMBER_REQUEST_394' AND a.entity_id=v->>'request_id') reject_394_audited,
 coalesce(v->>'decided_at',v->>'reviewed_at','')<>'' decision_time_present
 FROM member_rows
)
SELECT jsonb_build_object(
 'scope','READ_ONLY_394_FAILURE_DIAGNOSTIC_275',
 'transactionReadOnly',current_setting('transaction_read_only'),
 'defaultTransactionReadOnly',current_setting('default_transaction_read_only'),
 'inRecovery',pg_is_in_recovery(),
 'functions',(SELECT coalesce(jsonb_agg(jsonb_build_object(
  'name',name,'expectedSignature',signature,'present',oid IS NOT NULL,
  'signatureMatches',oid IS NOT NULL AND oid=to_regprocedure(signature),
  'installedArguments',CASE WHEN oid IS NOT NULL THEN pg_get_function_identity_arguments(oid) ELSE NULL END,
  'argumentNames',proargnames,'securityDefiner',prosecdef,'volatility',provolatile,
  'owner',pg_get_userbyid(proowner),
  'serviceRoleCanExecute',CASE WHEN oid IS NOT NULL AND to_regrole('service_role') IS NOT NULL THEN has_function_privilege('service_role',oid,'EXECUTE') ELSE NULL END,
  'expectedBodyHash',expected_hash,'installedBodyHash',actual_hash,
  'bodyMatchesRelease',CASE WHEN expected_hash IS NOT NULL AND oid IS NOT NULL THEN expected_hash=actual_hash ELSE NULL END,
  'definition',CASE WHEN oid IS NOT NULL AND (show_body OR expected_hash IS NOT NULL AND expected_hash<>actual_hash) THEN pg_get_functiondef(oid) ELSE NULL END
 ) ORDER BY name,oid),'[]'::jsonb) FROM functions),
 'tables',(SELECT coalesce(jsonb_agg(jsonb_build_object(
  'table',t.relname,'kind',t.relkind,'rls',t.relrowsecurity,'forceRls',t.relforcerowsecurity,
  'columns',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull) ORDER BY a.attnum),'[]'::jsonb)
   FROM pg_catalog.pg_attribute a WHERE a.attrelid=t.oid AND a.attnum>0 AND NOT a.attisdropped)
 ) ORDER BY t.relname),'[]'::jsonb) FROM relevant_tables t),
 'membershipConstraints',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',c.conname,'definition',pg_get_constraintdef(c.oid)) ORDER BY c.conname),'[]'::jsonb)
  FROM pg_catalog.pg_constraint c WHERE c.conrelid='public.tower_member_requests'::regclass),
 'membershipTriggers',(SELECT coalesce(jsonb_agg(jsonb_build_object(
  'name',g.tgname,'enabled',g.tgenabled,'before',(g.tgtype::int&2)<>0,'insteadOf',(g.tgtype::int&64)<>0,
  'onInsert',(g.tgtype::int&4)<>0,'onUpdate',(g.tgtype::int&16)<>0,
  'function',format('%I.%I',n.nspname,p.proname),'functionHash',md5(btrim(regexp_replace(p.prosrc,'[[:space:]]+',' ','g')))
 ) ORDER BY g.tgname),'[]'::jsonb) FROM pg_catalog.pg_trigger g JOIN pg_catalog.pg_proc p ON p.oid=g.tgfoid JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
 WHERE g.tgrelid='public.tower_member_requests'::regclass AND NOT g.tgisinternal),
 'membershipObservations',jsonb_build_object(
  'statusCounts',(SELECT coalesce(jsonb_object_agg(coalesce(status,'NULL'),n),'{}'::jsonb) FROM (SELECT status,count(*) n FROM member_state GROUP BY status) c),
  'reject394Audits',(SELECT count(*) FROM public.tower_audit WHERE action='REJECT_MEMBER_REQUEST_394'),
  'pendingDespiteReject394Audit',(SELECT count(*) FROM member_state WHERE status='PENDING' AND reject_394_audited),
  'latestAnonymousRequests',(SELECT coalesce(jsonb_agg(jsonb_build_object('fingerprint',fingerprint,'status',status,'reject394Audited',reject_394_audited,'decisionTimePresent',decision_time_present) ORDER BY sort_time DESC,fingerprint),'[]'::jsonb)
   FROM (SELECT * FROM member_state ORDER BY sort_time DESC,fingerprint LIMIT 12) q)
 )
) AS report;
COMMIT;
/*
___________________________
Tower App V3.9.4 - SQL_275 (READ ONLY).
Code End
*/
