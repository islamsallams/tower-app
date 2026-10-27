/*
Tower App V2.5.193 - SQL_245.

___________________________
*/
-- Read only. Returns ONE row / ONE JSON column. Export that result as JSON or CSV.
-- No PINs, sessions, login IDs, phone numbers, tokens, or arbitrary request payloads are selected.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
WITH unit_scope AS (
 SELECT u.unit_id,u.unit_number,u.floor,u.status
 FROM public.tower_units u
 WHERE translate(btrim(u.unit_number::text),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789') ~ '^0*26$'
), settlements AS (
 SELECT s.* FROM public.tower_trip_settlements s JOIN unit_scope u ON u.unit_id=s.unit_id
), payments AS (
 SELECT p.* FROM public.tower_trip_payments p JOIN unit_scope u ON u.unit_id=p.unit_id
), trips AS (
 SELECT t.* FROM public.tower_trips t JOIN unit_scope u ON u.unit_id=t.unit_id
), details AS (
 SELECT d.* FROM public.tower_trip_settlement_details d JOIN settlements s ON s.settlement_id=d.settlement_id
), options AS (
 SELECT o.* FROM public.tower_trip_settlement_options_244 o JOIN unit_scope u ON u.unit_id=o.unit_id
), requests AS (
 SELECT r.* FROM public.tower_trip_close_requests_244 r JOIN unit_scope u ON u.unit_id=r.unit_id
), audit_rows AS (
 SELECT a.* FROM public.tower_audit a
 WHERE (upper(a.entity)='TRIP_SETTLEMENT' AND a.entity_id IN (SELECT settlement_id::text FROM settlements))
 OR (upper(a.entity)='TRIP_PAYMENT' AND a.entity_id IN (SELECT payment_id::text FROM payments))
 OR (upper(a.entity)='TRIP' AND a.entity_id IN (SELECT trip_id::text FROM trips))
), snapshot_totals AS (
 SELECT s.settlement_id,
  count(d.entity_id) FILTER(WHERE d.detail_type='TRIP') AS trip_count,
  coalesce(sum(d.amount) FILTER(WHERE d.detail_type='TRIP'),0) AS trip_total,
  coalesce(sum(d.amount) FILTER(WHERE d.detail_type='PAYMENT'),0) AS payment_total,
  coalesce(sum(d.amount) FILTER(WHERE d.detail_type='CREDIT_CARRY'),0) AS carry_total
 FROM settlements s LEFT JOIN details d ON d.settlement_id=s.settlement_id GROUP BY s.settlement_id
), issues AS (
 SELECT 'UNIT_NUMBER_SCOPE' kind,NULL::uuid entity_id,NULL::uuid unit_id,
  jsonb_build_object('matchedUnits',count(*)) facts FROM unit_scope HAVING count(*)<>1
 UNION ALL
 SELECT 'SETTLEMENT_ARITHMETIC',s.settlement_id,s.unit_id,
  jsonb_build_object('gross',s.gross_total,'purchases',s.purchases_total,'fees',s.fees_total,
   'storedPrior',s.prior_payments,'storedClosing',s.closing_payment,'carry',s.credit_after)
 FROM settlements s WHERE s.gross_total<>s.purchases_total+s.fees_total
  OR s.prior_payments+s.closing_payment<>s.gross_total+s.credit_after
 UNION ALL
 SELECT 'OPTION_SPLIT_ARITHMETIC',s.settlement_id,s.unit_id,
  jsonb_build_object('priorBeforeCash',o.prior_paid,'paidNow',o.paid_now,'explicit',o.explicit_payment,
   'extraFee',o.extra_fee,'tripFees',o.trip_fees,'gross',s.gross_total,'carry',s.credit_after,
   'storedPrior',s.prior_payments,'storedClosing',s.closing_payment)
 FROM settlements s JOIN options o ON o.settlement_id=s.settlement_id
 WHERE o.prior_paid+o.paid_now<>s.gross_total+s.credit_after OR o.trip_fees+o.extra_fee<>s.fees_total
  OR s.prior_payments<>o.prior_paid+CASE WHEN o.explicit_payment THEN o.paid_now ELSE 0 END
  OR s.closing_payment<>CASE WHEN o.explicit_payment THEN 0 ELSE o.paid_now END
 UNION ALL
 SELECT 'SNAPSHOT_TOTALS',s.settlement_id,s.unit_id,
  jsonb_build_object('snapshotTripTotal',t.trip_total,'extraFee',coalesce(o.extra_fee,0),'gross',s.gross_total,
   'snapshotPaymentTotal',t.payment_total,'storedPaidTotal',s.prior_payments+s.closing_payment,
   'snapshotCarry',t.carry_total,'carry',s.credit_after)
 FROM settlements s JOIN snapshot_totals t ON t.settlement_id=s.settlement_id LEFT JOIN options o ON o.settlement_id=s.settlement_id
 WHERE t.trip_total+coalesce(o.extra_fee,0)<>s.gross_total
  OR t.payment_total<>s.prior_payments+s.closing_payment OR t.carry_total<>s.credit_after
 UNION ALL
 SELECT 'DUPLICATE_ENTITY_IN_SAME_SNAPSHOT',d.entity_id,s.unit_id,
  jsonb_build_object('settlementId',d.settlement_id,'detailType',d.detail_type,'count',count(*))
 FROM details d JOIN settlements s ON s.settlement_id=d.settlement_id
 GROUP BY d.settlement_id,d.entity_id,d.detail_type,s.unit_id HAVING count(*)>1
 UNION ALL
 SELECT 'CANCELED_SETTLEMENT_CARRY_STILL_OPEN',p.payment_id,p.unit_id,
  jsonb_build_object('originSettlementId',s.settlement_id,'amount',p.amount,'currentSettlementId',p.settlement_id)
 FROM payments p JOIN settlements s ON lower(p.reference)=s.settlement_id::text
 WHERE p.source='SETTLEMENT_CREDIT' AND p.status='OPEN' AND s.status='CANCELED'
 UNION ALL
 SELECT 'PAYMENT_LINKED_TO_CANCELED_SETTLEMENT',p.payment_id,p.unit_id,
  jsonb_build_object('settlementId',s.settlement_id,'source',p.source,'status',p.status,'amount',p.amount)
 FROM payments p JOIN settlements s ON s.settlement_id=p.settlement_id
 WHERE s.status='CANCELED' AND p.status IN ('OPEN','APPLIED')
 UNION ALL
 SELECT 'GENERATED_CLOSING_PAYMENT_OPEN',p.payment_id,p.unit_id,
  jsonb_build_object('settlementId',p.settlement_id,'amount',p.amount,'reference',p.reference)
 FROM payments p WHERE p.source='SETTLEMENT_CLOSING' AND p.status='OPEN'
 UNION ALL
 SELECT 'OPEN_PAYMENT_WITH_SETTLEMENT_LINK',p.payment_id,p.unit_id,
  jsonb_build_object('settlementId',p.settlement_id,'source',p.source,'amount',p.amount)
 FROM payments p WHERE p.status='OPEN' AND p.settlement_id IS NOT NULL
 UNION ALL
 SELECT 'TRIP_STATE_LINK_MISMATCH',t.trip_id,t.unit_id,
  jsonb_build_object('tripStatus',t.status,'settlementId',t.settlement_id,'settlementStatus',s.status,'total',t.total_due)
 FROM trips t LEFT JOIN settlements s ON s.settlement_id=t.settlement_id
 WHERE (t.status='OPEN' AND t.settlement_id IS NOT NULL)
  OR (t.status='SETTLED' AND (t.settlement_id IS NULL OR s.status IS DISTINCT FROM 'ACTIVE'))
 UNION ALL
 SELECT 'ACTIVE_SNAPSHOT_TRIP_NOT_LINKED',d.entity_id,s.unit_id,
  jsonb_build_object('settlementId',s.settlement_id,'currentTripStatus',t.status,'currentSettlementId',t.settlement_id)
 FROM details d JOIN settlements s ON s.settlement_id=d.settlement_id LEFT JOIN trips t ON t.trip_id=d.entity_id
 WHERE d.detail_type='TRIP' AND s.status='ACTIVE'
  AND (t.trip_id IS NULL OR t.status IS DISTINCT FROM 'SETTLED' OR t.settlement_id IS DISTINCT FROM s.settlement_id)
)
SELECT jsonb_build_object(
 'diagnostic','Tower App V2.5.193 - SQL245 - Unit26 trip account',
 'readOnly',true,'reportedAt',statement_timestamp(),
 'reportedAtCairo',to_char(statement_timestamp() AT TIME ZONE 'Africa/Cairo','YYYY-MM-DD HH24:MI:SS'),
 'matchingUnitCount',(SELECT count(*) FROM unit_scope),
 'units',coalesce((SELECT jsonb_agg(jsonb_build_object('unitId',unit_id,'unitNumber',unit_number,'floor',floor,'status',status) ORDER BY unit_id) FROM unit_scope),'[]'),
 'currentAccount',coalesce((SELECT jsonb_agg(jsonb_build_object('unitId',u.unit_id,
  'openTripCount',(SELECT count(*) FROM trips t WHERE t.unit_id=u.unit_id AND t.status='OPEN' AND t.settlement_id IS NULL),
  'openTripsTotal',coalesce((SELECT sum(t.total_due) FROM trips t WHERE t.unit_id=u.unit_id AND t.status='OPEN' AND t.settlement_id IS NULL),0),
  'openPaymentsTotal',coalesce((SELECT sum(p.amount) FROM payments p WHERE p.unit_id=u.unit_id AND p.status='OPEN' AND p.settlement_id IS NULL),0),
  'due',greatest(0,coalesce((SELECT sum(t.total_due) FROM trips t WHERE t.unit_id=u.unit_id AND t.status='OPEN' AND t.settlement_id IS NULL),0)-coalesce((SELECT sum(p.amount) FROM payments p WHERE p.unit_id=u.unit_id AND p.status='OPEN' AND p.settlement_id IS NULL),0)),
  'credit',greatest(0,coalesce((SELECT sum(p.amount) FROM payments p WHERE p.unit_id=u.unit_id AND p.status='OPEN' AND p.settlement_id IS NULL),0)-coalesce((SELECT sum(t.total_due) FROM trips t WHERE t.unit_id=u.unit_id AND t.status='OPEN' AND t.settlement_id IS NULL),0))
 ) ORDER BY u.unit_id) FROM unit_scope u),'[]'),
 'settlements',coalesce((SELECT jsonb_agg(jsonb_build_object(
  'settlementId',s.settlement_id,'unitId',s.unit_id,'sequence',s.sequence_no,'status',s.status,
  'settledAt',s.settled_at,'settledAtCairo',to_char(s.settled_at AT TIME ZONE 'Africa/Cairo','YYYY-MM-DD HH24:MI:SS'),
  'settledBy',s.settled_by,'managerSnapshot',s.manager_display_name,
  'purchases',s.purchases_total,'fees',s.fees_total,'gross',s.gross_total,
  'storedPrior',s.prior_payments,'storedClosing',s.closing_payment,'creditAfter',s.credit_after,
  'canceledAt',s.canceled_at,'canceledBy',s.canceled_by,'cancelReason',s.cancel_reason,
  'options244',(SELECT jsonb_build_object('extraFee',o.extra_fee,'tripFees',o.trip_fees,'priorBeforeCash',o.prior_paid,'paidNow',o.paid_now,'explicitCash',o.explicit_payment) FROM options o WHERE o.settlement_id=s.settlement_id),
  'snapshotTotals',(SELECT to_jsonb(t)-'settlement_id' FROM snapshot_totals t WHERE t.settlement_id=s.settlement_id)
 ) ORDER BY s.unit_id,s.sequence_no) FROM settlements s),'[]'),
 'payments',coalesce((SELECT jsonb_agg(jsonb_build_object(
  'paymentId',p.payment_id,'unitId',p.unit_id,'amount',p.amount,'status',p.status,'source',p.source,
  'settlementId',p.settlement_id,'reference',p.reference,'reversalReason',p.reversal_reason,
  'createdAt',p.created_at,'createdAtCairo',to_char(p.created_at AT TIME ZONE 'Africa/Cairo','YYYY-MM-DD HH24:MI:SS'),
  'updatedAt',p.updated_at,'createdBy',p.created_by
 ) ORDER BY p.created_at,p.payment_id) FROM payments p),'[]'),
 'trips',coalesce((SELECT jsonb_agg(jsonb_build_object(
  'tripId',t.trip_id,'unitId',t.unit_id,'status',t.status,'settlementId',t.settlement_id,
  'purchases',t.purchases_total,'distanceFee',t.distance_fee,'extraFee',t.extra_fee,'total',t.total_due,
  'createdAt',t.created_at,'updatedAt',t.updated_at,'actorRole',t.actor_role,
  'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',x->>'name','price',x->'price')),'[]') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.items)='array' THEN t.items ELSE '[]' END) x)
 ) ORDER BY t.created_at,t.trip_id) FROM trips t),'[]'),
 'snapshots',coalesce((SELECT jsonb_agg(jsonb_build_object('settlementId',d.settlement_id,'unitId',d.unit_id,'type',d.detail_type,
  'entityId',d.entity_id,'status',d.status,'amount',d.amount,
  'captured',jsonb_build_object('tripId',d.snapshot->'tripId','paymentId',d.snapshot->'paymentId','purchases',d.snapshot->'purchasesTotal','distanceFee',d.snapshot->'distanceFee','extraFee',d.snapshot->'extraFee','total',d.snapshot->'totalDue','source',d.snapshot->'source','amount',d.snapshot->'amount','createdAt',d.snapshot->'createdAt'))
  ORDER BY d.settlement_id,d.detail_type,d.entity_id) FROM details d),'[]'),
 'requests244',coalesce((SELECT jsonb_agg(jsonb_build_object('requestId',r.request_id,'unitId',r.unit_id,'actorId',r.actor_id,'createdAt',r.created_at,
  'submitted',jsonb_build_object('additionalFees',r.payload->'additionalFees','paidNow',r.payload->'paidNow','revision',r.payload->'expectedRevision'),
  'result',jsonb_build_object('settlementId',r.result->'settlementId','sequence',r.result->'sequenceNo','paymentId',r.result->'paymentId','paymentOnly',r.result->'paymentOnly',
   'amount',r.result->'amount','gross',r.result->'grossTotal','prior',r.result->'priorPayments','cash',r.result->'closingPayment','extraFee',r.result->'additionalFees','credit',r.result->'creditAfter'))
  ORDER BY r.created_at,r.request_id) FROM requests r),'[]'),
 'audit',coalesce((SELECT jsonb_agg(jsonb_build_object('auditId',a.audit_id,'at',a.at,'atCairo',to_char(a.at AT TIME ZONE 'Africa/Cairo','YYYY-MM-DD HH24:MI:SS'),
  'actorId',a.actor_id,'action',a.action,'entity',a.entity,'entityId',a.entity_id) ORDER BY a.at,a.audit_id) FROM audit_rows a),'[]'),
 'actors',coalesce((SELECT jsonb_agg(jsonb_build_object('userId',u.user_id,'role',u.role,
  'displayName',public.tower_person_label_231(u.name,u.title,u.user_id)) ORDER BY u.user_id) FROM public.tower_users u
  WHERE u.user_id IN (SELECT settled_by FROM settlements UNION SELECT canceled_by FROM settlements UNION SELECT created_by FROM payments UNION SELECT actor_id FROM audit_rows UNION SELECT actor_id FROM requests)),'[]'),
 'issues',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',kind,'entityId',entity_id,'unitId',unit_id,'facts',facts) ORDER BY kind,entity_id) FROM issues),'[]'),
 'schemaConstraints',coalesce((SELECT jsonb_agg(jsonb_build_object('table',c.conrelid::regclass::text,'name',c.conname,'definition',pg_get_constraintdef(c.oid)) ORDER BY c.conrelid::regclass::text,c.conname)
  FROM pg_constraint c WHERE c.conrelid IN ('public.tower_trips'::regclass,'public.tower_trip_payments'::regclass,'public.tower_trip_settlements'::regclass,'public.tower_trip_settlement_details'::regclass,'public.tower_trip_settlement_options_244'::regclass,'public.tower_trip_close_requests_244'::regclass)),'[]'),
 'schemaTriggers',coalesce((SELECT jsonb_agg(jsonb_build_object('table',t.tgrelid::regclass::text,'name',t.tgname,'definition',pg_get_triggerdef(t.oid)) ORDER BY t.tgrelid::regclass::text,t.tgname)
  FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgrelid IN ('public.tower_trips'::regclass,'public.tower_trip_payments'::regclass,'public.tower_trip_settlements'::regclass,'public.tower_trip_settlement_details'::regclass)),'[]'),
 'installedFunctions',coalesce((SELECT jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid)) ORDER BY p.proname)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND p.proname IN ('tower_trip_account','tower_trip_settlement_action_244','tower_trip_settlement_fields_244')),'[]')
) AS report;
COMMIT;
/*
___________________________

Tower App V2.5.193 - SQL_245.

Code End
*/
