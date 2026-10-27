/*
Tower App V2.5.185 - SQL_241.

___________________________
*/
BEGIN;
CREATE OR REPLACE FUNCTION public.tower_activity_kind_241(p_action text,p_entity text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO pg_catalog,public AS $f$
 SELECT CASE WHEN concat_ws(' ',p_action,p_entity) ~* '(financ|payment|fund|charge|collect|expense|deposit|cash|settle)' THEN 'FINANCE'
 WHEN concat_ws(' ',p_action,p_entity) ~* '(service|subscription|task|shared)' THEN 'SERVICE'
 WHEN concat_ws(' ',p_action,p_entity) ~* '(unit|member|user|resident|pin|login|registration|session)' THEN 'PEOPLE' ELSE 'OTHER' END
$f$;
CREATE OR REPLACE FUNCTION public.tower_activity_label_241(p_action text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO pg_catalog,public AS $f$
 SELECT CASE upper(p_action)
 WHEN 'CREATE_BUILDING_CHARGE' THEN 'إنشاء استحقاق'
 WHEN 'EDIT_BUILDING_CHARGE' THEN 'تعديل استحقاق'
 WHEN 'CANCEL_BUILDING_CHARGE' THEN 'إلغاء استحقاق'
 WHEN 'RECORD_BUILDING_PAYMENT' THEN 'تسجيل دفعة'
 WHEN 'CREATE_FINANCE_ENTRY' THEN 'تسجيل حركة صندوق'
 WHEN 'CANCEL_FINANCE_ENTRY' THEN 'إلغاء حركة صندوق'
 WHEN 'APPROVE_COLLECTION_REPORT' THEN 'اعتماد تقرير تحصيل'
 WHEN 'ADD_PAYMENT_ATTACHMENT' THEN 'إضافة مرفق دفعة'
 WHEN 'LOGIN' THEN 'تسجيل دخول'
 WHEN 'LOGOUT' THEN 'تسجيل خروج'
 WHEN 'UNIT_MANAGER_TRANSFER' THEN 'نقل إدارة وحدة'
 WHEN 'REQUEST_SERVICE_SUBSCRIPTION' THEN 'طلب اشتراك خدمة'
 WHEN 'SERVICE_SUBSCRIPTION_REQUEST' THEN 'طلب اشتراك خدمة'
 WHEN 'SERVICE_SUBSCRIBE' THEN 'إضافة اشتراك خدمة'
 WHEN 'REVIEW_SERVICE_SUBSCRIPTION' THEN 'مراجعة اشتراك خدمة'
 WHEN 'REMOVE_SHARED_SUBSCRIBER' THEN 'إزالة مشترك من مهمة'
 WHEN 'CANCEL_PENDING_SERVICE_REQUEST' THEN 'إلغاء طلب اشتراك'
 WHEN 'UPDATE_PENDING_SERVICE_REQUEST' THEN 'تعديل طلب اشتراك'
 WHEN 'UPDATE_USER' THEN 'تعديل حساب مستخدم'
 WHEN 'UPDATE_MEMBER' THEN 'تعديل عضوية'
 WHEN 'CREATE_USER' THEN 'إنشاء حساب مستخدم'
 WHEN 'CREATE_UNIT' THEN 'إنشاء وحدة'
 WHEN 'UPDATE_UNIT' THEN 'تعديل وحدة'
 WHEN 'EDIT_SERVICE_DETAILS_230' THEN 'تعديل خدمة أو مهمة'
 WHEN 'UNIT_ACCOUNT_VISIBILITY' THEN 'تعديل خصوصية حساب الوحدة'
 WHEN 'CREATE_PAYMENT' THEN 'تسجيل دفعة مشاوير'
 WHEN 'CANCEL_PAYMENT' THEN 'إلغاء دفعة مشاوير'
 WHEN 'CLOSE_SETTLEMENT' THEN 'تسوية حساب المشاوير'
 WHEN 'UNDO_SETTLEMENT' THEN 'التراجع عن تسوية المشاوير'
 WHEN 'CREATE_SERVICE' THEN 'إنشاء خدمة'
 WHEN 'UPDATE_SERVICE' THEN 'تعديل خدمة'
 WHEN 'REVIEW_SERVICE_CHANGE' THEN 'مراجعة تعديل اشتراك'
 WHEN 'REQUEST_SERVICE_CHANGE' THEN 'طلب تعديل اشتراك'
 WHEN 'GENERATE_SERVICE_DUES' THEN 'إنشاء مستحقات خدمة'
 WHEN 'FINALIZE_SHARED_ALLOCATION' THEN 'اعتماد توزيع المهمة'
 WHEN 'CREATE_COLLECTION_REPORT' THEN 'إنشاء تقرير تحصيل'
 WHEN 'SUBMIT_COLLECTION_REPORT' THEN 'إرسال تقرير تحصيل'
 WHEN 'RETURN_COLLECTION_REPORT' THEN 'إرجاع تقرير تحصيل'
 WHEN 'UPDATE_COLLECTION_REPORT' THEN 'تعديل تقرير تحصيل'
 WHEN 'CREATE_TRIP' THEN 'تسجيل مشوار'
 WHEN 'UPDATE_TRIP' THEN 'تعديل مشوار'
 WHEN 'CREATE_RESIDENT_TRIP' THEN 'طلب مشوار'
 WHEN 'TASK_CREATE' THEN 'إنشاء مهمة'
 WHEN 'TASK_EXPENSE' THEN 'تسجيل مصروف مهمة'
 WHEN 'TASK_ADJUSTMENT' THEN 'تسوية تكلفة مهمة'
 ELSE CASE public.tower_activity_kind_241(p_action,'') WHEN 'FINANCE' THEN 'عملية مالية' WHEN 'SERVICE' THEN 'عملية خدمة أو مهمة' WHEN 'PEOPLE' THEN 'عملية حساب أو وحدة' ELSE 'عملية بالنظام' END END
$f$;
-- This view supplies current labels only; no invented historical actor or unit membership.
CREATE OR REPLACE VIEW public.tower_activity_rows_241 AS
 SELECT a.audit_id,a.at,a.actor_id,a.action,a.entity,a.entity_id,
 public.tower_activity_label_241(a.action) AS action_label,
 public.tower_activity_kind_241(a.action,a.entity) AS category,
 (concat_ws(' ',a.action,a.entity) ~* '(financ|payment|fund|charge|collect|expense|deposit|cash|settle|service|subscription|task|shared)') AS is_financial,
 CASE WHEN actor.user_id IS NULL THEN 'حساب لم تعد بياناته متاحة' ELSE public.tower_person_label_231(actor.name,actor.title,actor.user_id) END AS actor_label,
 actor.role AS actor_role,un.unit_id,un.unit_number,un.floor,
 coalesce(svc.name,subsvc.name,chargesvc.name,accountsvc.name) AS service_name,
 CASE WHEN upper(a.entity)='USER' AND subject.user_id IS NOT NULL THEN public.tower_person_label_231(subject.name,subject.title,subject.user_id) END AS subject_label
 FROM public.tower_audit a
 LEFT JOIN public.tower_users actor ON actor.user_id=a.actor_id
 LEFT JOIN LATERAL (SELECT CASE WHEN coalesce(a.entity_id,'') ~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN a.entity_id::uuid END id) ident ON true
 LEFT JOIN public.tower_service_subscriptions sub ON upper(a.entity) IN ('SERVICE_SUBSCRIPTION','SUBSCRIPTION') AND sub.subscription_id=ident.id
 LEFT JOIN public.tower_services svc ON upper(a.entity) IN ('SERVICE','TASK','TASK_PROJECT') AND svc.service_id=ident.id
 LEFT JOIN public.tower_services subsvc ON subsvc.service_id=sub.service_id
 LEFT JOIN public.tower_building_payments pay ON upper(a.entity) IN ('BUILDING_PAYMENT') AND pay.payment_id=ident.id
 LEFT JOIN public.tower_building_charges charge ON (upper(a.entity)='BUILDING_CHARGE' AND charge.charge_id=ident.id) OR (charge.charge_id=pay.charge_id)
 LEFT JOIN public.tower_services chargesvc ON chargesvc.service_id=charge.service_id
 LEFT JOIN public.tower_finance_accounts account ON upper(a.entity) IN ('FINANCE_ACCOUNT','SERVICE_ACCOUNT') AND account.account_id=ident.id
 LEFT JOIN public.tower_services accountsvc ON accountsvc.service_id=account.service_id
 LEFT JOIN public.tower_units un ON un.unit_id=CASE WHEN upper(a.entity)='UNIT' THEN ident.id ELSE coalesce(sub.unit_id,pay.unit_id) END
 LEFT JOIN public.tower_users subject ON upper(a.entity)='USER' AND subject.user_id=ident.id;
REVOKE ALL ON public.tower_activity_rows_241 FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.tower_activity_read_241(p_token text,p_action text,p_payload jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;r record;rows jsonb;cnt integer;pg integer;query text;actor_query text;kind text;act text;day_from date;day_to date;opts jsonb;before_data jsonb;after_data jsonb;cid uuid;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;
 IF p_action='details' THEN
  IF coalesce(p_payload->>'auditId','') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN RAISE EXCEPTION 'AUDIT_NOT_FOUND';END IF;
  SELECT * INTO r FROM public.tower_activity_rows_241 WHERE audit_id=(p_payload->>'auditId')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'AUDIT_NOT_FOUND';END IF;
  IF upper(r.entity)='BUILDING_CHARGE' AND r.action IN ('EDIT_BUILDING_CHARGE','CANCEL_BUILDING_CHARGE') THEN
   SELECT h.before_state,h.after_state INTO before_data,after_data FROM (
    SELECT history.*,count(*) OVER() matches FROM public.tower_charge_history_240 history
    WHERE history.charge_id::text=r.entity_id AND history.actor_id=r.actor_id AND history.created_at=r.at AND history.action=CASE WHEN r.action='EDIT_BUILDING_CHARGE' THEN 'edit' ELSE 'cancel' END
   ) h WHERE h.matches=1 AND (SELECT count(*) FROM public.tower_audit other WHERE other.entity=r.entity AND other.entity_id=r.entity_id AND other.actor_id=r.actor_id AND other.at=r.at AND other.action=r.action)=1;
  END IF;
  RETURN jsonb_build_object('auditId',r.audit_id,'timestamp',r.at,'action',r.action,'actionLabel',r.action_label,'entity',r.entity,'entityId',r.entity_id,'actorUserId',r.actor_id,'actorDisplayName',r.actor_label,'role',r.actor_role,'unitId',r.unit_id,'unitNumber',r.unit_number,'floor',r.floor,'serviceName',r.service_name,'subjectName',r.subject_label,'category',r.category,'isFinancial',r.is_financial,'notes','','before',before_data,'after',after_data);
 END IF;
 IF p_action<>'page' OR p_action IS NULL THEN RAISE EXCEPTION 'INVALID_OPERATION';END IF;
 query:=public.tower_search_normalize_239(p_payload->>'query');actor_query:=public.tower_search_normalize_239(p_payload->>'actor');kind:=coalesce(p_payload->>'category','ALL');act:=coalesce(p_payload->>'action','');
 IF length(query)>100 OR length(actor_query)>100 OR length(act)>100 OR kind NOT IN ('ALL','FINANCE','PEOPLE','SERVICE','OTHER') OR coalesce(p_payload->>'page','1') !~ '^[0-9]{1,7}$' THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;
 pg:=coalesce((p_payload->>'page')::integer,1);IF pg NOT BETWEEN 1 AND 1000000 THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;
 IF nullif(p_payload->>'from','') IS NOT NULL THEN
  IF p_payload->>'from' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;day_from:=(p_payload->>'from')::date;
 END IF;
 IF nullif(p_payload->>'to','') IS NOT NULL THEN
  IF p_payload->>'to' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;day_to:=(p_payload->>'to')::date;
 END IF;
 IF day_from>day_to THEN RAISE EXCEPTION 'INVALID_ACTIVITY_FILTER';END IF;
 WITH filtered AS (
 SELECT x.* FROM public.tower_activity_rows_241 x WHERE
 (kind='ALL' OR (kind='FINANCE' AND x.is_financial) OR (kind<>'FINANCE' AND x.category=kind)) AND (act='' OR x.action=act)
 AND (day_from IS NULL OR x.at >= day_from::timestamp AT TIME ZONE 'Africa/Cairo') AND (day_to IS NULL OR x.at < (day_to+1)::timestamp AT TIME ZONE 'Africa/Cairo')
 AND NOT EXISTS(SELECT 1 FROM regexp_split_to_table(actor_query,'\s+') t WHERE t<>'' AND position(t IN public.tower_search_normalize_239(concat_ws(' ',x.actor_label,x.actor_id::text)))=0)
 AND NOT EXISTS(SELECT 1 FROM regexp_split_to_table(query,'\s+') t WHERE t<>'' AND position(t IN public.tower_search_normalize_239(concat_ws(' ',x.action_label,x.action,x.entity,x.actor_label,x.service_name,x.unit_number,x.floor,x.subject_label)))=0)
 ), numbered AS (SELECT *,row_number() OVER(ORDER BY at DESC,audit_id DESC) n FROM filtered), stats AS (SELECT count(*)::integer count FROM filtered)
 SELECT count,coalesce((SELECT jsonb_agg(jsonb_build_object('auditId',x.audit_id,'timestamp',x.at,'action',x.action,'actionLabel',x.action_label,'entity',x.entity,'entityId',x.entity_id,'actorUserId',x.actor_id,'actorDisplayName',x.actor_label,'role',x.actor_role,'unitId',x.unit_id,'unitNumber',x.unit_number,'floor',x.floor,'serviceName',x.service_name,'subjectName',x.subject_label,'category',x.category,'isFinancial',x.is_financial) ORDER BY x.at DESC,x.audit_id DESC) FROM numbered x WHERE n>(least(pg,greatest(1,ceil(count/12.0)::integer))-1)*12 AND n<=least(pg,greatest(1,ceil(count/12.0)::integer))*12),'[]') INTO cnt,rows FROM stats;
 pg:=least(pg,greatest(1,ceil(cnt/12.0)::integer));
 SELECT coalesce(jsonb_agg(jsonb_build_object('action',s.action,'label',public.tower_activity_label_241(s.action)) ORDER BY s.action),'[]') INTO opts FROM (SELECT DISTINCT action FROM public.tower_audit ORDER BY action LIMIT 1000) s;
 RETURN jsonb_build_object('scope','ACTIVITY_PAGE','readOnly',true,'pageSize',12,'rows',rows,'page',pg,'pages',greatest(1,ceil(cnt/12.0)::integer),'total',cnt,'actions',opts);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_fund_entry_read_241(p_token text,p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;entry public.tower_fund_entries;linked_payment boolean;linked_task boolean;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 SELECT * INTO entry FROM public.tower_fund_entries WHERE entry_id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ENTRY_NOT_FOUND';END IF;
 SELECT EXISTS(SELECT 1 FROM public.tower_building_payments WHERE fund_entry_id=p_id AND status='ACTIVE'),EXISTS(SELECT 1 FROM public.tower_task_fund_contributions WHERE fund_entry_id=p_id) INTO linked_payment,linked_task;
 RETURN jsonb_build_object('entryId',entry.entry_id,'entryDate',entry.created_at,'entryType',entry.entry_type,'category',entry.category,'description',entry.description,'amount',entry.amount,'status',entry.status,'reference',entry.reference,'canCancel',entry.status='ACTIVE' AND NOT linked_payment AND NOT linked_task,'linkedPayment',linked_payment,'linkedTask',linked_task);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_report_metadata_241(p_token text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE actor public.tower_users;units jsonb;subscriptions jsonb;
BEGIN
 SELECT * INTO actor FROM public.tower_session_user(p_token);
 IF NOT FOUND OR actor.status<>'ACTIVE' OR actor.must_change_pin THEN RAISE EXCEPTION 'SESSION_REQUIRED';END IF;
 IF actor.role NOT IN ('ADMIN','UNION') THEN RAISE EXCEPTION 'FORBIDDEN';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR jsonb_typeof(p_payload->'unitIds') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload->'subscriptions') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_REPORT_METADATA';END IF;
 IF jsonb_array_length(p_payload->'unitIds')>5000 OR jsonb_array_length(p_payload->'subscriptions')>5000 THEN RAISE EXCEPTION 'INVALID_REPORT_METADATA';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('unitId',u.unit_id,'unitNumber',u.unit_number,'floor',u.floor,'unitTypeName',t.name,'managerName',coalesce((SELECT public.tower_person_label_231(mu.name,mu.title,mu.user_id) FROM public.tower_members m JOIN public.tower_users mu ON mu.user_id=m.user_id WHERE m.unit_id=u.unit_id AND m.member_role='MANAGER' AND m.ended_at IS NULL LIMIT 1),'غير معين'))),'[]') INTO units FROM public.tower_units u LEFT JOIN public.tower_unit_types t ON t.unit_type_id=u.unit_type_id WHERE u.unit_id::text IN (SELECT jsonb_array_elements_text(p_payload->'unitIds'));
 WITH inputs AS (SELECT value x,ordinality n FROM jsonb_array_elements(p_payload->'subscriptions') WITH ORDINALITY),candidates AS (
 SELECT i.n,s.service_id,s.service_kind,s.pricing_mode
 FROM inputs i JOIN public.tower_service_subscriptions sub ON
 CASE WHEN coalesce(i.x->>'subscriptionId','')<>'' THEN sub.subscription_id::text=i.x->>'subscriptionId'
 ELSE sub.unit_id::text=i.x->>'unitId' AND (CASE WHEN coalesce(i.x->>'serviceId','')<>'' THEN sub.service_id::text=i.x->>'serviceId' ELSE true END) END
 JOIN public.tower_services s ON s.service_id=sub.service_id
 WHERE (coalesce(i.x->>'serviceId','')<>'' OR coalesce(i.x->>'subscriptionId','')<>'' OR s.name=i.x->>'serviceName')
 ),matches AS (SELECT n,min(service_id::text)::uuid service_id,min(service_kind) service_kind,min(pricing_mode) pricing_mode,count(DISTINCT service_id) cnt FROM candidates GROUP BY n) SELECT coalesce(jsonb_agg(jsonb_build_object('index',n-1,'serviceId',service_id,'serviceKind',service_kind,'pricingMode',pricing_mode)),'[]') INTO subscriptions FROM matches WHERE cnt=1;
 RETURN jsonb_build_object('scope','REPORT_LABELS_ONLY','units',units,'subscriptions',subscriptions);
END $f$;
REVOKE ALL ON FUNCTION public.tower_activity_kind_241(text,text),public.tower_activity_label_241(text),public.tower_activity_read_241(text,text,jsonb),public.tower_fund_entry_read_241(text,uuid),public.tower_report_metadata_241(text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.tower_activity_read_241(text,text,jsonb),public.tower_fund_entry_read_241(text,uuid),public.tower_report_metadata_241(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*
___________________________

Tower App V2.5.185 - SQL_241.

Code End
*/
