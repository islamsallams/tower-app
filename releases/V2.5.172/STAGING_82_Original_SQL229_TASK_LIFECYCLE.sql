/* Tower App — STAGING82 / OriginalSQL229 — task lifecycle.
   New append-only task records and trusted RPCs. SQL228 was a read-only diagnostic.
   Existing task rows are not converted to proposals; existing ledger amounts stay intact.
   Execute as one transaction. No migration executes a financial workflow. */
BEGIN;
CREATE TABLE IF NOT EXISTS public.tower_task_projects (
 service_id uuid PRIMARY KEY REFERENCES public.tower_services(service_id),
 creation_reference text UNIQUE,creation_payload jsonb,
 phase text NOT NULL DEFAULT 'PARTICIPATION' CHECK(phase IN ('PROPOSAL','PARTICIPATION','CANCELLED','FINANCIAL_CLOSED')),
 closure_note text NOT NULL DEFAULT '',scope_text text NOT NULL DEFAULT '',target_units uuid[] NOT NULL DEFAULT '{}',deadline date,
 distribution text NOT NULL DEFAULT 'EQUAL' CHECK(distribution IN ('EQUAL','CUSTOM')),
 agreed_amounts jsonb NOT NULL DEFAULT '[]',policy_text text NOT NULL DEFAULT '',
 minimum_start_amount numeric(16,2) CHECK(minimum_start_amount>=0),
 version bigint NOT NULL DEFAULT 1,updated_by uuid REFERENCES public.tower_users(user_id),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tower_task_interests (
 service_id uuid REFERENCES public.tower_task_projects(service_id),unit_id uuid REFERENCES public.tower_units(unit_id),
 interested boolean NOT NULL,recorded_by uuid NOT NULL REFERENCES public.tower_users(user_id),recorded_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(service_id,unit_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_agreements (
 subscription_id uuid PRIMARY KEY REFERENCES public.tower_service_subscriptions(subscription_id),
 source text NOT NULL CHECK(source IN ('APP','WHATSAPP','MEETING','PHONE','OTHER')),
 note text NOT NULL DEFAULT '',recorded_by uuid NOT NULL REFERENCES public.tower_users(user_id),recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tower_task_allocation_snapshots (
 service_id uuid NOT NULL REFERENCES public.tower_services(service_id),subscription_id uuid NOT NULL REFERENCES public.tower_service_subscriptions(subscription_id),
 unit_id uuid NOT NULL REFERENCES public.tower_units(unit_id),account_id uuid NOT NULL REFERENCES public.tower_finance_accounts(account_id),
 original_amount numeric(16,2) NOT NULL CHECK(original_amount>=0),captured_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(service_id,subscription_id),UNIQUE(service_id,unit_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_adjustments (
 adjustment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_id uuid NOT NULL REFERENCES public.tower_services(service_id),
 reference text NOT NULL,amount numeric(16,2) NOT NULL CHECK(amount<>0),reason text NOT NULL CHECK(length(btrim(reason))>0),
 state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN ('DRAFT','APPROVED','CANCELLED')),
 proposed_by uuid NOT NULL REFERENCES public.tower_users(user_id),approved_by uuid REFERENCES public.tower_users(user_id),
 created_at timestamptz NOT NULL DEFAULT now(),approved_at timestamptz,UNIQUE(service_id,reference)
);
CREATE TABLE IF NOT EXISTS public.tower_task_adjustment_lines (
 adjustment_id uuid NOT NULL REFERENCES public.tower_task_adjustments(adjustment_id),
 subscription_id uuid NOT NULL REFERENCES public.tower_service_subscriptions(subscription_id),
 amount numeric(16,2) NOT NULL CHECK(amount<>0),due_id uuid REFERENCES public.tower_finance_dues(due_id),
 PRIMARY KEY(adjustment_id,subscription_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_due_credits (
 adjustment_id uuid NOT NULL REFERENCES public.tower_task_adjustments(adjustment_id),
 due_id uuid NOT NULL REFERENCES public.tower_finance_dues(due_id),amount numeric(16,2) NOT NULL CHECK(amount>0),
 PRIMARY KEY(adjustment_id,due_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_credit_reversals (
 adjustment_id uuid NOT NULL REFERENCES public.tower_task_adjustments(adjustment_id),
 due_id uuid NOT NULL REFERENCES public.tower_finance_dues(due_id),amount numeric(16,2) NOT NULL CHECK(amount>0),PRIMARY KEY(adjustment_id,due_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_expenses (
 expense_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_id uuid NOT NULL REFERENCES public.tower_services(service_id),
 reference text NOT NULL,expense_date date NOT NULL DEFAULT current_date,description text NOT NULL CHECK(length(btrim(description))>0),
 amount numeric(16,2) NOT NULL CHECK(amount>0),recipient text NOT NULL DEFAULT '',evidence text NOT NULL DEFAULT '',
 funding text NOT NULL CHECK(funding IN ('UNPAID','PERSONAL','TASK')),
 state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN ('DRAFT','APPROVED','CANCELLED')),
 recorded_by uuid NOT NULL REFERENCES public.tower_users(user_id),approved_by uuid REFERENCES public.tower_users(user_id),
 paid_by uuid REFERENCES public.tower_users(user_id),paid_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(service_id,reference)
);
CREATE TABLE IF NOT EXISTS public.tower_task_expense_disbursements (
 expense_id uuid PRIMARY KEY REFERENCES public.tower_task_expenses(expense_id),
 account_id uuid NOT NULL REFERENCES public.tower_finance_accounts(account_id),
 holder_id uuid NOT NULL REFERENCES public.tower_users(user_id),amount numeric(16,2) NOT NULL CHECK(amount>0),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tower_task_credit_refunds (
 authorization_id uuid PRIMARY KEY REFERENCES public.tower_finance_refund_authorizations(refund_authorization_id),
 service_id uuid NOT NULL REFERENCES public.tower_services(service_id),refund_source text NOT NULL DEFAULT 'DUE_CREDIT' CHECK(refund_source IN ('DUE_CREDIT','ADVANCE'))
);
CREATE TABLE IF NOT EXISTS public.tower_task_advance_refund_allocations (
 authorization_id uuid NOT NULL REFERENCES public.tower_finance_refund_authorizations(refund_authorization_id),
 link_id uuid NOT NULL REFERENCES public.tower_finance_advance_subscription_links(link_id),
 advance_application_id uuid NOT NULL REFERENCES public.tower_finance_applications(application_id),
 amount numeric(16,2) NOT NULL CHECK(amount>0),PRIMARY KEY(authorization_id,link_id)
);
CREATE TABLE IF NOT EXISTS public.tower_task_donations (
 donation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_id uuid NOT NULL REFERENCES public.tower_services(service_id),
 receipt_id uuid NOT NULL UNIQUE REFERENCES public.tower_finance_receipts(receipt_id),
 application_id uuid NOT NULL UNIQUE REFERENCES public.tower_finance_applications(application_id),
 unit_id uuid NOT NULL REFERENCES public.tower_units(unit_id),amount numeric(16,2) NOT NULL CHECK(amount>0),
 reference text NOT NULL,note text NOT NULL DEFAULT '',received_by uuid NOT NULL REFERENCES public.tower_users(user_id),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(service_id,reference)
);
CREATE TABLE IF NOT EXISTS public.tower_task_donation_returns (
 return_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),donation_id uuid NOT NULL REFERENCES public.tower_task_donations(donation_id),
 account_id uuid NOT NULL REFERENCES public.tower_finance_accounts(account_id),unit_id uuid NOT NULL REFERENCES public.tower_units(unit_id),
 sender_id uuid NOT NULL REFERENCES public.tower_users(user_id),recipient_id uuid NOT NULL REFERENCES public.tower_users(user_id),
 amount numeric(16,2) NOT NULL CHECK(amount>0),reason text NOT NULL CHECK(length(btrim(reason))>0),
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','CONFIRMED','CANCELLED')),
 reference text NOT NULL UNIQUE,created_at timestamptz NOT NULL DEFAULT now(),confirmed_at timestamptz
);
-- Keep legacy one-due-per-period invariant, while uniquely identifying each new adjustment.
ALTER TABLE public.tower_finance_dues ADD COLUMN IF NOT EXISTS task_adjustment_id uuid REFERENCES public.tower_task_adjustments(adjustment_id);
DROP INDEX IF EXISTS public.tower_finance_subscription_due_once_idx;
CREATE UNIQUE INDEX tower_finance_subscription_due_once_idx ON public.tower_finance_dues(subscription_id,due_date) WHERE subscription_id IS NOT NULL AND task_adjustment_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS tower_task_adjustment_due_once_229 ON public.tower_finance_dues(subscription_id,task_adjustment_id) WHERE task_adjustment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tower_task_credits_due_229 ON public.tower_task_due_credits(due_id);
CREATE INDEX IF NOT EXISTS tower_task_reversals_due_229 ON public.tower_task_credit_reversals(due_id);
CREATE INDEX IF NOT EXISTS tower_task_snapshot_subscription_229 ON public.tower_task_allocation_snapshots(subscription_id);
CREATE INDEX IF NOT EXISTS tower_task_expenses_service_229 ON public.tower_task_expenses(service_id,state);
CREATE INDEX IF NOT EXISTS tower_task_disbursements_holder_229 ON public.tower_task_expense_disbursements(account_id,holder_id);
CREATE INDEX IF NOT EXISTS tower_task_refunds_service_229 ON public.tower_task_credit_refunds(service_id);
CREATE INDEX IF NOT EXISTS tower_task_advance_refunds_application_229 ON public.tower_task_advance_refund_allocations(advance_application_id);
CREATE INDEX IF NOT EXISTS tower_task_advance_refunds_link_229 ON public.tower_task_advance_refund_allocations(link_id);
CREATE INDEX IF NOT EXISTS tower_task_donation_returns_holder_229 ON public.tower_task_donation_returns(account_id,sender_id,state);
CREATE INDEX IF NOT EXISTS tower_task_donation_returns_source_229 ON public.tower_task_donation_returns(donation_id,state);
CREATE INDEX IF NOT EXISTS tower_task_adjustments_service_229 ON public.tower_task_adjustments(service_id,state);
-- New tables are private. Only session-authorized SECURITY DEFINER RPCs expose data.
DO $do$ DECLARE n text;BEGIN
 FOREACH n IN ARRAY ARRAY['tower_task_projects','tower_task_interests','tower_task_agreements','tower_task_allocation_snapshots','tower_task_adjustments','tower_task_adjustment_lines','tower_task_due_credits','tower_task_credit_reversals','tower_task_expenses','tower_task_expense_disbursements','tower_task_credit_refunds','tower_task_donations','tower_task_advance_refund_allocations','tower_task_donation_returns'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n);
  EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated,service_role',n);
 END LOOP;
END $do$;
CREATE OR REPLACE FUNCTION public.tower_task_due_amount_internal(p_due uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 SELECT d.amount-coalesce((SELECT sum(c.amount) FROM public.tower_task_due_credits c WHERE c.due_id=d.due_id),0)+coalesce((SELECT sum(c.amount) FROM public.tower_task_credit_reversals c WHERE c.due_id=d.due_id),0)
 FROM public.tower_finance_dues d WHERE d.due_id=p_due
$f$;
CREATE OR REPLACE FUNCTION public.tower_task_due_paid_raw_internal(p_due uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 SELECT coalesce((SELECT sum(ap.amount) FROM public.tower_finance_applications ap
 JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
 JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id AND r.receipt_status='POSTED'
 WHERE ap.due_id=p_due AND ap.application_kind='DUE'),0)
 +coalesce((SELECT sum(au.amount) FROM public.tower_finance_advance_uses au
 JOIN public.tower_finance_applications ap ON ap.application_id=au.advance_application_id
 JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id
 JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id AND r.receipt_status='POSTED'
 WHERE au.due_id=p_due),0)
$f$;
CREATE OR REPLACE FUNCTION public.tower_task_due_paid_internal(p_due uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 WITH target AS (SELECT * FROM public.tower_finance_dues WHERE due_id=p_due),
 refund AS (SELECT coalesce(sum(m.amount),0) amount FROM public.tower_finance_refund_authorizations a
 JOIN public.tower_task_credit_refunds tr ON tr.authorization_id=a.refund_authorization_id AND tr.refund_source='DUE_CREDIT'
 JOIN public.tower_finance_refund_movements rm ON rm.refund_authorization_id=a.refund_authorization_id
 JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id AND m.movement_status='CONFIRMED'
 WHERE a.subscription_id=(SELECT subscription_id FROM target)),
 paid AS (SELECT public.tower_task_due_paid_raw_internal(p_due) amount,
 (SELECT coalesce(sum(public.tower_task_due_paid_raw_internal(d.due_id)),0) FROM public.tower_finance_dues d,target t
 WHERE d.subscription_id=t.subscription_id AND d.status='OPEN' AND (d.due_date,d.due_id)>(t.due_date,t.due_id)) prior)
 SELECT paid.amount-greatest(0,least(paid.amount,refund.amount-paid.prior)) FROM paid,refund
$f$;
CREATE OR REPLACE FUNCTION public.tower_task_unused_advance_internal(p_sub uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 WITH links AS (SELECT coalesce(sum(l.amount),0) amount,coalesce(sum((SELECT coalesce(sum(u.amount),0) FROM public.tower_finance_advance_use_subscriptions x JOIN public.tower_finance_advance_uses u ON u.use_id=x.use_id WHERE x.link_id=l.link_id)),0) used
 FROM public.tower_finance_advance_subscription_links l JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id AND r.receipt_status='POSTED' WHERE l.subscription_id=p_sub),
 reserves AS (SELECT coalesce(sum(al.amount),0) amount FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations a ON a.refund_authorization_id=al.authorization_id AND a.authorization_status='APPROVED' WHERE a.subscription_id=p_sub),
 returned AS (SELECT coalesce(sum(m.amount),0) amount FROM public.tower_finance_refund_authorizations a JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=a.refund_authorization_id AND cr.refund_source='ADVANCE' JOIN public.tower_finance_refund_movements rm ON rm.refund_authorization_id=a.refund_authorization_id JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id AND m.movement_status='CONFIRMED' WHERE a.subscription_id=p_sub)
 SELECT jsonb_build_object('advance',greatest(0,links.amount-links.used-returned.amount),'advanceAvailable',greatest(0,links.amount-links.used-reserves.amount)) FROM links,reserves,returned
$f$;
CREATE OR REPLACE FUNCTION public.tower_task_subscription_balance_internal(p_sub uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
 WITH totals AS (SELECT coalesce(sum(public.tower_task_due_amount_internal(due_id)),0) due,
 coalesce(sum(public.tower_task_due_paid_internal(due_id)),0) paid,
 coalesce(sum(greatest(0,public.tower_task_due_amount_internal(due_id)-public.tower_task_due_paid_internal(due_id))),0) remaining
 FROM public.tower_finance_dues WHERE subscription_id=p_sub AND status='OPEN'), refunds AS (
 SELECT coalesce(sum(m.amount) FILTER(WHERE m.movement_status='CONFIRMED'),0) refunded,
 coalesce(sum(m.amount) FILTER(WHERE m.movement_status IN ('PENDING','DISPUTED')),0) pending
 FROM public.tower_finance_refund_authorizations a JOIN public.tower_task_credit_refunds tr ON tr.authorization_id=a.refund_authorization_id
 JOIN public.tower_finance_refund_movements rm ON rm.refund_authorization_id=a.refund_authorization_id
 JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE a.subscription_id=p_sub)
 SELECT jsonb_build_object('due',due,'paid',paid,'remaining',remaining,
 'refunded',refunded,'refundPending',pending,'credit',greatest(0,remaining+paid-due),
 'creditAvailable',greatest(0,paid-due-pending))||public.tower_task_unused_advance_internal(p_sub) FROM totals,refunds
$f$;
CREATE OR REPLACE FUNCTION public.tower_task_capture_snapshot_internal(p_service uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE account uuid;
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_task_allocation_snapshots WHERE service_id=p_service) THEN RETURN; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=p_service AND enrollment_status='FINALIZED') THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
 SELECT account_id INTO account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE';
 IF NOT FOUND THEN SELECT account_id INTO account FROM public.tower_finance_accounts WHERE account_kind='FUND' AND status='ACTIVE'; END IF;
 IF account IS NULL THEN RAISE EXCEPTION 'ACCOUNT_NOT_FOUND'; END IF;
 INSERT INTO public.tower_task_allocation_snapshots(service_id,subscription_id,unit_id,account_id,original_amount)
 SELECT sub.service_id,sub.subscription_id,sub.unit_id,account,coalesce(sum(d.amount),0)
 FROM public.tower_service_subscriptions sub LEFT JOIN public.tower_finance_dues d ON d.subscription_id=sub.subscription_id AND d.status='OPEN' AND d.task_adjustment_id IS NULL
 WHERE sub.service_id=p_service AND sub.status='ACTIVE' GROUP BY sub.service_id,sub.subscription_id,sub.unit_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'NO_ACTIVE_SUBSCRIBERS'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service AND d.account_id<>account AND d.status='OPEN') THEN RAISE EXCEPTION 'ACCOUNT_SERVICE_MISMATCH'; END IF;
END $f$;
-- Enrollment is forbidden at the database level while a project is only an idea.
CREATE OR REPLACE FUNCTION public.tower_task_enrollment_gate_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=NEW.service_id AND phase<>'PARTICIPATION') THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
 IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=NEW.service_id AND cardinality(target_units)>0 AND NOT NEW.unit_id=ANY(target_units)) THEN RAISE EXCEPTION 'UNIT_OUTSIDE_TASK_SCOPE'; END IF;
 IF NEW.status IN ('PENDING','ACTIVE') AND EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=NEW.service_id AND deadline<current_date) THEN RAISE EXCEPTION 'TASK_PARTICIPATION_DEADLINE_PASSED'; END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_enrollment_gate_229 ON public.tower_service_subscriptions;
CREATE TRIGGER tower_task_enrollment_gate_229 BEFORE INSERT OR UPDATE ON public.tower_service_subscriptions FOR EACH ROW EXECUTE FUNCTION public.tower_task_enrollment_gate_229();
CREATE OR REPLACE FUNCTION public.tower_task_project_read_229(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;admin boolean;account uuid;rows jsonb;exp jsonb;adjustments jsonb;own_interest boolean;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 admin:=a.role IN ('ADMIN','UNION');
 IF NOT admin AND a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL';
 IF NOT FOUND OR (NOT admin AND s.status<>'ACTIVE') THEN RAISE EXCEPTION 'TASK_NOT_FOUND'; END IF;
 IF NOT admin THEN
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE'
    WHERE m.unit_id=p_unit AND m.user_id=a.user_id AND m.ended_at IS NULL) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 END IF;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=p_service;
 SELECT account_id INTO account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE';
 IF (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN account:=NULL; END IF;
 SELECT interested INTO own_interest FROM public.tower_task_interests WHERE service_id=p_service AND unit_id=p_unit;
 SELECT coalesce(jsonb_agg(jsonb_build_object('subscriptionId',sub.subscription_id,'unitId',sub.unit_id,'unitNumber',u.unit_number,
  'status',sub.status,'agreement',CASE WHEN admin THEN (SELECT to_jsonb(ag) FROM public.tower_task_agreements ag WHERE ag.subscription_id=sub.subscription_id) ELSE NULL END,
  'balance',public.tower_task_subscription_balance_internal(sub.subscription_id)) ORDER BY u.unit_number),'[]') INTO rows
 FROM public.tower_service_subscriptions sub JOIN public.tower_units u ON u.unit_id=sub.unit_id
 WHERE sub.service_id=p_service AND (admin OR sub.unit_id=p_unit);
 SELECT coalesce(jsonb_agg(CASE WHEN admin THEN to_jsonb(e)||jsonb_build_object('disbursed',EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements ed WHERE ed.expense_id=e.expense_id)) ELSE jsonb_build_object('description',e.description,'amount',e.amount,'state',e.state) END ORDER BY e.created_at DESC),'[]') INTO exp FROM public.tower_task_expenses e
 WHERE e.service_id=p_service AND (admin OR e.state='APPROVED');
 SELECT coalesce(jsonb_agg(jsonb_build_object('adjustmentId',ad.adjustment_id,'amount',ad.amount,'reason',ad.reason,'state',ad.state,
 'createdAt',ad.created_at,'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object('subscriptionId',l.subscription_id,'unitNumber',u.unit_number,'amount',l.amount)),'[]')
 FROM public.tower_task_adjustment_lines l JOIN public.tower_service_subscriptions sub ON sub.subscription_id=l.subscription_id
 JOIN public.tower_units u ON u.unit_id=sub.unit_id WHERE l.adjustment_id=ad.adjustment_id AND (admin OR sub.unit_id=p_unit))) ORDER BY ad.created_at DESC),'[]') INTO adjustments
 FROM public.tower_task_adjustments ad WHERE ad.service_id=p_service AND (admin OR ad.state='APPROVED');
 RETURN jsonb_build_object('serviceId',p_service,'name',s.name,'totalBudget',s.total_budget,'enrollment',s.enrollment_status,
 'project',CASE WHEN p.service_id IS NULL THEN jsonb_build_object('phase','PARTICIPATION','version',1,'distribution','EQUAL') WHEN admin THEN to_jsonb(p) ELSE to_jsonb(p)-'agreed_amounts'-'creation_reference'-'creation_payload'-'updated_by'-'target_units' END,
 'eligible',admin OR coalesce(cardinality(p.target_units),0)=0 OR p_unit=ANY(p.target_units),
 'availableUnits',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',u.unit_id,'unitNumber',u.unit_number,'floor',u.floor) ORDER BY u.unit_number),'[]') FROM public.tower_units u WHERE u.status='ACTIVE') ELSE '[]'::jsonb END,
 'interested',coalesce(own_interest,false),'interestCount',(SELECT count(*) FROM public.tower_task_interests WHERE service_id=p_service AND interested AND (coalesce(cardinality(p.target_units),0)=0 OR unit_id=ANY(p.target_units))),
 'subscriptions',rows,'expenses',exp,'adjustments',adjustments,'canManage',admin,'canApproveCredit',a.role='UNION',
 'hasPersonalAccount',account IS NOT NULL,'holderAvailable',CASE WHEN admin AND account IS NOT NULL THEN public.tower_finance_holder_available_internal(account,a.user_id) ELSE NULL END,
 'refundAuthorizations',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('authorizationId',ra.refund_authorization_id,'subscriptionId',ra.subscription_id,'source',cr.refund_source,'amount',ra.max_amount-coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=ra.refund_authorization_id AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')),0))), '[]') FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=ra.refund_authorization_id WHERE cr.service_id=p_service AND ra.authorization_status='APPROVED') ELSE '[]'::jsonb END,
 'pendingSentRefunds',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('movementId',m.movement_id,'amount',m.amount)), '[]') FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE cr.service_id=p_service AND m.sender_user_id=a.user_id AND m.movement_status='PENDING') ELSE '[]'::jsonb END,
 'pendingRefunds',CASE WHEN NOT admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('movementId',m.movement_id,'amount',m.amount,'canConfirm',m.recipient_user_id=a.user_id)), '[]') FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE cr.service_id=p_service AND m.unit_id=p_unit AND m.movement_status='PENDING' AND m.recipient_user_id=a.user_id) ELSE '[]'::jsonb END,
 'execution',(SELECT jsonb_build_object('stage',w.stage,'percent',w.execution_percent,'date',w.execution_date) FROM public.tower_task_workflow w WHERE w.service_id=p_service),
 'donationTotal',(SELECT coalesce(sum(dn.amount-coalesce((SELECT sum(dr.amount) FROM public.tower_task_donation_returns dr WHERE dr.donation_id=dn.donation_id AND dr.state='CONFIRMED'),0)),0) FROM public.tower_task_donations dn JOIN public.tower_finance_receipts rr ON rr.receipt_id=dn.receipt_id AND rr.receipt_status='POSTED' WHERE dn.service_id=p_service),
 'donations',CASE WHEN admin THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('donationId',dn.donation_id,'unitNumber',un.unit_number,'amount',dn.amount,'available',dn.amount-coalesce((SELECT sum(dr.amount) FROM public.tower_task_donation_returns dr WHERE dr.donation_id=dn.donation_id AND dr.state IN ('PENDING','CONFIRMED')),0),'canReturn',dn.received_by=a.user_id)),'[]') FROM public.tower_task_donations dn JOIN public.tower_units un ON un.unit_id=dn.unit_id WHERE dn.service_id=p_service) ELSE '[]'::jsonb END,
 'donationReturns',(SELECT coalesce(jsonb_agg(jsonb_build_object('returnId',dr.return_id,'amount',dr.amount,'canConfirm',dr.recipient_id=a.user_id AND NOT admin,'canCancel',dr.sender_id=a.user_id AND admin)),'[]') FROM public.tower_task_donation_returns dr JOIN public.tower_task_donations dn ON dn.donation_id=dr.donation_id WHERE dn.service_id=p_service AND dr.state='PENDING' AND ((NOT admin AND dr.unit_id=p_unit AND dr.recipient_id=a.user_id) OR (admin AND dr.sender_id=a.user_id))),
 'actualExpenseTotal',(SELECT coalesce(sum(amount),0) FROM public.tower_task_expenses WHERE service_id=p_service AND state='APPROVED'),
 'unitId',CASE WHEN admin THEN NULL ELSE p_unit END);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_task_project_action_229(p_token text,p_action text,p_service uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;s public.tower_services;p public.tower_task_projects;v_id uuid;v_sub uuid;v_unit uuid;v_account uuid;
 v_receipt uuid;v_portion uuid;v_app uuid;
 v_amount numeric;v_ref text;v_reason text;v_data jsonb;v_row record;v_total numeric;v_remaining numeric;v_take numeric;v_due uuid;
 e public.tower_task_expenses;ad public.tower_task_adjustments;v_current jsonb;v_authorization uuid;v_manager uuid;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_PAYLOAD'; END IF;
 IF p_action IN ('interest','confirm_refund','confirm_donation_return') THEN
  IF a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 ELSE IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF; END IF;
 IF p_action='create' THEN
  v_ref:=p_payload->>'reference';
  IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 THEN RAISE EXCEPTION 'REFERENCE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('task-create:'||v_ref,0));
  SELECT service_id,creation_payload,updated_by INTO v_id,v_data,v_unit FROM public.tower_task_projects WHERE creation_reference=v_ref;
  IF FOUND THEN IF v_data IS DISTINCT FROM (p_payload-'reference') OR v_unit<>a.user_id THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;RETURN jsonb_build_object('serviceId',v_id,'replayed',true); END IF;
  IF coalesce(p_payload->>'name','')='' OR coalesce(p_payload->>'totalBudget','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_TASK_FIELDS'; END IF;
  v_data:=public.tower_service_finance_action(p_token,'save',jsonb_build_object('name',p_payload->>'name','description',coalesce(p_payload->>'description',''),
   'price',0,'billingTiming','POSTPAID','allowQuantity',false,'cancelable',false,'revenueKind','PERSONAL_SERVICE',
   'beneficiaryUserId',p_payload->>'beneficiaryUserId','serviceKind','ONE_TIME','pricingMode','SHARED_TOTAL','totalBudget',p_payload->>'totalBudget'));
  v_id:=(v_data->>'serviceId')::uuid;
  INSERT INTO public.tower_task_projects(service_id,creation_reference,creation_payload,phase,scope_text,updated_by) VALUES(v_id,v_ref,p_payload-'reference','PROPOSAL',coalesce(p_payload->>'scope',''),a.user_id);
  RETURN jsonb_build_object('serviceId',v_id);
 END IF;
 SELECT * INTO s FROM public.tower_services WHERE service_id=p_service FOR UPDATE;
 IF NOT FOUND OR s.service_kind<>'ONE_TIME' OR s.pricing_mode<>'SHARED_TOTAL' THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 INSERT INTO public.tower_task_projects(service_id,updated_by) VALUES(p_service,a.user_id) ON CONFLICT DO NOTHING;
 SELECT * INTO p FROM public.tower_task_projects WHERE service_id=p_service FOR UPDATE;
 IF p.phase='FINANCIAL_CLOSED' AND p_action='close_financial' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
 IF p.phase IN ('CANCELLED','FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
 IF p_action='confirm_donation_return' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  PERFORM 1 FROM public.tower_task_donation_returns dr JOIN public.tower_task_donations dn ON dn.donation_id=dr.donation_id JOIN public.tower_members mb ON mb.unit_id=dr.unit_id AND mb.user_id=a.user_id AND mb.member_role='MANAGER' AND mb.ended_at IS NULL JOIN public.tower_units un ON un.unit_id=mb.unit_id AND un.status='ACTIVE'
   WHERE dr.return_id=(p_payload->>'returnId')::uuid AND dn.service_id=p_service AND dr.unit_id=v_unit AND dr.recipient_id=a.user_id AND dr.state IN ('PENDING','CONFIRMED') FOR UPDATE OF dr;
  IF NOT FOUND OR (SELECT count(*) FROM public.tower_members WHERE unit_id=v_unit AND member_role='MANAGER' AND ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'REFUND_ONLY_CURRENT_UNIT_MANAGER'; END IF;
  UPDATE public.tower_task_donation_returns SET state='CONFIRMED',confirmed_at=now() WHERE return_id=(p_payload->>'returnId')::uuid AND state='PENDING';
 ELSIF p_action='confirm_refund' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.tower_finance_cash_movements m JOIN public.tower_finance_refund_movements rm ON rm.movement_id=m.movement_id JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id JOIN public.tower_members mb ON mb.unit_id=m.unit_id AND mb.user_id=a.user_id AND mb.member_role='MANAGER' AND mb.ended_at IS NULL JOIN public.tower_units un ON un.unit_id=m.unit_id AND un.status='ACTIVE'
   WHERE cr.service_id=p_service AND m.unit_id=v_unit AND m.movement_id=(p_payload->>'movementId')::uuid AND m.recipient_user_id=a.user_id) THEN RAISE EXCEPTION 'REFUND_ONLY_CURRENT_UNIT_MANAGER'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_finance_cash_movements WHERE movement_id=(p_payload->>'movementId')::uuid AND movement_status='CONFIRMED') THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
  v_data:=public.tower_finance_refund_action(p_token,'confirm',jsonb_build_object('movementId',p_payload->>'movementId'));
 ELSIF p_action='interest' THEN
  v_unit:=(p_payload->>'unitId')::uuid;
  IF s.status<>'ACTIVE' OR p.phase<>'PROPOSAL' THEN RAISE EXCEPTION 'NOT_A_PROPOSAL'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE'
   WHERE m.user_id=a.user_id AND m.unit_id=v_unit AND m.ended_at IS NULL) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
  IF cardinality(p.target_units)>0 AND NOT v_unit=ANY(p.target_units) THEN RAISE EXCEPTION 'UNIT_OUTSIDE_TASK_SCOPE'; END IF;
  IF jsonb_typeof(p_payload->'interested')<>'boolean' THEN RAISE EXCEPTION 'INVALID_INTEREST'; END IF;
  INSERT INTO public.tower_task_interests(service_id,unit_id,interested,recorded_by) VALUES(p_service,v_unit,(p_payload->>'interested')::boolean,a.user_id)
   ON CONFLICT(service_id,unit_id) DO UPDATE SET interested=excluded.interested,recorded_by=a.user_id,recorded_at=now();
 ELSIF p_action IN ('terms','publish','cancel') THEN
  IF coalesce((p_payload->>'version')::bigint,-1)<>p.version THEN RAISE EXCEPTION 'TASK_CHANGED_REFRESH'; END IF;
  IF s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'TERMS_LOCKED'; END IF;
  IF p_action='terms' THEN
   IF coalesce(p_payload->>'distribution','') NOT IN ('EQUAL','CUSTOM') OR jsonb_typeof(p_payload->'agreedAmounts')<>'array' THEN RAISE EXCEPTION 'INVALID_DISTRIBUTION'; END IF;
   IF length(coalesce(p_payload->>'scope',''))>4000 OR length(coalesce(p_payload->>'policy',''))>4000 THEN RAISE EXCEPTION 'TEXT_TOO_LONG'; END IF;
   IF coalesce(p_payload->>'minimumStartAmount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_START_AMOUNT'; END IF;
   IF p_payload->>'distribution'='CUSTOM' AND (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN RAISE EXCEPTION 'DEDICATED_TASK_ACCOUNT_REQUIRED'; END IF;
   IF p_payload ? 'targetUnits' THEN
    IF jsonb_typeof(p_payload->'targetUnits')<>'array' THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_payload->'targetUnits') x(value) WHERE NOT EXISTS(SELECT 1 FROM public.tower_units u WHERE u.unit_id=x.value::uuid AND u.status='ACTIVE')) THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
    IF jsonb_array_length(p_payload->'targetUnits')>0 AND EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status IN ('ACTIVE','PENDING') AND NOT sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'targetUnits'))) THEN RAISE EXCEPTION 'EXISTING_PARTICIPANT_OUTSIDE_SCOPE'; END IF;
   END IF;
   UPDATE public.tower_task_projects SET target_units=CASE WHEN p_payload ? 'targetUnits' THEN ARRAY(SELECT DISTINCT value::uuid FROM jsonb_array_elements_text(p_payload->'targetUnits')) ELSE target_units END,scope_text=p_payload->>'scope',policy_text=p_payload->>'policy',deadline=nullif(p_payload->>'deadline','')::date,
    distribution=p_payload->>'distribution',agreed_amounts=p_payload->'agreedAmounts',minimum_start_amount=(p_payload->>'minimumStartAmount')::numeric WHERE service_id=p_service;
  ELSIF p_action='publish' THEN
   IF p.phase<>'PROPOSAL' OR btrim(p.scope_text)='' OR btrim(p.policy_text)='' THEN RAISE EXCEPTION 'TASK_TERMS_REQUIRED'; END IF;
   IF p.deadline IS NULL OR p.deadline<current_date THEN RAISE EXCEPTION 'VALID_DEADLINE_REQUIRED'; END IF;
   UPDATE public.tower_task_projects SET phase='PARTICIPATION' WHERE service_id=p_service;
  ELSE
   IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_finance_accounts ac JOIN public.tower_finance_receipt_portions rp ON rp.account_id=ac.account_id WHERE ac.service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_task_fund_contributions WHERE service_id=p_service)
    OR EXISTS(SELECT 1 FROM public.tower_task_expenses WHERE service_id=p_service AND state<>'CANCELLED')
   THEN RAISE EXCEPTION 'CANCELLATION_REQUIRES_FINANCIAL_SETTLEMENT'; END IF;
   UPDATE public.tower_task_projects SET phase='CANCELLED' WHERE service_id=p_service;
  END IF;
 ELSIF p_action='enroll' THEN
  IF p.phase<>'PARTICIPATION' OR s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'ENROLLMENT_CLOSED'; END IF;
  IF jsonb_typeof(p_payload->'unitIds')<>'array' OR jsonb_array_length(p_payload->'unitIds') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  IF coalesce(p_payload->>'source','') NOT IN ('WHATSAPP','MEETING','PHONE','OTHER','APP') OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_AGREEMENT'; END IF;
  IF (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_payload->'unitIds'))<>jsonb_array_length(p_payload->'unitIds') THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
  v_data:=public.tower_add_service_subscribers(p_token,jsonb_build_object('serviceId',p_service,'unitIds',p_payload->'unitIds','quantity',1));
  FOR v_row IN SELECT sub.subscription_id FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status='ACTIVE' AND sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds')) LOOP
   INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(v_row.subscription_id,p_payload->>'source',coalesce(p_payload->>'note',''),a.user_id) ON CONFLICT DO NOTHING;
  END LOOP;
  IF (SELECT count(*) FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND sub.status='ACTIVE' AND sub.unit_id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_payload->'unitIds')))<>jsonb_array_length(p_payload->'unitIds') THEN RAISE EXCEPTION 'ENROLLMENT_RESULT_MISMATCH'; END IF;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_DIRECT_AGREEMENT','SERVICE',p_service::text);
  RETURN v_data;
 ELSIF p_action='preview' THEN
  IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
  v_total:=s.total_budget-coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0);
  IF s.enrollment_status='FINALIZED' AND EXISTS(SELECT 1 FROM public.tower_task_allocation_snapshots WHERE service_id=p_service) THEN
   SELECT jsonb_agg(jsonb_build_object('unitId',unit_id,'subscriptionId',subscription_id,'amount',original_amount) ORDER BY unit_id) INTO v_data FROM public.tower_task_allocation_snapshots WHERE service_id=p_service;
  ELSIF v_total=0 THEN
   SELECT jsonb_agg(jsonb_build_object('unitId',unit_id,'subscriptionId',subscription_id,'amount',0) ORDER BY unit_id) INTO v_data FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE';
  ELSIF p.distribution='CUSTOM' THEN
   IF jsonb_array_length(p.agreed_amounts)<>(SELECT count(*) FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE') OR (SELECT count(DISTINCT x->>'subscriptionId') FROM jsonb_array_elements(p.agreed_amounts) x)<>jsonb_array_length(p.agreed_amounts) THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(p.agreed_amounts) x WHERE coalesce(x->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.subscription_id=(x->>'subscriptionId')::uuid AND sub.service_id=p_service AND sub.status='ACTIVE')) THEN RAISE EXCEPTION 'INVALID_AGREED_AMOUNTS'; END IF;
   IF (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(p.agreed_amounts) x)<>v_total THEN RAISE EXCEPTION 'ALLOCATION_SUM_MISMATCH'; END IF;
   SELECT jsonb_agg(jsonb_build_object('unitId',sub.unit_id,'subscriptionId',sub.subscription_id,'amount',(x->>'amount')::numeric) ORDER BY sub.unit_id) INTO v_data FROM jsonb_array_elements(p.agreed_amounts) x JOIN public.tower_service_subscriptions sub ON sub.subscription_id=(x->>'subscriptionId')::uuid;
  ELSE RETURN public.tower_service_shared_allocation_action(p_token,'preview',p_service); END IF;
  IF v_data IS NULL THEN RAISE EXCEPTION 'NO_ACTIVE_SUBSCRIBERS'; END IF;
  RETURN jsonb_build_object('status',s.enrollment_status,'subscriberCount',jsonb_array_length(v_data),'totalBudget',s.total_budget,'allocations',v_data);
 ELSIF p_action='agreement' THEN
  IF p.phase<>'PARTICIPATION' OR s.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'ENROLLMENT_CLOSED'; END IF;
  v_sub:=(p_payload->>'subscriptionId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE subscription_id=v_sub AND service_id=p_service AND status='ACTIVE') THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  IF coalesce(p_payload->>'source','') NOT IN ('APP','WHATSAPP','MEETING','PHONE','OTHER') OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_AGREEMENT'; END IF;
  INSERT INTO public.tower_task_agreements(subscription_id,source,note,recorded_by) VALUES(v_sub,p_payload->>'source',coalesce(p_payload->>'note',''),a.user_id)
   ON CONFLICT(subscription_id) DO UPDATE SET source=excluded.source,note=excluded.note,recorded_by=a.user_id,recorded_at=now();
 ELSE
  IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
  -- Serialize with receipts and transfers before changing debt/custody.
  PERFORM 1 FROM public.tower_units u WHERE u.unit_id IN (SELECT unit_id FROM public.tower_service_subscriptions WHERE service_id=p_service) ORDER BY u.unit_id FOR UPDATE;
  SELECT account_id INTO v_account FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE' FOR UPDATE;
  IF v_account IS NULL AND p_action='finalize' AND p.distribution='EQUAL' THEN
   v_data:=public.tower_service_shared_allocation_action(p_token,'finalize',p_service);
   PERFORM public.tower_task_capture_snapshot_internal(p_service);RETURN v_data;
  END IF;
  IF NOT FOUND OR (SELECT count(*) FROM public.tower_finance_accounts WHERE service_id=p_service AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE')<>1 THEN RAISE EXCEPTION 'DEDICATED_TASK_ACCOUNT_REQUIRED'; END IF;
  IF p_action IN ('adjustment_draft','adjustment_approve') AND (p_action='adjustment_draft' OR EXISTS(SELECT 1 FROM public.tower_task_adjustments WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND state='DRAFT')) AND EXISTS(
   SELECT 1 FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=ra.refund_authorization_id
   WHERE cr.service_id=p_service AND ra.authorization_status='APPROVED' AND ra.max_amount>coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=ra.refund_authorization_id AND m.movement_status='CONFIRMED'),0)
  ) THEN RAISE EXCEPTION 'SETTLE_AUTHORIZED_REFUNDS_FIRST'; END IF;
  IF p_action='finalize' THEN
   IF p.phase<>'PARTICIPATION' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
   IF s.enrollment_status='FINALIZED' THEN PERFORM public.tower_task_capture_snapshot_internal(p_service);RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF s.enrollment_status='CLOSED' AND s.total_budget=coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0) THEN
    IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
    UPDATE public.tower_services SET enrollment_status='FINALIZED',updated_at=now() WHERE service_id=p_service;
   ELSIF p.distribution='EQUAL' THEN
    v_data:=public.tower_service_shared_allocation_action(p_token,'finalize',p_service);
   ELSE
    IF s.enrollment_status<>'CLOSED' THEN RAISE EXCEPTION 'ENROLLMENT_MUST_BE_CLOSED'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='PENDING') THEN RAISE EXCEPTION 'PENDING_SUBSCRIPTIONS_EXIST'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service) THEN RAISE EXCEPTION 'SERVICE_ALREADY_HAS_DUES'; END IF;
    IF jsonb_array_length(p.agreed_amounts)=0 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p.agreed_amounts) x WHERE coalesce(x->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR (x->>'amount')::numeric<0) THEN RAISE EXCEPTION 'INVALID_AGREED_AMOUNTS'; END IF;
    IF (SELECT count(DISTINCT x->>'subscriptionId') FROM jsonb_array_elements(p.agreed_amounts) x)<>jsonb_array_length(p.agreed_amounts)
     OR jsonb_array_length(p.agreed_amounts)<>(SELECT count(*) FROM public.tower_service_subscriptions WHERE service_id=p_service AND status='ACTIVE') THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
    v_total:=s.total_budget-coalesce((SELECT amount FROM public.tower_task_fund_contributions WHERE service_id=p_service),0);
    IF (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(p.agreed_amounts) x)<>v_total THEN RAISE EXCEPTION 'ALLOCATION_SUM_MISMATCH'; END IF;
    FOR v_row IN SELECT value x FROM jsonb_array_elements(p.agreed_amounts) LOOP
     SELECT unit_id INTO v_unit FROM public.tower_service_subscriptions WHERE subscription_id=(v_row.x->>'subscriptionId')::uuid AND service_id=p_service AND status='ACTIVE';
     IF NOT FOUND THEN RAISE EXCEPTION 'PARTICIPANTS_CHANGED'; END IF;
     IF (v_row.x->>'amount')::numeric>0 THEN INSERT INTO public.tower_finance_dues(unit_id,account_id,subscription_id,due_date,amount,status) VALUES(v_unit,v_account,(v_row.x->>'subscriptionId')::uuid,current_date,(v_row.x->>'amount')::numeric,'OPEN'); END IF;
    END LOOP;
    UPDATE public.tower_services SET enrollment_status='FINALIZED',updated_at=now() WHERE service_id=p_service;
   END IF;
   PERFORM public.tower_task_capture_snapshot_internal(p_service);
   FOR v_row IN SELECT DISTINCT unit_id FROM public.tower_task_allocation_snapshots WHERE service_id=p_service ORDER BY unit_id LOOP PERFORM public.tower_finance_apply_advances_internal(v_row.unit_id,v_account); END LOOP;
  ELSIF p_action='collect' THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   v_unit:=(p_payload->>'unitId')::uuid;
   SELECT subscription_id INTO v_sub FROM public.tower_service_subscriptions WHERE service_id=p_service AND unit_id=v_unit AND status='ACTIVE';
   IF NOT FOUND THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE'; END IF;
   v_ref:=p_payload->>'reference';
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 80 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_RECEIPT_FIELDS'; END IF;
   v_data:=public.tower_finance_personal_receipt_action(p_token,jsonb_build_object('unitId',v_unit,'amount',p_payload->>'amount','portions',jsonb_build_array(jsonb_build_object('account_id',v_account,'amount',p_payload->>'amount')),'externalReference','task:'||p_service::text||':'||v_ref));
   v_receipt:=(v_data->>'receiptId')::uuid;
   FOR v_row IN SELECT ap.application_id,ap.amount FROM public.tower_finance_applications ap JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id WHERE rp.receipt_id=v_receipt AND ap.application_kind='ADVANCE' LOOP
    IF NOT EXISTS(SELECT 1 FROM public.tower_finance_advance_subscription_links WHERE advance_application_id=v_row.application_id AND subscription_id=v_sub) THEN
     INSERT INTO public.tower_finance_advance_subscription_links(advance_application_id,subscription_id,amount,linked_by) VALUES(v_row.application_id,v_sub,v_row.amount,a.user_id);
    END IF;
   END LOOP;
   PERFORM public.tower_finance_apply_advances_internal(v_unit,v_account);
  ELSIF p_action IN ('donation_return','cancel_donation_return') THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   IF p_action='cancel_donation_return' THEN
    UPDATE public.tower_task_donation_returns dr SET state='CANCELLED' FROM public.tower_task_donations dn WHERE dr.return_id=(p_payload->>'returnId')::uuid AND dn.donation_id=dr.donation_id AND dn.service_id=p_service AND dr.sender_id=a.user_id AND dr.state='PENDING';
    IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_NOT_PENDING'; END IF;
   ELSE
    v_ref:=p_payload->>'reference';v_reason:=btrim(coalesce(p_payload->>'reason',''));
    IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR length(v_reason) NOT BETWEEN 1 AND 2000 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_DONATION_RETURN'; END IF;
    v_id:=(p_payload->>'donationId')::uuid;v_amount:=(p_payload->>'amount')::numeric;
    IF EXISTS(SELECT 1 FROM public.tower_task_donation_returns WHERE reference=v_ref AND donation_id=v_id AND amount=v_amount AND reason=v_reason AND sender_id=a.user_id) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
    SELECT dn.unit_id,dn.amount INTO v_unit,v_total FROM public.tower_task_donations dn JOIN public.tower_finance_receipts rr ON rr.receipt_id=dn.receipt_id AND rr.receipt_status='POSTED' WHERE dn.donation_id=v_id AND dn.service_id=p_service AND dn.received_by=a.user_id FOR UPDATE OF dn;
    IF NOT FOUND THEN RAISE EXCEPTION 'ONLY_DONATION_COLLECTOR_CAN_RETURN'; END IF;
    IF v_amount<=0 OR v_amount>v_total-coalesce((SELECT sum(amount) FROM public.tower_task_donation_returns WHERE donation_id=v_id AND state IN ('PENDING','CONFIRMED')),0) THEN RAISE EXCEPTION 'RETURN_EXCEEDS_DONATION'; END IF;
    IF (SELECT count(*) FROM public.tower_members mb JOIN public.tower_users us ON us.user_id=mb.user_id AND us.role='RESIDENT' AND us.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
   SELECT mb.user_id INTO v_manager FROM public.tower_members mb JOIN public.tower_users usr ON usr.user_id=mb.user_id AND usr.role='RESIDENT' AND usr.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL;
    IF v_manager IS NULL OR v_manager=a.user_id THEN RAISE EXCEPTION 'INDEPENDENT_UNIT_MANAGER_REQUIRED'; END IF;
    IF v_amount>public.tower_finance_holder_available_internal(v_account,a.user_id) THEN RAISE EXCEPTION 'INSUFFICIENT_HOLDER_BALANCE'; END IF;
    INSERT INTO public.tower_task_donation_returns(donation_id,account_id,unit_id,sender_id,recipient_id,amount,reason,reference) VALUES(v_id,v_account,v_unit,a.user_id,v_manager,v_amount,v_reason,v_ref);
   END IF;
  ELSIF p_action='donation' THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   v_ref:=p_payload->>'reference';v_unit:=(p_payload->>'unitId')::uuid;
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR coalesce(p_payload->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' OR length(coalesce(p_payload->>'note',''))>2000 THEN RAISE EXCEPTION 'INVALID_DONATION'; END IF;
   v_amount:=(p_payload->>'amount')::numeric;IF v_amount<=0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   SELECT donation_id,amount,unit_id,note INTO v_id,v_total,v_sub,v_reason FROM public.tower_task_donations WHERE service_id=p_service AND reference=v_ref;
   IF FOUND THEN
    IF (v_total,v_sub,v_reason) IS DISTINCT FROM (v_amount,v_unit,coalesce(p_payload->>'note','')) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
    RETURN jsonb_build_object('success',true,'replayed',true);
   END IF;
   PERFORM 1 FROM public.tower_units WHERE unit_id=v_unit AND status='ACTIVE' FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_UNIT_IDS'; END IF;
   INSERT INTO public.tower_finance_receipts(unit_id,collector_id,amount,external_reference) VALUES(v_unit,a.user_id,v_amount,'task-donation:'||p_service::text||':'||v_ref) RETURNING receipt_id INTO v_receipt;
   INSERT INTO public.tower_finance_receipt_portions(receipt_id,account_id,amount) VALUES(v_receipt,v_account,v_amount) RETURNING portion_id INTO v_portion;
   INSERT INTO public.tower_finance_applications(portion_id,due_id,amount,application_kind) VALUES(v_portion,NULL,v_amount,'ADVANCE') RETURNING application_id INTO v_app;
   INSERT INTO public.tower_task_donations(service_id,receipt_id,application_id,unit_id,amount,reference,note,received_by) VALUES(p_service,v_receipt,v_app,v_unit,v_amount,v_ref,coalesce(p_payload->>'note',''),a.user_id);
  ELSIF p_action IN ('expense_draft','adjustment_draft') THEN
   v_ref:=p_payload->>'reference';v_reason:=btrim(coalesce(p_payload->>'description',p_payload->>'reason',''));
   IF coalesce(length(v_ref),0) NOT BETWEEN 16 AND 128 OR length(v_reason) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'REFERENCE_AND_REASON_REQUIRED'; END IF;
   IF coalesce(p_payload->>'amount','') !~ '^-?[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   v_amount:=(p_payload->>'amount')::numeric;
   IF v_amount=0 OR abs(v_amount)>999999999999.99 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
   IF p_action='expense_draft' THEN
    IF v_amount<0 OR coalesce(p_payload->>'funding','') NOT IN ('UNPAID','PERSONAL','TASK') OR length(coalesce(p_payload->>'evidence',''))>2000 OR length(coalesce(p_payload->>'recipient',''))>500 THEN RAISE EXCEPTION 'INVALID_EXPENSE'; END IF;
    SELECT * INTO e FROM public.tower_task_expenses WHERE service_id=p_service AND reference=v_ref;
    IF FOUND THEN
     IF (e.amount,e.description,e.funding,e.recipient,e.evidence,e.recorded_by,e.expense_date) IS DISTINCT FROM (v_amount,v_reason,p_payload->>'funding',coalesce(p_payload->>'recipient',''),coalesce(p_payload->>'evidence',''),a.user_id,coalesce(nullif(p_payload->>'date','')::date,current_date)) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
     RETURN jsonb_build_object('expenseId',e.expense_id,'replayed',true);
    END IF;
    INSERT INTO public.tower_task_expenses(service_id,reference,amount,description,funding,recipient,evidence,recorded_by,expense_date)
     VALUES(p_service,v_ref,v_amount,v_reason,p_payload->>'funding',coalesce(p_payload->>'recipient',''),coalesce(p_payload->>'evidence',''),a.user_id,coalesce(nullif(p_payload->>'date','')::date,current_date)) RETURNING expense_id INTO v_id;
   ELSE
    IF s.enrollment_status<>'FINALIZED' THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
    PERFORM public.tower_task_capture_snapshot_internal(p_service);
    IF p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)=0 THEN RAISE EXCEPTION 'CUSTOM_ZERO_BASE_REQUIRES_NEW_AGREEMENT'; END IF;
    SELECT * INTO ad FROM public.tower_task_adjustments WHERE service_id=p_service AND reference=v_ref;
    IF FOUND THEN
     IF (ad.amount,ad.reason,ad.proposed_by) IS DISTINCT FROM (v_amount,v_reason,a.user_id) THEN RAISE EXCEPTION 'REFERENCE_CONFLICT'; END IF;
     RETURN jsonb_build_object('adjustmentId',ad.adjustment_id,'replayed',true);
    END IF;
    INSERT INTO public.tower_task_adjustments(service_id,reference,amount,reason,proposed_by) VALUES(p_service,v_ref,v_amount,v_reason,a.user_id) RETURNING adjustment_id INTO v_id;
    -- Largest-remainder apportionment in integer cents; stable tie-break by unit UUID.
    INSERT INTO public.tower_task_adjustment_lines(adjustment_id,subscription_id,amount)
    WITH weights AS (SELECT x.*,CASE WHEN p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)>0 THEN original_amount ELSE 1 END weight,sum(CASE WHEN p.distribution='CUSTOM' AND (SELECT sum(original_amount) FROM public.tower_task_allocation_snapshots WHERE service_id=p_service)>0 THEN original_amount ELSE 1 END) OVER() total FROM public.tower_task_allocation_snapshots x WHERE service_id=p_service),
    raw AS (SELECT *,abs(v_amount)*100*weight/total exact_cents FROM weights),
    ranked AS (SELECT *,floor(exact_cents) base,row_number() OVER(ORDER BY exact_cents-floor(exact_cents) DESC,unit_id) rn,
       abs(v_amount)*100-sum(floor(exact_cents)) OVER() extras FROM raw)
    SELECT v_id,subscription_id,sign(v_amount)*(base+CASE WHEN rn<=extras THEN 1 ELSE 0 END)/100 FROM ranked
    WHERE base+CASE WHEN rn<=extras THEN 1 ELSE 0 END>0;
   END IF;
  ELSIF p_action IN ('expense_cancel','adjustment_cancel') THEN
   IF p_action='expense_cancel' THEN
    UPDATE public.tower_task_expenses SET state='CANCELLED' WHERE expense_id=(p_payload->>'expenseId')::uuid AND service_id=p_service AND state='DRAFT';
   ELSE
    UPDATE public.tower_task_adjustments SET state='CANCELLED' WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND service_id=p_service AND state='DRAFT';
   END IF;
   IF NOT FOUND THEN RAISE EXCEPTION 'ONLY_DRAFT_CAN_BE_CANCELLED'; END IF;
  ELSIF p_action IN ('expense_approve','expense_pay') THEN
   SELECT * INTO e FROM public.tower_task_expenses WHERE expense_id=(p_payload->>'expenseId')::uuid AND service_id=p_service FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
   IF p_action='expense_approve' AND e.state='APPROVED' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF p_action='expense_pay' AND EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements WHERE expense_id=e.expense_id) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF e.state='CANCELLED' THEN RAISE EXCEPTION 'EXPENSE_CANCELLED'; END IF;
   IF p_action='expense_pay' AND e.state<>'APPROVED' THEN RAISE EXCEPTION 'EXPENSE_NOT_APPROVED'; END IF;
   IF e.funding='TASK' AND p_action='expense_approve' AND e.recorded_by<>a.user_id THEN RAISE EXCEPTION 'ONLY_RECORDED_HOLDER_CAN_CONFIRM_EXPENSE'; END IF;
   IF e.funding='TASK' OR p_action='expense_pay' THEN
    IF e.amount>public.tower_finance_holder_available_internal(v_account,a.user_id) THEN RAISE EXCEPTION 'INSUFFICIENT_HOLDER_BALANCE'; END IF;
    INSERT INTO public.tower_task_expense_disbursements(expense_id,account_id,holder_id,amount) VALUES(e.expense_id,v_account,a.user_id,e.amount);
   END IF;
   UPDATE public.tower_task_expenses SET state='APPROVED',approved_by=coalesce(approved_by,a.user_id),
    paid_by=CASE WHEN funding='PERSONAL' THEN recorded_by WHEN funding='TASK' OR p_action='expense_pay' THEN a.user_id ELSE NULL END,
    paid_at=CASE WHEN funding IN ('PERSONAL','TASK') OR p_action='expense_pay' THEN now() ELSE NULL END WHERE expense_id=e.expense_id;
  ELSIF p_action='adjustment_approve' THEN
   SELECT * INTO ad FROM public.tower_task_adjustments WHERE adjustment_id=(p_payload->>'adjustmentId')::uuid AND service_id=p_service FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'ADJUSTMENT_NOT_FOUND'; END IF;
   IF ad.state='CANCELLED' THEN RAISE EXCEPTION 'ADJUSTMENT_CANCELLED'; END IF;
   IF ad.state='APPROVED' THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF ad.amount<0 AND a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   FOR v_row IN SELECT l.*,sn.unit_id FROM public.tower_task_adjustment_lines l JOIN public.tower_task_allocation_snapshots sn ON sn.service_id=p_service AND sn.subscription_id=l.subscription_id WHERE l.adjustment_id=ad.adjustment_id ORDER BY sn.unit_id LOOP
    IF v_row.amount>0 THEN
     v_remaining:=v_row.amount;
     -- Consume outstanding credit before recreating any collectible debt.
     FOR v_data IN SELECT jsonb_build_object('dueId',d.due_id,'amount',least(d.amount-public.tower_task_due_amount_internal(d.due_id),greatest(0,public.tower_task_due_paid_internal(d.due_id)-public.tower_task_due_amount_internal(d.due_id))))
       FROM public.tower_finance_dues d WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date,due_id LOOP
      v_take:=least(v_remaining,(v_data->>'amount')::numeric);
      IF v_take>0 THEN INSERT INTO public.tower_task_credit_reversals(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take);v_remaining:=v_remaining-v_take; END IF;
      EXIT WHEN v_remaining=0;
     END LOOP;
     IF v_remaining>0 THEN
      FOR v_data IN SELECT jsonb_build_object('dueId',d.due_id,'amount',d.amount-public.tower_task_due_amount_internal(d.due_id)) FROM public.tower_finance_dues d WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date,due_id LOOP
       v_take:=least(v_remaining,(v_data->>'amount')::numeric);
       IF v_take>0 THEN INSERT INTO public.tower_task_credit_reversals(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take) ON CONFLICT(adjustment_id,due_id) DO UPDATE SET amount=tower_task_credit_reversals.amount+excluded.amount;v_remaining:=v_remaining-v_take; END IF;
       EXIT WHEN v_remaining=0;
      END LOOP;
     END IF;
     IF v_remaining>0 THEN
      INSERT INTO public.tower_finance_dues(unit_id,account_id,subscription_id,due_date,amount,status,task_adjustment_id) VALUES(v_row.unit_id,v_account,v_row.subscription_id,current_date,v_remaining,'OPEN',ad.adjustment_id) RETURNING due_id INTO v_due;
      UPDATE public.tower_task_adjustment_lines SET due_id=v_due WHERE adjustment_id=ad.adjustment_id AND subscription_id=v_row.subscription_id;
     END IF;
     -- Apply eligible advances through the existing attribution-aware internal routine.
     PERFORM public.tower_finance_apply_advances_internal(v_row.unit_id,v_account);
    ELSE
     v_remaining:=-v_row.amount;
     IF v_remaining>(SELECT coalesce(sum(public.tower_task_due_amount_internal(due_id)),0) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN') THEN RAISE EXCEPTION 'CREDIT_EXCEEDS_APPROVED_DUES'; END IF;
     -- First reduce unpaid debt, then record credit against amounts already paid.
     FOR v_data IN SELECT jsonb_build_object('dueId',due_id,'amount',greatest(0,public.tower_task_due_amount_internal(due_id)-public.tower_task_due_paid_internal(due_id))) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date DESC,due_id DESC LOOP
      v_take:=least(v_remaining,(v_data->>'amount')::numeric);
      IF v_take>0 THEN INSERT INTO public.tower_task_due_credits(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take);v_remaining:=v_remaining-v_take; END IF;
      EXIT WHEN v_remaining=0;
     END LOOP;
     IF v_remaining>0 THEN
      FOR v_data IN SELECT jsonb_build_object('dueId',due_id,'amount',public.tower_task_due_amount_internal(due_id)) FROM public.tower_finance_dues WHERE subscription_id=v_row.subscription_id AND status='OPEN' ORDER BY due_date DESC,due_id DESC LOOP
       v_take:=least(v_remaining,(v_data->>'amount')::numeric);
       IF v_take>0 THEN INSERT INTO public.tower_task_due_credits(adjustment_id,due_id,amount) VALUES(ad.adjustment_id,(v_data->>'dueId')::uuid,v_take) ON CONFLICT(adjustment_id,due_id) DO UPDATE SET amount=tower_task_due_credits.amount+excluded.amount;v_remaining:=v_remaining-v_take; END IF;
       EXIT WHEN v_remaining=0;
      END LOOP;
     END IF;
    END IF;
   END LOOP;
   UPDATE public.tower_task_adjustments SET state='APPROVED',approved_by=a.user_id,approved_at=now() WHERE adjustment_id=ad.adjustment_id;
  ELSIF p_action='refund_authorize' THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   v_sub:=(p_payload->>'subscriptionId')::uuid;
   IF NOT EXISTS(SELECT 1 FROM public.tower_service_subscriptions WHERE service_id=p_service AND subscription_id=v_sub) THEN RAISE EXCEPTION 'SUBSCRIPTION_SCOPE_MISMATCH'; END IF;
   v_current:=public.tower_task_subscription_balance_internal(v_sub);
   v_amount:=CASE WHEN coalesce(p_payload->>'source','DUE_CREDIT')='ADVANCE' THEN (v_current->>'advanceAvailable')::numeric ELSE (v_current->>'creditAvailable')::numeric END;
   IF v_amount<=0 OR EXISTS(SELECT 1 FROM public.tower_finance_refund_authorizations WHERE subscription_id=v_sub AND authorization_status='APPROVED' AND max_amount>coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=tower_finance_refund_authorizations.refund_authorization_id AND m.movement_status='CONFIRMED'),0)) THEN RAISE EXCEPTION 'REFUND_UNAVAILABLE_OR_ALREADY_AUTHORIZED'; END IF;
   SELECT unit_id INTO v_unit FROM public.tower_service_subscriptions WHERE subscription_id=v_sub;
   INSERT INTO public.tower_finance_refund_authorizations(unit_id,account_id,subscription_id,max_amount,approved_by,effective_date)
    VALUES(v_unit,v_account,v_sub,v_amount,a.user_id,current_date) RETURNING refund_authorization_id INTO v_authorization;
   IF coalesce(p_payload->>'source','DUE_CREDIT') NOT IN ('DUE_CREDIT','ADVANCE') THEN RAISE EXCEPTION 'INVALID_REFUND_SOURCE'; END IF;
   INSERT INTO public.tower_task_credit_refunds(authorization_id,service_id,refund_source) VALUES(v_authorization,p_service,coalesce(p_payload->>'source','DUE_CREDIT'));
   IF p_payload->>'source'='ADVANCE' THEN
    v_remaining:=v_amount;
    FOR v_row IN SELECT l.link_id,l.advance_application_id,l.amount-coalesce((SELECT sum(au.amount) FROM public.tower_finance_advance_use_subscriptions x JOIN public.tower_finance_advance_uses au ON au.use_id=x.use_id WHERE x.link_id=l.link_id),0)-coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.link_id=l.link_id),0) available
     FROM public.tower_finance_advance_subscription_links l JOIN public.tower_finance_applications ap ON ap.application_id=l.advance_application_id JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id JOIN public.tower_finance_receipts rr ON rr.receipt_id=rp.receipt_id AND rr.receipt_status='POSTED' WHERE l.subscription_id=v_sub ORDER BY l.linked_at,l.link_id LOOP
     v_take:=least(v_remaining,greatest(0,v_row.available));
     IF v_take>0 THEN INSERT INTO public.tower_task_advance_refund_allocations(authorization_id,link_id,advance_application_id,amount) VALUES(v_authorization,v_row.link_id,v_row.advance_application_id,v_take);v_remaining:=v_remaining-v_take; END IF;
     EXIT WHEN v_remaining=0;
    END LOOP;
    IF v_remaining<>0 THEN RAISE EXCEPTION 'ADVANCE_REFUND_SCOPE_MISMATCH'; END IF;
   END IF;
  ELSIF p_action='refund_request' THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   SELECT ra.refund_authorization_id,ra.unit_id,ra.subscription_id INTO v_authorization,v_unit,v_sub
    FROM public.tower_finance_refund_authorizations ra JOIN public.tower_task_credit_refunds tr ON tr.authorization_id=ra.refund_authorization_id
    WHERE tr.service_id=p_service AND ra.refund_authorization_id=(p_payload->>'authorizationId')::uuid AND ra.authorization_status='APPROVED';
   IF NOT FOUND THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.sender_user_id=a.user_id AND m.movement_status IN ('PENDING','DISPUTED')) THEN RETURN jsonb_build_object('success',true,'replayed',true); END IF;
   IF (SELECT count(*) FROM public.tower_members mb JOIN public.tower_users us ON us.user_id=mb.user_id AND us.role='RESIDENT' AND us.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL)<>1 THEN RAISE EXCEPTION 'UNIQUE_CURRENT_UNIT_MANAGER_REQUIRED'; END IF;
   SELECT mb.user_id INTO v_manager FROM public.tower_members mb JOIN public.tower_users usr ON usr.user_id=mb.user_id AND usr.role='RESIDENT' AND usr.status='ACTIVE' WHERE mb.unit_id=v_unit AND mb.member_role='MANAGER' AND mb.ended_at IS NULL;
   v_current:=public.tower_task_subscription_balance_internal(v_sub);
   v_amount:=least(CASE WHEN (SELECT refund_source FROM public.tower_task_credit_refunds WHERE authorization_id=v_authorization)='ADVANCE' THEN (SELECT max_amount FROM public.tower_finance_refund_authorizations WHERE refund_authorization_id=v_authorization) ELSE (v_current->>'creditAvailable')::numeric END,(SELECT max_amount FROM public.tower_finance_refund_authorizations WHERE refund_authorization_id=v_authorization)
     -coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')),0));
   PERFORM public.tower_finance_request_unit_refund_internal(v_authorization,a.user_id,v_manager,v_amount);
  ELSIF p_action IN ('cancel_refund','revoke_refund') THEN
   IF a.role<>'UNION' THEN RAISE EXCEPTION 'UNION_ONLY'; END IF;
   IF p_action='cancel_refund' THEN
    IF NOT EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_task_credit_refunds cr ON cr.authorization_id=rm.refund_authorization_id WHERE rm.movement_id=(p_payload->>'movementId')::uuid AND cr.service_id=p_service) THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
    v_data:=public.tower_finance_refund_action(p_token,'cancel',jsonb_build_object('movementId',p_payload->>'movementId'));
   ELSE
    v_authorization:=(p_payload->>'authorizationId')::uuid;
    IF NOT EXISTS(SELECT 1 FROM public.tower_task_credit_refunds WHERE authorization_id=v_authorization AND service_id=p_service) THEN RAISE EXCEPTION 'REFUND_AUTHORIZATION_NOT_FOUND'; END IF;
    IF EXISTS(SELECT 1 FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id WHERE rm.refund_authorization_id=v_authorization AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED')) THEN RAISE EXCEPTION 'REFUND_ALREADY_IN_PROGRESS'; END IF;
    UPDATE public.tower_finance_refund_authorizations SET authorization_status='REVOKED' WHERE refund_authorization_id=v_authorization;
   END IF;
  ELSIF p_action IN ('close_financial','cancel_settled') THEN
   IF p_action='cancel_settled' AND (a.role<>'UNION' OR length(btrim(coalesce(p_payload->>'reason','')))=0) THEN RAISE EXCEPTION 'UNION_CANCELLATION_REASON_REQUIRED'; END IF;
   IF p_action='close_financial' AND NOT EXISTS(SELECT 1 FROM public.tower_task_workflow WHERE service_id=p_service AND stage='COMPLETED') THEN RAISE EXCEPTION 'EXECUTION_NOT_COMPLETED'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_fund_contributions fc WHERE fc.service_id=p_service AND NOT EXISTS(SELECT 1 FROM public.tower_task_fund_receipts fr WHERE fr.service_id=fc.service_id AND fr.amount=fc.amount AND fr.account_id=v_account)) THEN RAISE EXCEPTION 'FUND_CONTRIBUTION_RECEIPT_PENDING'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_service_subscriptions sub WHERE sub.service_id=p_service AND
     ((public.tower_task_subscription_balance_internal(sub.subscription_id)->>'remaining')::numeric>0 OR (public.tower_task_subscription_balance_internal(sub.subscription_id)->>'credit')::numeric>0)) THEN RAISE EXCEPTION 'UNSETTLED_UNIT_BALANCES'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_expenses ex WHERE ex.service_id=p_service AND ex.state<>'CANCELLED' AND (ex.state='DRAFT' OR NOT EXISTS(SELECT 1 FROM public.tower_task_expense_disbursements d WHERE d.expense_id=ex.expense_id))) THEN RAISE EXCEPTION 'UNSETTLED_EXPENSES'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_task_donation_returns WHERE account_id=v_account AND state='PENDING') THEN RAISE EXCEPTION 'PENDING_DONATION_RETURN'; END IF;
   IF EXISTS(SELECT 1 FROM public.tower_finance_cash_movements WHERE account_id=v_account AND movement_status IN ('PENDING','DISPUTED')) THEN RAISE EXCEPTION 'PENDING_CASH_MOVEMENTS'; END IF;
   FOR v_row IN SELECT DISTINCT user_id FROM public.tower_users WHERE user_id IN (
    SELECT r.collector_id FROM public.tower_finance_receipts r JOIN public.tower_finance_receipt_portions rp ON rp.receipt_id=r.receipt_id WHERE rp.account_id=v_account
    UNION SELECT confirmed_by FROM public.tower_task_fund_receipts WHERE account_id=v_account
    UNION SELECT recipient_user_id FROM public.tower_finance_cash_movements WHERE account_id=v_account AND movement_status='CONFIRMED') LOOP
    IF public.tower_finance_holder_available_internal(v_account,v_row.user_id)<>0 THEN RAISE EXCEPTION 'UNSETTLED_CUSTODY'; END IF;
   END LOOP;
   IF EXISTS(SELECT 1 FROM public.tower_finance_applications ap JOIN public.tower_finance_receipt_portions rp ON rp.portion_id=ap.portion_id JOIN public.tower_finance_receipts r ON r.receipt_id=rp.receipt_id
     WHERE rp.account_id=v_account AND r.receipt_status='POSTED' AND ap.application_kind='ADVANCE' AND NOT EXISTS(SELECT 1 FROM public.tower_task_donations dn WHERE dn.application_id=ap.application_id) AND ap.amount>coalesce((SELECT sum(au.amount) FROM public.tower_finance_advance_uses au WHERE au.advance_application_id=ap.application_id),0)+coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id WHERE al.advance_application_id=ap.application_id AND ra.max_amount<=coalesce((SELECT sum(m.amount) FROM public.tower_finance_refund_movements rm JOIN public.tower_finance_cash_movements m ON m.movement_id=rm.movement_id AND m.movement_status='CONFIRMED' WHERE rm.refund_authorization_id=ra.refund_authorization_id),0)),0)) THEN RAISE EXCEPTION 'UNSETTLED_ADVANCES'; END IF;
   UPDATE public.tower_task_projects SET phase=CASE WHEN p_action='cancel_settled' THEN 'CANCELLED' ELSE 'FINANCIAL_CLOSED' END,closure_note=CASE WHEN p_action='cancel_settled' THEN left(p_payload->>'reason',4000) ELSE 'انتهاء التنفيذ وتسوية الحساب' END WHERE service_id=p_service;
  ELSE RAISE EXCEPTION 'INVALID_TASK_ACTION'; END IF;
 END IF;
 IF p_action IN ('adjustment_approve','finalize','terms') THEN PERFORM public.tower_task_recompute_ready_213(p_service); END IF;
 UPDATE public.tower_task_projects SET version=version+1,updated_by=a.user_id,updated_at=now() WHERE service_id=p_service;
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'TASK_PROJECT_'||upper(p_action),'SERVICE',p_service::text);
 RETURN jsonb_build_object('success',true,'serviceId',p_service,'expenseId',CASE WHEN p_action='expense_draft' THEN v_id ELSE NULL END,'adjustmentId',CASE WHEN p_action='adjustment_draft' THEN v_id ELSE NULL END);
END $f$;

-- Targeted compatibility patches, based on the actual SQL228 definitions.
CREATE OR REPLACE FUNCTION public.tower_finance_holder_available_internal(p_account_id uuid, p_holder_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_receipts numeric(16,2);
 v_fund_cash numeric(16,2);
 v_incoming numeric(16,2);
 v_outgoing numeric(16,2);
 v_expenses numeric(16,2);
 v_account_kind text;
BEGIN
 IF p_account_id IS NULL OR p_holder_id IS NULL THEN
   RAISE EXCEPTION 'INVALID_HOLDER_ACCOUNT';
 END IF;
 -- Serialize all money movements for this account when used inside a writer.
 -- This is a read helper, not an authorization endpoint.
 SELECT account_kind INTO v_account_kind FROM public.tower_finance_accounts
 WHERE account_id=p_account_id AND status='ACTIVE' FOR UPDATE;
 IF NOT FOUND OR v_account_kind<>'PERSONAL_SERVICE' THEN
   RAISE EXCEPTION 'PERSONAL_ACCOUNT_NOT_FOUND';
 END IF;
 SELECT COALESCE(SUM(p.amount),0) INTO v_receipts
 FROM public.tower_finance_receipt_portions p
 JOIN public.tower_finance_receipts r ON r.receipt_id=p.receipt_id
 WHERE p.account_id=p_account_id AND r.collector_id=p_holder_id
 AND r.receipt_status='POSTED';
 SELECT COALESCE(SUM(fr.amount),0) INTO v_fund_cash
 FROM public.tower_task_fund_receipts fr
 JOIN public.tower_task_fund_contributions fc ON fc.service_id=fr.service_id
 JOIN public.tower_fund_entries fe ON fe.entry_id=fc.fund_entry_id
 WHERE fr.account_id=p_account_id AND fr.confirmed_by=p_holder_id
 AND fe.status='ACTIVE' AND fe.entry_type='EXPENSE' AND fe.amount=fr.amount;
 -- Only transfers between custodians create an inbound holder balance.
 -- UNIT_REFUND exits the service cash ledger; the resident manager does not
 -- become a new custodian of this money after confirming the refund.
 SELECT COALESCE(SUM(m.amount),0) INTO v_incoming
 FROM public.tower_finance_cash_movements m
 WHERE m.account_id=p_account_id AND m.recipient_user_id=p_holder_id
 AND m.movement_status='CONFIRMED'
 AND m.movement_kind IN ('BENEFICIARY_DELIVERY','BENEFICIARY_HANDOVER');
 -- Pending/disputed outgoing cash is already reserved and cannot be promised again.
 SELECT COALESCE(SUM(m.amount),0) INTO v_outgoing
 FROM public.tower_finance_cash_movements m
 WHERE m.account_id=p_account_id AND m.sender_user_id=p_holder_id
 AND m.movement_status IN ('PENDING','DISPUTED','CONFIRMED');
 SELECT coalesce(sum(amount),0) INTO v_expenses FROM public.tower_task_expense_disbursements WHERE account_id=p_account_id AND holder_id=p_holder_id;
 v_outgoing:=v_outgoing+v_expenses+coalesce((SELECT sum(amount) FROM public.tower_task_donation_returns WHERE account_id=p_account_id AND sender_id=p_holder_id AND state IN ('PENDING','CONFIRMED')),0);
 IF v_receipts+v_fund_cash+v_incoming<v_outgoing THEN
   RAISE EXCEPTION 'NEGATIVE_HOLDER_BALANCE';
 END IF;
 RETURN v_receipts+v_fund_cash+v_incoming-v_outgoing;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.tower_finance_post_personal_receipt_internal(p_unit_id uuid, p_collector_id uuid, p_amount numeric, p_portions jsonb, p_external_reference text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_receipt uuid;
  v_item jsonb;
  v_account uuid;
  v_amount numeric(16,2);
  v_portion uuid;
  v_due record;
  v_remaining numeric(16,2);
  v_unpaid numeric(16,2);
  v_take numeric(16,2);
  v_total numeric(16,2) := 0;
  v_seen uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_unit_id IS NULL OR p_collector_id IS NULL OR p_amount IS NULL
    OR p_amount<=0 OR p_amount<>round(p_amount,2)
    OR p_portions IS NULL OR jsonb_typeof(p_portions)<>'array'
    OR jsonb_array_length(p_portions)=0 THEN
    RAISE EXCEPTION 'INVALID_RECEIPT';
  END IF;
  -- Serialize updates for a unit (protect concurrent transactions allocating same dues).
  PERFORM 1 FROM public.tower_units WHERE unit_id=p_unit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_NOT_FOUND'; END IF;
  PERFORM 1 FROM public.tower_users WHERE user_id=p_collector_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COLLECTOR_NOT_FOUND'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_portions)
  LOOP
    IF jsonb_typeof(v_item)<>'object' OR
       NOT (v_item ? 'account_id' AND v_item ? 'amount') OR
       coalesce(v_item->>'account_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR
       coalesce(v_item->>'amount','') !~ '^([0-9]+)(\.[0-9]{1,2})?$' THEN
      RAISE EXCEPTION 'INVALID_PORTION';
    END IF;
    v_account := (v_item->>'account_id')::uuid;
    v_amount := (v_item->>'amount')::numeric;
    IF v_amount<=0 OR v_account=ANY(v_seen) THEN
      RAISE EXCEPTION 'INVALID_OR_DUPLICATE_ACCOUNT';
    END IF;
    PERFORM 1 FROM public.tower_finance_accounts
     WHERE account_id=v_account AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE'
     FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACCOUNT_NOT_PERSONAL_OR_INACTIVE'; END IF;
    v_seen:=array_append(v_seen,v_account);
    v_total:=v_total+v_amount;
  END LOOP;
  IF v_total<>p_amount THEN RAISE EXCEPTION 'RECEIPT_SUM_MISMATCH'; END IF;
  -- The caller's SQL transaction makes the receipt, portions and allocations indivisible.
  INSERT INTO public.tower_finance_receipts(unit_id,collector_id,amount,external_reference)
  VALUES(p_unit_id,p_collector_id,p_amount,coalesce(p_external_reference,''))
  RETURNING receipt_id INTO v_receipt;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_portions)
  LOOP
    v_account:=(v_item->>'account_id')::uuid;
    v_remaining:=(v_item->>'amount')::numeric;
    INSERT INTO public.tower_finance_receipt_portions(receipt_id,account_id,amount)
    VALUES(v_receipt,v_account,v_remaining) RETURNING portion_id INTO v_portion;
    FOR v_due IN
      SELECT d.due_id,public.tower_task_due_amount_internal(d.due_id) AS amount,
        public.tower_task_due_paid_internal(d.due_id) AS paid
       FROM public.tower_finance_dues d
       WHERE d.unit_id=p_unit_id AND d.account_id=v_account AND d.status='OPEN'
       ORDER BY d.due_date,d.due_id FOR UPDATE OF d
    LOOP
      EXIT WHEN v_remaining<=0;
      v_unpaid:=v_due.amount-v_due.paid;
      IF v_unpaid<0 AND NOT EXISTS(SELECT 1 FROM public.tower_task_due_credits WHERE due_id=v_due.due_id) THEN RAISE EXCEPTION 'OVERPAID_DUE_IN_LEDGER'; END IF;
      v_unpaid:=greatest(0,v_unpaid);
      v_take:=least(v_remaining,v_unpaid);
      IF v_take>0 THEN
        INSERT INTO public.tower_finance_applications(portion_id,due_id,amount,application_kind)
        VALUES(v_portion,v_due.due_id,v_take,'DUE');
        v_remaining:=v_remaining-v_take;
      END IF;
    END LOOP;
    IF v_remaining>0 THEN
      INSERT INTO public.tower_finance_applications(portion_id,due_id,amount,application_kind)
      VALUES(v_portion,NULL,v_remaining,'ADVANCE');
    END IF;
  END LOOP;
  RETURN v_receipt;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.tower_finance_apply_advances_internal(p_unit_id uuid, p_account_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 v_due record;
 v_advance record;
 v_link record;
 v_due_left numeric(16,2);
 v_advance_left numeric(16,2);
 v_link_left numeric(16,2);
 v_apply numeric(16,2);
 v_total numeric(16,2):=0;
 v_use_id uuid;
BEGIN
 IF p_unit_id IS NULL OR p_account_id IS NULL THEN RAISE EXCEPTION 'MISSING_SCOPE'; END IF;
 PERFORM 1 FROM public.tower_units WHERE unit_id=p_unit_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'UNIT_NOT_FOUND'; END IF;
 PERFORM 1 FROM public.tower_finance_accounts
  WHERE account_id=p_account_id AND account_kind='PERSONAL_SERVICE' AND status='ACTIVE' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_PERSONAL_ACCOUNT'; END IF;
 -- Abort rather than silently trusting earlier advance uses lacking an exact subscription.
 IF EXISTS (
  SELECT 1 FROM public.tower_finance_advance_uses u
  JOIN public.tower_finance_applications a ON a.application_id=u.advance_application_id
  JOIN public.tower_finance_receipt_portions p ON p.portion_id=a.portion_id
  JOIN public.tower_finance_receipts r ON r.receipt_id=p.receipt_id
  LEFT JOIN public.tower_finance_advance_use_subscriptions x ON x.use_id=u.use_id
  WHERE r.unit_id=p_unit_id AND p.account_id=p_account_id AND x.use_id IS NULL
 ) THEN RAISE EXCEPTION 'UNATTRIBUTED_HISTORIC_ADVANCE_USE'; END IF;
 FOR v_due IN
  SELECT d.due_id,d.subscription_id,public.tower_task_due_amount_internal(d.due_id) AS amount FROM public.tower_finance_dues d
  WHERE d.unit_id=p_unit_id AND d.account_id=p_account_id AND d.status='OPEN'
  ORDER BY d.due_date,d.due_id FOR UPDATE OF d
 LOOP
  IF v_due.subscription_id IS NULL THEN RAISE EXCEPTION 'DUE_SUBSCRIPTION_REQUIRED'; END IF;
  SELECT v_due.amount-public.tower_task_due_paid_internal(v_due.due_id) INTO v_due_left;
  IF v_due_left<0 AND NOT EXISTS(SELECT 1 FROM public.tower_task_due_credits WHERE due_id=v_due.due_id) THEN RAISE EXCEPTION 'OVERPAID_DUE_IN_LEDGER'; END IF;
  v_due_left:=greatest(0,v_due_left);
  IF v_due_left=0 THEN CONTINUE; END IF;
  FOR v_advance IN
   SELECT a.application_id,a.amount,r.created_at,r.receipt_id
   FROM public.tower_finance_applications a
   JOIN public.tower_finance_receipt_portions p ON p.portion_id=a.portion_id
   JOIN public.tower_finance_receipts r ON r.receipt_id=p.receipt_id
   WHERE a.application_kind='ADVANCE' AND a.due_id IS NULL
    AND p.account_id=p_account_id AND r.unit_id=p_unit_id AND r.receipt_status='POSTED'
   ORDER BY r.created_at,r.receipt_id,a.application_id FOR UPDATE OF a
  LOOP
   SELECT v_advance.amount-COALESCE(sum(u.amount),0) INTO v_advance_left
   FROM public.tower_finance_advance_uses u
   WHERE u.advance_application_id=v_advance.application_id;
   v_advance_left:=v_advance_left-coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.advance_application_id=v_advance.application_id),0);
   IF v_advance_left<0 THEN RAISE EXCEPTION 'OVERUSED_ADVANCE_IN_LEDGER'; END IF;
   IF v_advance_left=0 THEN CONTINUE; END IF;
   -- Link eligibility is subscription-specific; never spend another subscription's advance.
   FOR v_link IN
    SELECT l.link_id,l.amount,l.linked_by FROM public.tower_finance_advance_subscription_links l
    WHERE l.advance_application_id=v_advance.application_id
     AND l.subscription_id=v_due.subscription_id ORDER BY l.link_id FOR UPDATE OF l
   LOOP
    SELECT v_link.amount-COALESCE(sum(u.amount),0) INTO v_link_left
     FROM public.tower_finance_advance_use_subscriptions x
     JOIN public.tower_finance_advance_uses u ON u.use_id=x.use_id
     WHERE x.link_id=v_link.link_id;
    v_link_left:=v_link_left-coalesce((SELECT sum(al.amount) FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.link_id=v_link.link_id),0);
    IF v_link_left<0 THEN RAISE EXCEPTION 'ATTRIBUTION_LINK_OVERUSED'; END IF;
    v_apply:=LEAST(v_due_left,v_advance_left,v_link_left);
    IF v_apply>0 THEN
     INSERT INTO public.tower_finance_advance_uses(advance_application_id,due_id,amount)
      VALUES(v_advance.application_id,v_due.due_id,v_apply) RETURNING use_id INTO v_use_id;
     -- Any trigger failure rolls back the use as part of this very same transaction.
     INSERT INTO public.tower_finance_advance_use_subscriptions(use_id,link_id,subscription_id,attributed_by)
      VALUES(v_use_id,v_link.link_id,v_due.subscription_id,v_link.linked_by);
     v_total:=v_total+v_apply;
     v_due_left:=v_due_left-v_apply;
     v_advance_left:=v_advance_left-v_apply;
    END IF;
    EXIT WHEN v_due_left=0 OR v_advance_left=0;
   END LOOP;
   EXIT WHEN v_due_left=0;
  END LOOP;
 END LOOP;
 RETURN v_total;
END; $function$
;
CREATE OR REPLACE FUNCTION public.tower_finance_personal_overview(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor public.tower_users;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status <> 'ACTIVE' OR v_actor.must_change_pin THEN
  RAISE EXCEPTION 'SESSION_REQUIRED';
 END IF;
 IF v_actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 RETURN jsonb_build_object(
  'scope','PERSONAL_SERVICE','readOnly',true,
  'accounts',COALESCE((
   SELECT jsonb_agg(jsonb_build_object(
     'accountId',f.account_id,'serviceId',f.service_id,
     'serviceName',s.name,'beneficiaryUserId',f.beneficiary_user_id,
     'beneficiaryName',concat_ws(' ',u.title,u.name),
     'status',f.status,
     'collected',COALESCE((SELECT sum(p.amount) FROM public.tower_finance_receipt_portions p
        JOIN public.tower_finance_receipts r ON r.receipt_id=p.receipt_id
        WHERE p.account_id=f.account_id AND r.receipt_status='POSTED'),0),
     'dues',COALESCE((SELECT sum(public.tower_task_due_amount_internal(d.due_id)) FROM public.tower_finance_dues d
        WHERE d.account_id=f.account_id AND d.status='OPEN'),0),
     'pendingMovements',COALESCE((SELECT sum(m.amount) FROM public.tower_finance_cash_movements m
        WHERE m.account_id=f.account_id AND m.movement_status IN ('PENDING','DISPUTED')),0)
    ) ORDER BY s.name,f.created_at,f.account_id)
   FROM public.tower_finance_accounts f
   JOIN public.tower_services s ON s.service_id=f.service_id
   JOIN public.tower_users u ON u.user_id=f.beneficiary_user_id
   WHERE f.account_kind='PERSONAL_SERVICE'
  ),'[]'::jsonb)
 );
END $function$
;
CREATE OR REPLACE FUNCTION public.tower_task_workflow_action(p_token text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor public.tower_users; v_service public.tower_services; v_id uuid; v_w public.tower_task_workflow; v_data jsonb; v_rows jsonb; v_admin boolean;
BEGIN
 SELECT * INTO v_actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR v_actor.status <> 'ACTIVE' OR v_actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 v_admin := v_actor.role IN ('ADMIN','UNION');
 IF p_action='list' THEN
  IF NOT v_admin AND v_actor.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
     'serviceId',s.service_id,'stage',coalesce(w.stage,CASE WHEN s.enrollment_status='OPEN' THEN 'COLLECT_SUBSCRIBERS' ELSE 'COLLECT_FUNDS' END),
     'executionDate',w.execution_date,'startRule',coalesce(w.start_rule,'MANUAL'),
     'collectionThreshold',coalesce(w.collection_threshold,100),'executionPercent',coalesce(w.execution_percent,0),
     'installmentCount',coalesce(w.installment_count,1),'firstDueDate',w.first_due_date,
     'fundContributionProposed',coalesce(w.fund_contribution_proposed,0),
     'revision',coalesce(w.revision,0),
     'collected',coalesce(fin.collected,0),'approvedDues',coalesce(fin.due_total,0),
     'fundContributionPosted',coalesce((SELECT c.amount FROM public.tower_task_fund_contributions c WHERE c.service_id=s.service_id),0),
     'minimumStartAmount',coalesce((SELECT minimum_start_amount FROM public.tower_task_projects WHERE service_id=s.service_id),0),
     'adjustmentsTotal',coalesce((SELECT sum(amount) FROM public.tower_task_adjustments WHERE service_id=s.service_id AND state='APPROVED'),0),
     'financialNote','مساهمة الصندوق المقترحة لا تدخل في التحصيل إلا بعد تنفيذ تحويل مالي موثق') ORDER BY s.name),'[]'::jsonb)
   INTO v_rows
   FROM public.tower_services s
   LEFT JOIN public.tower_task_workflow w ON w.service_id=s.service_id
   LEFT JOIN LATERAL (
      SELECT coalesce(sum(public.tower_task_due_amount_internal(d.due_id)),0) due_total,
      coalesce(sum(least(public.tower_task_due_amount_internal(d.due_id),public.tower_task_due_paid_internal(d.due_id))),0) collected
      FROM public.tower_finance_dues d
      JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
      WHERE sub.service_id=s.service_id AND d.status='OPEN'
   ) fin ON true
   WHERE s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL'
     AND (v_admin OR EXISTS(
       SELECT 1 FROM public.tower_members m JOIN public.tower_service_subscriptions ss ON ss.unit_id=m.unit_id
       WHERE m.user_id=v_actor.user_id AND m.ended_at IS NULL AND ss.service_id=s.service_id
     ) OR s.status='ACTIVE');
  RETURN v_rows;
 END IF;
 IF NOT v_admin THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action<>'save' THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 BEGIN v_id:=(p_payload->>'serviceId')::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'INVALID_SERVICE_ID'; END;
 SELECT * INTO v_service FROM public.tower_services WHERE service_id=v_id FOR UPDATE;
 IF NOT FOUND OR v_service.service_kind<>'ONE_TIME' OR v_service.pricing_mode<>'SHARED_TOTAL' THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 IF (p_payload->>'stage') NOT IN ('COLLECT_SUBSCRIBERS','COLLECT_FUNDS','READY','IN_PROGRESS','COMPLETED') THEN RAISE EXCEPTION 'INVALID_STAGE'; END IF;
 IF v_service.enrollment_status<>'OPEN' AND p_payload->>'stage'='COLLECT_SUBSCRIBERS' THEN RAISE EXCEPTION 'ENROLLMENT_NOT_OPEN'; END IF;
 IF v_service.enrollment_status<>'FINALIZED' AND p_payload->>'stage' IN ('READY','IN_PROGRESS','COMPLETED') THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
 IF coalesce((p_payload->>'executionPercent')::int,-1) NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'INVALID_EXECUTION_PERCENT'; END IF;
 IF coalesce((p_payload->>'installmentCount')::int,-1) NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'INVALID_INSTALLMENTS'; END IF;
 IF coalesce((p_payload->>'collectionThreshold')::int,-1) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVALID_THRESHOLD'; END IF;
 IF p_payload->>'startRule' NOT IN ('MANUAL','DATE','COLLECTION','DATE_AND_COLLECTION') THEN RAISE EXCEPTION 'INVALID_START_RULE'; END IF;
 IF (p_payload->>'fundContributionProposed')::numeric < 0 OR (p_payload->>'fundContributionProposed')::numeric > v_service.total_budget THEN RAISE EXCEPTION 'INVALID_FUND_CONTRIBUTION'; END IF;
 IF v_service.enrollment_status='FINALIZED' AND (p_payload->>'fundContributionProposed')::numeric <> coalesce((SELECT fund_contribution_proposed FROM public.tower_task_workflow WHERE service_id=v_id),0) THEN RAISE EXCEPTION 'CONTRIBUTION_LOCKED_AFTER_FINALIZATION'; END IF;
 INSERT INTO public.tower_task_workflow(service_id,stage,execution_date,start_rule,collection_threshold,execution_percent,installment_count,first_due_date,fund_contribution_proposed,updated_by)
 VALUES(v_id,p_payload->>'stage',nullif(p_payload->>'executionDate','')::date,p_payload->>'startRule',(p_payload->>'collectionThreshold')::int,(p_payload->>'executionPercent')::int,(p_payload->>'installmentCount')::int,nullif(p_payload->>'firstDueDate','')::date,(p_payload->>'fundContributionProposed')::numeric,v_actor.user_id)
 ON CONFLICT(service_id) DO UPDATE SET stage=excluded.stage,execution_date=excluded.execution_date,start_rule=excluded.start_rule,
 collection_threshold=excluded.collection_threshold,execution_percent=excluded.execution_percent,installment_count=excluded.installment_count,
 first_due_date=excluded.first_due_date,fund_contribution_proposed=excluded.fund_contribution_proposed,updated_by=v_actor.user_id,
 revision=tower_task_workflow.revision+1,updated_at=now();
 INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(v_actor.user_id,'UPDATE_TASK_WORKFLOW','SERVICE',v_id::text);
 RETURN jsonb_build_object('success',true,'serviceId',v_id);
END $function$
;
CREATE OR REPLACE FUNCTION public.tower_task_recompute_ready_213(p_service_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE w public.tower_task_workflow; paid numeric;due numeric;minimum numeric;ok_date boolean;ok_money boolean;ready boolean;
BEGIN
 PERFORM 1 FROM public.tower_services WHERE service_id=p_service_id AND enrollment_status='FINALIZED' FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT * INTO w FROM public.tower_task_workflow WHERE service_id=p_service_id FOR UPDATE;
 IF NOT FOUND OR w.stage NOT IN ('COLLECT_FUNDS','READY') THEN RETURN; END IF;
 SELECT minimum_start_amount INTO minimum FROM public.tower_task_projects WHERE service_id=p_service_id;
 IF w.start_rule='MANUAL' AND coalesce(minimum,0)=0 THEN RETURN; END IF;
 SELECT coalesce(sum(public.tower_task_due_amount_internal(d.due_id)),0),coalesce(sum(least(public.tower_task_due_amount_internal(d.due_id),public.tower_task_due_paid_internal(d.due_id))),0)
 INTO due,paid FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND d.status='OPEN';
 ok_date:=w.execution_date IS NOT NULL AND w.execution_date<=current_date;
 ok_money:=CASE WHEN coalesce(minimum,0)>0 THEN paid>=minimum ELSE paid*100>=due*w.collection_threshold END;
 ready:=CASE WHEN w.start_rule='DATE' THEN ok_date AND (coalesce(minimum,0)=0 OR ok_money)
 WHEN w.start_rule='DATE_AND_COLLECTION' THEN ok_date AND ok_money ELSE ok_money END;
 UPDATE public.tower_task_workflow SET stage=CASE WHEN ready THEN 'READY' ELSE 'COLLECT_FUNDS' END,revision=revision+1,updated_at=now()
 WHERE service_id=p_service_id AND stage IS DISTINCT FROM CASE WHEN ready THEN 'READY' ELSE 'COLLECT_FUNDS' END;
END $f$;
-- Correct both payment sources in the unit-scoped reader; expose overpayment explicitly.
CREATE OR REPLACE FUNCTION public.tower_unit_task_balances_read_for_unit(p_token text,p_unit_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role<>'RESIDENT' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_units u ON u.unit_id=m.unit_id AND u.status='ACTIVE'
 WHERE m.unit_id=p_unit_id AND m.user_id=a.user_id AND m.ended_at IS NULL) THEN RAISE EXCEPTION 'UNIT_ACCESS_DENIED'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('serviceId',service_id,'due',due,'paid',paid,'remaining',remaining,'credit',credit,'refunded',refunded,'dueCount',cnt)),'[]') INTO rows
 FROM (SELECT sub.service_id,sum((b->>'due')::numeric) due,sum((b->>'paid')::numeric) paid,sum((b->>'remaining')::numeric) remaining,
 sum((b->>'credit')::numeric) credit,sum((b->>'refunded')::numeric) refunded,
 (SELECT count(*) FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions ss ON ss.subscription_id=d.subscription_id WHERE ss.service_id=sub.service_id AND d.unit_id=p_unit_id AND d.status='OPEN') cnt
 FROM public.tower_service_subscriptions sub JOIN public.tower_services s ON s.service_id=sub.service_id
 CROSS JOIN LATERAL (SELECT public.tower_task_subscription_balance_internal(sub.subscription_id) b) bal
 WHERE sub.unit_id=p_unit_id AND s.service_kind='ONE_TIME' AND s.pricing_mode='SHARED_TOTAL' AND s.enrollment_status='FINALIZED'
 AND (EXISTS(SELECT 1 FROM public.tower_finance_dues d WHERE d.subscription_id=sub.subscription_id AND d.status='OPEN') OR EXISTS(SELECT 1 FROM public.tower_task_allocation_snapshots sn WHERE sn.subscription_id=sub.subscription_id)) GROUP BY sub.service_id) q;
 RETURN jsonb_build_object('unitId',p_unit_id,'scope','UNIT_TASK_DUES','readOnly',true,'rows',rows);
END $f$;
-- List adjusted installments without recreating debt. Credits reduce the last installments first.
CREATE OR REPLACE FUNCTION public.tower_task_installments_action(p_token text,p_service_id uuid,p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE a public.tower_users;v_due_record record;v_count int;v_first date;v_installment int;cents bigint;v_part numeric;rows jsonb;
BEGIN
 SELECT * INTO a FROM public.tower_session_user(p_token);
 IF NOT FOUND OR a.status<>'ACTIVE' OR a.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED'; END IF;
 IF a.role NOT IN ('ADMIN','UNION','RESIDENT') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action NOT IN ('list','install') THEN RAISE EXCEPTION 'INVALID_ACTION'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tower_services WHERE service_id=p_service_id AND service_kind='ONE_TIME' AND pricing_mode='SHARED_TOTAL') THEN RAISE EXCEPTION 'INVALID_TASK'; END IF;
 IF a.role='RESIDENT' AND NOT EXISTS(SELECT 1 FROM public.tower_members m JOIN public.tower_service_subscriptions s ON s.unit_id=m.unit_id WHERE m.user_id=a.user_id AND m.ended_at IS NULL AND s.service_id=p_service_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
 IF p_action='install' THEN
  IF a.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  PERFORM 1 FROM public.tower_services WHERE service_id=p_service_id AND enrollment_status='FINALIZED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ALLOCATION_NOT_FINALIZED'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_task_projects WHERE service_id=p_service_id AND phase='FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
  SELECT installment_count,first_due_date INTO v_count,v_first FROM public.tower_task_workflow WHERE service_id=p_service_id;
  IF v_first IS NULL THEN RAISE EXCEPTION 'INSTALLMENT_START_DATE_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND d.status='OPEN' AND public.tower_task_due_amount_internal(d.due_id)>0) THEN RAISE EXCEPTION 'NO_APPROVED_DUES'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues d ON d.due_id=i.due_id JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id) THEN RAISE EXCEPTION 'INSTALLMENT_PLAN_ALREADY_INSTALLED'; END IF;
  IF EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id AND public.tower_task_due_paid_internal(d.due_id)>0) THEN RAISE EXCEPTION 'INSTALLMENTS_REQUIRE_UNPAID_DUES'; END IF;
  FOR v_due_record IN SELECT d.* FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.service_id=p_service_id AND d.status='OPEN' ORDER BY d.due_id FOR UPDATE OF d LOOP
   cents:=round(public.tower_task_due_amount_internal(v_due_record.due_id)*100)::bigint;
   IF cents=0 THEN CONTINUE; END IF;
   IF cents<v_count THEN RAISE EXCEPTION 'INSTALLMENTS_EXCEED_AMOUNT_CENTS'; END IF;
   FOR v_installment IN 1..v_count LOOP
    v_part:=((cents/v_count)+CASE WHEN v_installment<=cents%v_count THEN 1 ELSE 0 END)::numeric/100;
    INSERT INTO public.tower_task_due_installments(due_id,installment_no,due_date,amount) VALUES(v_due_record.due_id,v_installment,(v_first+make_interval(months=>v_installment-1))::date,v_part);
   END LOOP;
  END LOOP;
  INSERT INTO public.tower_audit(actor_id,action,entity,entity_id) VALUES(a.user_id,'INSTALL_TASK_DUE_SCHEDULE','SERVICE',p_service_id::text);
 END IF;
 WITH dues AS (
 SELECT d.*,public.tower_task_due_amount_internal(d.due_id) effective,public.tower_task_due_paid_internal(d.due_id) paid
 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id
 WHERE sub.service_id=p_service_id AND d.status='OPEN' AND (a.role IN ('ADMIN','UNION') OR EXISTS(SELECT 1 FROM public.tower_members m WHERE m.unit_id=d.unit_id AND m.user_id=a.user_id AND m.ended_at IS NULL))),
 plan AS (SELECT i.due_id,i.installment_no no,i.due_date,i.amount FROM public.tower_task_due_installments i JOIN dues d ON d.due_id=i.due_id
 UNION ALL
 SELECT d.due_id,coalesce((SELECT max(i.installment_no) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)+1,
 coalesce((SELECT max(ad.approved_at)::date FROM public.tower_task_credit_reversals cr JOIN public.tower_task_adjustments ad ON ad.adjustment_id=cr.adjustment_id WHERE cr.due_id=d.due_id),d.due_date),
 d.effective-coalesce((SELECT sum(i.amount) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)
 FROM dues d WHERE d.effective>coalesce((SELECT sum(i.amount) FROM public.tower_task_due_installments i WHERE i.due_id=d.due_id),0)
 AND EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues other ON other.due_id=i.due_id JOIN public.tower_service_subscriptions sub ON sub.subscription_id=other.subscription_id WHERE sub.service_id=p_service_id)),
 base AS (SELECT d.due_id,d.unit_id,i.no,i.due_date,i.amount,d.effective,d.paid,
 coalesce(sum(i.amount) OVER(PARTITION BY d.due_id ORDER BY i.no ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM dues d JOIN plan i ON i.due_id=d.due_id),
 net AS (SELECT *,greatest(0,least(amount,effective-prior)) net_amount FROM base)
 SELECT coalesce(jsonb_agg(jsonb_build_object('dueId',due_id,'unitId',unit_id,'installment',no,'dueDate',due_date,'amount',net_amount,
 'paid',greatest(0,least(net_amount,paid-prior)),'remaining',net_amount-greatest(0,least(net_amount,paid-prior))) ORDER BY unit_id,due_date,no),'[]') INTO rows FROM net WHERE net_amount>0;
 RETURN jsonb_build_object('success',true,'rows',rows,
 'hasPlan',EXISTS(SELECT 1 FROM public.tower_task_due_installments i JOIN public.tower_finance_dues d ON d.due_id=i.due_id JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id),
 'noPlanNeeded',NOT EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND d.status='OPEN' AND public.tower_task_due_amount_internal(d.due_id)>0),
 'hasPayments',EXISTS(SELECT 1 FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE sub.service_id=p_service_id AND public.tower_task_due_paid_internal(d.due_id)>0));
END $f$;
CREATE OR REPLACE FUNCTION public.tower_task_cash_gate_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_finance_accounts a JOIN public.tower_task_projects p ON p.service_id=a.service_id
 WHERE a.account_id=NEW.account_id AND p.phase IN ('PROPOSAL','CANCELLED','FINANCIAL_CLOSED')) THEN RAISE EXCEPTION 'TASK_NOT_ACCEPTING_FINANCIAL_POSTS'; END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_cash_gate_229 ON public.tower_finance_receipt_portions;
CREATE TRIGGER tower_task_cash_gate_229 BEFORE INSERT ON public.tower_finance_receipt_portions FOR EACH ROW EXECUTE FUNCTION public.tower_task_cash_gate_229();
DROP TRIGGER IF EXISTS tower_task_due_gate_229 ON public.tower_finance_dues;
CREATE TRIGGER tower_task_due_gate_229 BEFORE INSERT ON public.tower_finance_dues FOR EACH ROW EXECUTE FUNCTION public.tower_task_cash_gate_229();
CREATE OR REPLACE FUNCTION public.tower_task_phase_gate_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE phase text;
BEGIN
 SELECT p.phase INTO phase FROM public.tower_task_projects p WHERE p.service_id=NEW.service_id;
 IF phase IN ('CANCELLED','FINANCIAL_CLOSED') THEN RAISE EXCEPTION 'TASK_CLOSED'; END IF;
 IF TG_TABLE_NAME='tower_services' THEN
  IF phase='PROPOSAL' AND NEW.enrollment_status<>'OPEN' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
 ELSE
  IF phase='PROPOSAL' AND NEW.stage<>'COLLECT_SUBSCRIBERS' THEN RAISE EXCEPTION 'TASK_NOT_OPEN_FOR_PARTICIPATION'; END IF;
 END IF;
 RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_service_phase_gate_229 ON public.tower_services;
CREATE TRIGGER tower_task_service_phase_gate_229 BEFORE UPDATE OF enrollment_status ON public.tower_services FOR EACH ROW EXECUTE FUNCTION public.tower_task_phase_gate_229();
DROP TRIGGER IF EXISTS tower_task_workflow_phase_gate_229 ON public.tower_task_workflow;
CREATE TRIGGER tower_task_workflow_phase_gate_229 BEFORE INSERT OR UPDATE ON public.tower_task_workflow FOR EACH ROW EXECUTE FUNCTION public.tower_task_phase_gate_229();
CREATE OR REPLACE FUNCTION public.tower_task_advance_ready_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE service uuid;BEGIN
 SELECT sub.service_id INTO service FROM public.tower_finance_dues d JOIN public.tower_service_subscriptions sub ON sub.subscription_id=d.subscription_id WHERE d.due_id=NEW.due_id;
 IF service IS NOT NULL THEN PERFORM public.tower_task_recompute_ready_213(service); END IF; RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_advance_ready_229 ON public.tower_finance_advance_uses;
CREATE TRIGGER tower_task_advance_ready_229 AFTER INSERT ON public.tower_finance_advance_uses FOR EACH ROW EXECUTE FUNCTION public.tower_task_advance_ready_229();
CREATE OR REPLACE FUNCTION public.tower_task_donation_attribution_gate_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
BEGIN
 IF EXISTS(SELECT 1 FROM public.tower_task_donations WHERE application_id=NEW.advance_application_id) THEN RAISE EXCEPTION 'DONATION_NOT_A_SUBSCRIPTION_ADVANCE'; END IF; RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_donation_attribution_gate_229 ON public.tower_finance_advance_subscription_links;
CREATE TRIGGER tower_task_donation_attribution_gate_229 BEFORE INSERT OR UPDATE ON public.tower_finance_advance_subscription_links FOR EACH ROW EXECUTE FUNCTION public.tower_task_donation_attribution_gate_229();
CREATE OR REPLACE FUNCTION public.tower_task_advance_refund_gate_229() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE available numeric;used numeric;reserved numeric;
BEGIN
 IF TG_TABLE_NAME='tower_finance_advance_uses' THEN
  SELECT amount INTO available FROM public.tower_finance_applications WHERE application_id=NEW.advance_application_id;
  SELECT coalesce(sum(amount),0) INTO used FROM public.tower_finance_advance_uses WHERE advance_application_id=NEW.advance_application_id;
  SELECT coalesce(sum(al.amount),0) INTO reserved FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.advance_application_id=NEW.advance_application_id;
  IF NEW.amount>available-used-reserved THEN RAISE EXCEPTION 'ADVANCE_RESERVED_FOR_REFUND'; END IF;
 ELSE
  SELECT amount INTO available FROM public.tower_finance_advance_subscription_links WHERE link_id=NEW.link_id;
  SELECT coalesce(sum(au.amount),0) INTO used FROM public.tower_finance_advance_use_subscriptions x JOIN public.tower_finance_advance_uses au ON au.use_id=x.use_id WHERE x.link_id=NEW.link_id;
  SELECT coalesce(sum(al.amount),0) INTO reserved FROM public.tower_task_advance_refund_allocations al JOIN public.tower_finance_refund_authorizations ra ON ra.refund_authorization_id=al.authorization_id AND ra.authorization_status='APPROVED' WHERE al.link_id=NEW.link_id;
  IF (SELECT amount FROM public.tower_finance_advance_uses WHERE use_id=NEW.use_id)>available-used-reserved THEN RAISE EXCEPTION 'ADVANCE_RESERVED_FOR_REFUND'; END IF;
 END IF; RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS tower_task_advance_refund_gate_229 ON public.tower_finance_advance_uses;
CREATE TRIGGER tower_task_advance_refund_gate_229 BEFORE INSERT ON public.tower_finance_advance_uses FOR EACH ROW EXECUTE FUNCTION public.tower_task_advance_refund_gate_229();
DROP TRIGGER IF EXISTS tower_task_advance_link_refund_gate_229 ON public.tower_finance_advance_use_subscriptions;
CREATE TRIGGER tower_task_advance_link_refund_gate_229 BEFORE INSERT ON public.tower_finance_advance_use_subscriptions FOR EACH ROW EXECUTE FUNCTION public.tower_task_advance_refund_gate_229();
-- Internal helpers and triggers cannot be invoked by application roles.
DO $do$ DECLARE r record;BEGIN
 FOR r IN SELECT p.oid::regprocedure signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
 AND (p.proname LIKE 'tower_task_%_internal' OR p.proname IN ('tower_task_enrollment_gate_229','tower_task_cash_gate_229','tower_task_phase_gate_229','tower_task_advance_ready_229','tower_task_donation_attribution_gate_229','tower_task_advance_refund_gate_229','tower_task_project_read_229','tower_task_project_action_229')) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',r.signature);
 END LOOP;
END $do$;
GRANT SELECT(service_id,phase,scope_text,deadline,distribution,target_units,agreed_amounts) ON public.tower_task_projects TO service_role;
GRANT EXECUTE ON FUNCTION public.tower_task_project_read_229(text,uuid,uuid),public.tower_task_project_action_229(text,text,uuid,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*__________________________________ End of code...*/
