/* Tower App V2.5.174 — SQL231. Requires SQL230. Presentation only; no financial postings. */
BEGIN;
DO $check$ BEGIN IF to_regprocedure('public.tower_task_project_read_230(text,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'SQL230_REQUIRED_BEFORE_SQL231'; END IF; END $check$;
CREATE OR REPLACE FUNCTION public.tower_person_label_231(p_name text,p_title text DEFAULT NULL,p_user uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE n text:=btrim(coalesce(p_name,''));t text:=btrim(coalesce(p_title,''));cnt integer;qualified text;
BEGIN
 IF p_user IS NOT NULL THEN SELECT btrim(name),btrim(coalesce(nullif(custom_title,''),nullif(title,''),'')) INTO n,t FROM public.tower_users WHERE user_id=p_user; END IF;
 IF n IS NULL OR n='' OR n IN ('—','غير محدد','غير معين','عضو','ساكن','حارس','مستخدم غير معروف','لقب غير مسجل','لقب غير محدد') THEN RETURN coalesce(n,'غير محدد'); END IF;
 IF t='' THEN
  SELECT count(DISTINCT btrim(coalesce(nullif(custom_title,''),nullif(title,''),''))||' '||btrim(name)),min(btrim(coalesce(nullif(custom_title,''),nullif(title,''),''))||' '||btrim(name)) INTO cnt,qualified FROM public.tower_users WHERE btrim(coalesce(title,''))||' '||btrim(name)=n OR btrim(coalesce(custom_title,''))||' '||btrim(name)=n;
  IF cnt=1 THEN RETURN qualified; ELSIF cnt>1 THEN RETURN 'لقب غير محدد'; END IF;
  SELECT count(DISTINCT btrim(coalesce(nullif(custom_title,''),nullif(title,''),''))),min(btrim(coalesce(nullif(custom_title,''),nullif(title,''),''))) INTO cnt,t FROM public.tower_users WHERE btrim(name)=n;
  IF cnt>1 THEN RETURN 'لقب غير محدد'; END IF;
 END IF;
 IF coalesce(t,'')='' THEN RETURN 'لقب غير مسجل'; END IF;
 IF n=t OR left(n,length(t)+1)=t||' ' THEN RETURN n; END IF;
 RETURN t||' '||n;
END $f$;
CREATE OR REPLACE FUNCTION public.tower_present_text_231(p_message text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE result text:=p_message;r record;m record;label text;marker text;prefix text:='__TOWER_PERSON_'||replace(gen_random_uuid()::text,'-','')||'_';i integer:=0;j integer;c text;pattern text;markers jsonb:='{}';
BEGIN
 IF result IS NULL OR result='' THEN RETURN result; END IF;
 result:=replace(result,'Islam Sallam. All rights reserved.',prefix||'COPY_1__');result:=replace(result,'© Islam Sallam',prefix||'COPY_2__');result:=replace(result,'Islam Sallam · Tower App',prefix||'COPY_3__');
 -- Protect whole qualified names and replacements until all overlapping names were processed.
 FOR r IN SELECT n FROM (SELECT DISTINCT btrim(name) n FROM public.tower_users WHERE length(btrim(name))>=5 AND btrim(name)~'[[:space:]]') q ORDER BY length(n) DESC,n LOOP
  IF position(r.n IN result)=0 THEN CONTINUE; END IF;
  label:=public.tower_person_label_231(r.n);i:=i+1;marker:=prefix||i||'__';pattern:='';
  FOR j IN 1..length(r.n) LOOP c:=substr(r.n,j,1);IF position(c IN E'.^$|?*+(){}[]\\')>0 THEN pattern:=pattern||chr(92)||c;ELSE pattern:=pattern||c;END IF;END LOOP;
  markers:=markers||jsonb_build_object(marker,jsonb_build_object('name',r.n,'label',label,'pattern',pattern));
  IF position(r.n IN label)>0 THEN result:=replace(result,label,marker);END IF;
 END LOOP;
 FOR m IN SELECT key,value FROM jsonb_each(markers) ORDER BY length(value->>'name') DESC LOOP result:=regexp_replace(result,chr(92)||'m'||(m.value->>'pattern')||chr(92)||'M',m.key,'g');END LOOP;
 FOR m IN SELECT key,value FROM jsonb_each(markers) LOOP result:=replace(result,m.key,m.value->>'label');END LOOP;
 result:=replace(result,prefix||'COPY_1__','Islam Sallam. All rights reserved.');result:=replace(result,prefix||'COPY_2__','© Islam Sallam');result:=replace(result,prefix||'COPY_3__','Islam Sallam · Tower App');
 RETURN result;
END $f$;
CREATE OR REPLACE FUNCTION public.tower_present_names_231(p_value jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE result jsonb:=p_value;item record;out_array jsonb:='[]';val jsonb;title text;person boolean;uid uuid;key_user text;col jsonb;col_index integer;row_value jsonb;new_rows jsonb;new_row jsonb;idx integer;
BEGIN
 IF jsonb_typeof(p_value)='array' THEN FOR item IN SELECT value FROM jsonb_array_elements(p_value) LOOP out_array:=out_array||jsonb_build_array(public.tower_present_names_231(item.value));END LOOP;RETURN out_array;END IF;
 IF jsonb_typeof(p_value)<>'object' THEN RETURN p_value; END IF;
 title:=coalesce(nullif(p_value->>'customTitle',''),nullif(p_value->>'custom_title',''),nullif(p_value->>'preferredTitle',''),nullif(p_value->>'title',''),'');
 person:=(p_value ? 'name') AND ((p_value ? 'userId') OR (p_value ? 'user_id') OR (p_value ? 'loginId') OR (p_value ? 'login_id') OR ((p_value ? 'title') AND (p_value ? 'phone' OR p_value ? 'relation' OR p_value ? 'memberRole' OR p_value ? 'preferredTitle')) OR (p_value->>'role' IN ('ADMIN','UNION','RESIDENT','OPERATOR')));
 FOR item IN SELECT key,value FROM jsonb_each(p_value) LOOP
  val:=item.value;
  IF item.key IN ('actorDisplayName','actorName','actor_display_name','actor_name','approvedByName','approved_by_name','beneficiaryName','beneficiary_name','candidateName','candidate_name','collectorName','collector_name','confirmedByName','confirmed_by_name','counterpartyName','counterparty_name','createdByName','created_by_name','deliveredByName','delivered_by_name','displayName','display_name','managerDisplayName','managerName','manager_display_name','manager_name','memberName','member_name','ownerName','owner_name','payerName','payer_name','receiverName','receiver_name','recipientName','recipient_name','recordedByName','recorded_by_name','requestedByName','requested_by_name','requesterName','requester_name','responsibleName','responsible_name','reviewedByName','reviewed_by_name','senderName','sender_name','userName','user_name') AND jsonb_typeof(val)='string' THEN
   IF item.key IN ('counterpartyName','counterparty_name') AND NOT EXISTS(SELECT 1 FROM public.tower_users person_row WHERE btrim(person_row.name)=btrim(val#>>'{}') OR btrim(person_row.title)||' '||btrim(person_row.name)=btrim(val#>>'{}') OR btrim(person_row.custom_title)||' '||btrim(person_row.name)=btrim(val#>>'{}')) THEN CONTINUE; END IF;
   uid:=NULL;key_user:=NULL;
   IF item.key IN ('displayName','display_name') THEN key_user:=coalesce(p_value->>'userId',p_value->>'user_id');
   ELSIF item.key IN ('responsibleName','beneficiaryName','beneficiary_name') THEN key_user:=coalesce(p_value->>'beneficiaryUserId',p_value->>'beneficiary_user_id');
   ELSIF item.key IN ('managerName','manager_name','managerDisplayName','manager_display_name') THEN key_user:=coalesce(p_value->>'managerUserId',p_value->>'manager_user_id');
   ELSIF item.key IN ('collectorName','collector_name') THEN key_user:=coalesce(p_value->>'collectorId',p_value->>'collectorUserId',p_value->>'collector_id');
   ELSIF item.key IN ('actorName','actorDisplayName','actor_name') THEN key_user:=coalesce(p_value->>'actorUserId',p_value->>'actor_id'); END IF;
   IF key_user~*'^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN uid:=key_user::uuid;END IF;
   result:=jsonb_set(result,ARRAY[item.key],to_jsonb(public.tower_person_label_231(val#>>'{}',CASE WHEN item.key IN ('displayName','display_name') AND person THEN title WHEN item.key IN ('candidateName','candidate_name') THEN coalesce(nullif(p_value->>'candidateCustomTitle',''),nullif(p_value->>'candidate_custom_title',''),p_value->>'candidateTitle',p_value->>'candidate_title') ELSE NULL END,uid)));
  ELSIF item.key IN ('memberNames','member_names') AND jsonb_typeof(val)='array' THEN
   out_array:='[]';FOR col IN SELECT value FROM jsonb_array_elements(val) LOOP out_array:=out_array||jsonb_build_array(public.tower_person_label_231(col#>>'{}'));END LOOP;result:=jsonb_set(result,ARRAY[item.key],out_array);
  ELSIF item.key IN ('message','body','text','caption','title') AND jsonb_typeof(val)='string' AND (p_value ? 'notificationId' OR p_value ? 'notification_id' OR p_value ? 'notificationType') THEN
   result:=jsonb_set(result,ARRAY[item.key],to_jsonb(public.tower_present_text_231(val#>>'{}')));
  ELSIF jsonb_typeof(val) IN ('object','array') THEN result:=jsonb_set(result,ARRAY[item.key],public.tower_present_names_231(val));END IF;
 END LOOP;
 IF person THEN
  key_user:=coalesce(p_value->>'userId',p_value->>'user_id');uid:=NULL;IF key_user~*'^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' THEN uid:=key_user::uuid;END IF;
  result:=result||jsonb_build_object('displayName',public.tower_person_label_231(p_value->>'name',title,uid));
 END IF;
 -- Legacy tabular reports carry names in cells instead of named properties.
 IF jsonb_typeof(p_value->'columns')='array' AND jsonb_typeof(p_value->'rows')='array' THEN
  new_rows:='[]';FOR row_value IN SELECT value FROM jsonb_array_elements(result->'rows') LOOP
   new_row:=row_value;col_index:=0;
   FOR col IN SELECT value FROM jsonb_array_elements(p_value->'columns') LOOP
    IF coalesce(col->>'label',col#>>'{}')~'(مدير الوحدة|اسم الشخص|اسم العضو|المسؤول|المحصّل|المحصل|المستلم|المستخدم|مدير الحساب)' AND jsonb_typeof(row_value->col_index)='string' THEN
     new_row:=jsonb_set(new_row,ARRAY[col_index::text],to_jsonb(public.tower_person_label_231(row_value->>col_index)));
    END IF;col_index:=col_index+1;
   END LOOP;new_rows:=new_rows||jsonb_build_array(new_row);
  END LOOP;result:=jsonb_set(result,'{rows}',new_rows);
 END IF;
 RETURN result;
END $f$;
CREATE OR REPLACE FUNCTION public.tower_task_workspace_read_231(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE result jsonb;rows jsonb;
BEGIN
 result:=public.tower_task_project_read_230(p_token,p_service,p_unit);
 SELECT coalesce(jsonb_agg(x||jsonb_build_object('balance',coalesce(x->'balance','{}'::jsonb)||jsonb_build_object('state',CASE WHEN EXISTS(SELECT 1 FROM public.tower_finance_dues d WHERE d.subscription_id=(x->>'subscriptionId')::uuid AND d.status='OPEN') OR EXISTS(SELECT 1 FROM public.tower_task_allocation_snapshots sn WHERE sn.subscription_id=(x->>'subscriptionId')::uuid) THEN 'RECORDED' ELSE 'NOT_RECORDED' END),'floor',u.floor,'managerName',(SELECT public.tower_person_label_231(us.name,coalesce(nullif(us.custom_title,''),us.title),us.user_id) FROM public.tower_members m JOIN public.tower_users us ON us.user_id=m.user_id WHERE m.unit_id=u.unit_id AND m.member_role='MANAGER' AND m.ended_at IS NULL ORDER BY us.user_id LIMIT 1))),'[]') INTO rows
 FROM jsonb_array_elements(result->'subscriptions') x LEFT JOIN public.tower_units u ON u.unit_id=(x->>'unitId')::uuid;
 result:=jsonb_set(result,'{subscriptions}',rows);
 IF p_unit IS NOT NULL THEN result:=result||jsonb_build_object('unitId',p_unit,'unitNumber',(SELECT unit_number FROM public.tower_units WHERE unit_id=p_unit));END IF;
 RETURN public.tower_present_names_231(result);
END $f$;
CREATE OR REPLACE FUNCTION public.tower_task_workspace_installments_231(p_token text,p_service uuid,p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,public AS $f$
DECLARE workspace jsonb;result jsonb;rows jsonb;
BEGIN
 workspace:=public.tower_task_workspace_read_231(p_token,p_service,p_unit);
 result:=public.tower_task_installments_action(p_token,p_service,'list');
 IF NOT coalesce((workspace->>'canManage')::boolean,false) THEN
  SELECT coalesce(jsonb_agg(x),'[]') INTO rows FROM jsonb_array_elements(result->'rows') x WHERE x->>'unitId'=p_unit::text;
  result:=jsonb_set(result,'{rows}',rows)||jsonb_build_object('hasPlan',jsonb_array_length(rows)>0,'hasPayments',coalesce((SELECT sum((x#>>'{balance,paid}')::numeric)>0 FROM jsonb_array_elements(workspace->'subscriptions') x),false),'noPlanNeeded',coalesce((SELECT sum((x#>>'{balance,due}')::numeric)=0 FROM jsonb_array_elements(workspace->'subscriptions') x),true));
 END IF;
 RETURN result;
END $f$;
REVOKE ALL ON FUNCTION public.tower_task_workspace_installments_231(text,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_task_workspace_installments_231(text,uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.tower_person_label_231(text,text,uuid) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.tower_present_names_231(jsonb),public.tower_present_text_231(text),public.tower_task_workspace_read_231(text,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tower_present_names_231(jsonb),public.tower_present_text_231(text),public.tower_task_workspace_read_231(text,uuid,uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
/*__________________________________ End of code...*/
