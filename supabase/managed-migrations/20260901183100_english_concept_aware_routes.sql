-- English V2 concept-aware learning routes.
-- One concept is the unit of selection; question history remains intact.

create or replace function english.concept_dedupe_payload(p_user_id uuid,p_raw jsonb,p_limit integer default 30) returns jsonb
language sql stable security definer set search_path=pg_catalog,english as $$
with elems as (
  select e.value item,e.ord::int ord,
    coalesce(nullif(e.value->>'id',''),nullif(e.value->>'question_id',''),nullif(e.value->>'questionId',''),
      nullif(e.value->>'centralQuestionId',''),nullif(e.value->>'central_question_id','')) qid
  from jsonb_array_elements(coalesce(p_raw,'[]'::jsonb)) with ordinality e(value,ord)
), enriched as (
  select x.*,m.concept_id,ce.coverage_state concept_state,ce.confidence_score concept_confidence,
    ce.next_review concept_next_review,
    row_number() over(partition by coalesce(m.concept_id,x.qid,'raw:'||x.ord::text) order by
      case coalesce(ce.coverage_state,'unseen') when 'weak' then 6 when 'retention_risk' then 5
        when 'seen' then 4 when 'unseen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      coalesce(ce.confidence_score,0) asc,x.ord) rn
  from elems x
  left join english.question_concept_mappings m on m.question_id=x.qid
  left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
)
select coalesce(jsonb_agg(item||jsonb_strip_nulls(jsonb_build_object(
  'conceptId',concept_id,'conceptCoverage',concept_state,'conceptConfidence',concept_confidence,'conceptNextReview',concept_next_review
)) order by ord),'[]'::jsonb)
from (select * from enriched where rn=1 order by ord limit greatest(1,least(1000,coalesce(p_limit,30)))) d;
$$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer) returns integer
language plpgsql security definer set search_path=pg_catalog,english,auth as $$
declare v_target integer:=greatest(1,least(120,coalesce(p_target,120))); v_reason text; v_take integer; v_inserted integer; v_count integer:=0;
begin
  create temporary table if not exists pg_temp.ep_daily_candidates(
    question_id text primary key,concept_key text,concept_id text,concept_state text,concept_confidence numeric,
    concept_next_review timestamptz,reason text,score numeric,priority integer,signals text[],snapshot jsonb
  ) on commit drop;
  truncate pg_temp.ep_daily_candidates;

  insert into pg_temp.ep_daily_candidates(question_id,concept_key,concept_id,concept_state,concept_confidence,concept_next_review,reason,score,priority,signals,snapshot)
  select q.question_id,coalesce(cm.concept_id,q.question_id),cm.concept_id,coalesce(ce.coverage_state,'unseen'),coalesce(ce.confidence_score,0),ce.next_review,r.reason,
    english.daily_reason_base_score(r.reason)
    +coalesce(cp.penalty,0)*70
    +least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0)))*12
    +case when coalesce(s.last_marked,false) then 12 else 0 end
    +case when coalesce(ds.difficult,false) then 10 else 0 end
    +case coalesce(ce.coverage_state,'unseen') when 'weak' then 220 when 'retention_risk' then 180 when 'seen' then 35 when 'unseen' then 25 when 'secure' then -25 when 'exam_ready' then -110 else 0 end
    +case when ce.next_review is not null and ce.next_review<=now() then 80 else 0 end
    +case coalesce(c.exam_relevance,'medium') when 'high' then 20 when 'low' then -15 else 0 end
    +random()*20,
    english.daily_reason_base_score(r.reason),
    english.daily_signal_codes(r.reason,coalesce(s.status,'New'),
      s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
      coalesce(s.last_marked,false),coalesce(ds.difficult,false),coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)),
    jsonb_build_object('selectedAt',now(),'batchDate',p_batch_date,'state',coalesce(s.status,'New'),'attempts',coalesce(s.attempts,0),
      'correct',coalesce(s.correct,0),'wrong',coalesce(s.wrong,0),'accuracy',coalesce(s.accuracy,0),'nextReview',s.next_review,
      'starred',coalesce(s.last_marked,false),'difficult',coalesce(ds.difficult,false),'category',english.learning_category(q.topic),
      'categoryPenalty',coalesce(cp.penalty,0),'conceptId',cm.concept_id,'conceptCoverage',coalesce(ce.coverage_state,'unseen'),
      'conceptConfidence',coalesce(ce.confidence_score,0),'conceptNextReview',ce.next_review,
      'daysOverdue',greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0)))
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  left join english.question_concept_mappings cm on cm.question_id=q.question_id
  left join english.concepts c on c.concept_id=cm.concept_id
  left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=cm.concept_id
  left join english.daily_category_penalties(p_user_id) cp on cp.category=english.learning_category(q.topic)
  cross join lateral (select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
  where q.active and english.question_visible_to_user(p_user_id,q.question_id) and not coalesce(s.mastered,false) and r.reason<>''
    and not (p_batch_date=((now() at time zone 'Asia/Kolkata')::date) and exists(
      select 1 from english.attempts a left join english.question_concept_mappings am on am.question_id=a.question_id
      where a.user_id=p_user_id and lower(coalesce(a.module,''))='daily'
        and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
        and coalesce(am.concept_id,a.question_id)=coalesce(cm.concept_id,q.question_id)));

  foreach v_reason in array array['Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Mixed Revision'] loop
    exit when v_count>=v_target;
    v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);
    with base as (
      select c.*,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_pick
      from pg_temp.ep_daily_candidates c where c.reason=v_reason
        and not exists(select 1 from english.daily_current d left join english.question_concept_mappings dm on dm.question_id=d.question_id
          where d.user_id=p_user_id and coalesce(dm.concept_id,d.question_id)=c.concept_key)
    ), pick as (select * from base where concept_pick=1 order by score desc limit v_take)
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,p.question_id,v_count+row_number() over(order by p.score desc)::int,round(p.score)::int,p.reason,p_batch_date,'New',q.topic,
      coalesce(p.concept_id,q.concept_id),p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id order by p.score desc;
    get diagnostics v_inserted=row_count; v_count:=v_count+v_inserted;
  end loop;

  if v_count<v_target then
    with existing as (select reason,count(*) n from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date group by reason),
    ranked as (
      select c.*,row_number() over(partition by c.reason order by c.score desc) reason_rn,
        row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn
      from pg_temp.ep_daily_candidates c
      where not exists(select 1 from english.daily_current d left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and coalesce(dm.concept_id,d.question_id)=c.concept_key)
    ), eligible as (
      select r.* from ranked r left join existing e on e.reason=r.reason
      where r.concept_rn=1 and r.reason_rn<=greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0))
      order by r.score desc limit (v_target-v_count)
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,e.question_id,v_count+row_number() over(order by e.score desc)::int,round(e.score)::int,e.reason,p_batch_date,'New',q.topic,
      coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id order by e.score desc;
    get diagnostics v_inserted=row_count; v_count:=v_count+v_inserted;
  end if;
  return v_count;
end $$;

create or replace function public.english_get_revision_batch(p_mode text default 'smart',p_count integer default 30) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); m text:=lower(btrim(coalesce(p_mode,'smart'))); n integer:=greatest(1,least(100,coalesce(p_count,30))); outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if m not in ('smart','due','weak','recall','difficult','random') then raise exception 'Unknown revision mode: %',p_mode; end if;
  with base as (
    select q.question_id,coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
      coalesce(d.difficult,false) difficult,coalesce(s.last_marked,false) starred,s.last_attempt,s.next_review,
      (s.next_review is not null and s.next_review<=(((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due,
      coalesce(cm.concept_id,q.question_id) concept_key,cm.concept_id,coalesce(ce.coverage_state,'unseen') concept_state,
      coalesce(ce.confidence_score,0) concept_confidence,ce.next_review concept_next_review,(ce.next_review is not null and ce.next_review<=now()) concept_due
    from english.questions q
    left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
    left join english.difficult_state d on d.user_id=uid and d.question_id=q.question_id
    left join english.question_concept_mappings cm on cm.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=cm.concept_id
    where q.active and not coalesce(s.mastered,false)
      and not exists(select 1 from english.learning_route_state r where r.user_id=uid and r.question_id=q.question_id and r.route='fast_track')
  ), filtered as (
    select * from base where
      (m='smart' and attempts>0 and (due or concept_due or status in ('Persistent Weak','Weak','Fragile') or concept_state in ('weak','retention_risk') or difficult))
      or (m='due' and attempts>0 and (due or concept_due))
      or (m='weak' and (status in ('Persistent Weak','Weak','Fragile') or concept_state in ('weak','retention_risk')))
      or (m='recall' and attempts>0 and concept_state in ('secure','exam_ready','retention_risk') and concept_due)
      or (m='difficult' and difficult) or m='random'
  ), scored as (
    select *,case concept_state when 'weak' then 12 when 'retention_risk' then 11 when 'seen' then 6 when 'unseen' then 5 when 'secure' then 3 when 'exam_ready' then 1 else 4 end concept_rank,
      row_number() over(partition by concept_key order by case when m='random' then random() else 0 end,
        case when status='Persistent Weak' and due then 10 when status='Persistent Weak' then 9 when status='Weak' and due then 8 when status='Weak' then 7
          when status='Fragile' and due then 6 when due then 5 when status='Fragile' then 4 when difficult then 3 when status='Learning' then 2 else 1 end desc,
        wrong desc,coalesce(next_review,'infinity'::timestamptz),coalesce(last_attempt,'epoch'::timestamptz),question_id) concept_pick
    from filtered
  ), ranked as (
    select *,row_number() over(order by case when m='random' then random() else 0 end,concept_rank desc,concept_due desc,
      case when status='Persistent Weak' and due then 10 when status='Persistent Weak' then 9 when status='Weak' and due then 8 when status='Weak' then 7
        when status='Fragile' and due then 6 when due then 5 when status='Fragile' then 4 when difficult then 3 when status='Learning' then 2 else 1 end desc,
      difficult desc,wrong desc,coalesce(concept_next_review,next_review,'infinity'::timestamptz),coalesce(last_attempt,'epoch'::timestamptz),question_id)::int ord
    from scored where concept_pick=1
  ), chosen as (select * from ranked order by ord limit n)
  select coalesce(jsonb_agg(english.question_payload(uid,c.question_id)||jsonb_build_object(
    'centralRevisionMode',m,'centralRevisionSignals',english.central_revision_signals(c.status,c.due,c.difficult,c.starred,c.wrong,c.next_review),
    'centralRevisionReason',case when c.concept_state='weak' then 'Weak Concept' when c.concept_state='retention_risk' then 'Concept Retention Risk'
      when m='recall' then 'Concept Retention Check' when c.status='Persistent Weak' then 'Persistent Weak' when c.status='Weak' then 'Weak'
      when c.status='Fragile' then 'Fragile' when c.due or c.concept_due then 'Due Spaced Revision' when c.difficult then 'Difficult' else 'Recall Rotation' end,
    'conceptId',c.concept_id,'conceptCoverage',c.concept_state,'conceptConfidence',c.concept_confidence,'conceptNextReview',c.concept_next_review
  ) order by c.ord),'[]'::jsonb) into outv from chosen c;
  return outv;
end $$;

create or replace function public.english_get_fast_track_batch(p_count integer default 30,p_origin text default null) returns jsonb
language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with base as (
  select x.*,case when x.fast_track_status='retention_watch' then 0 when x.fast_track_status='ready' then 1 else 2 end wait_ord,
    coalesce(cm.concept_id,x.question_id) concept_key,cm.concept_id,coalesce(ce.coverage_state,'unseen') concept_state,
    coalesce(ce.confidence_score,0) concept_confidence,ce.next_review concept_next_review
  from english.learning_route_state x
  left join english.question_concept_mappings cm on cm.question_id=x.question_id
  left join english.concept_evidence ce on ce.user_id=x.user_id and ce.concept_id=cm.concept_id
  where x.user_id=auth.uid() and x.route='fast_track' and x.fast_track_status<>'mastered'
    and (x.fast_track_status='ready' or (x.fast_track_status in ('waiting','retention_watch') and x.next_fast_track_check<=now()))
    and (p_origin is null or p_origin=any(x.origins)) and nullif(english.route_targeted_reason(auth.uid(),x.question_id),'') is null
), deduped as (
  select *,row_number() over(partition by concept_key order by
    case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
    wait_ord,next_fast_track_check nulls first,updated_at,question_id) concept_pick from base
), r as (
  select * from deduped where concept_pick=1 order by
    case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
    wait_ord,next_fast_track_check nulls first,updated_at,question_id limit greatest(1,least(100,coalesce(p_count,30)))
)
select coalesce(jsonb_agg(english.question_payload(auth.uid(),r.question_id)||jsonb_build_object(
  'fastTrack',true,'fastTrackStatus',r.fast_track_status,'fastTrackOrigins',r.origins,'fastTrackReason',r.last_route_reason,
  'fastTrackNextCheck',r.next_fast_track_check,'fastTrackFailureDecision',r.pending_failure_decision,'retentionWatch',(r.fast_track_status='retention_watch'),
  'conceptId',r.concept_id,'conceptCoverage',r.concept_state,'conceptConfidence',r.concept_confidence,'conceptNextReview',r.concept_next_review
) order by case r.concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
  r.wait_ord,r.next_fast_track_check nulls first,r.question_id),'[]'::jsonb) from r;
$$;

create or replace function public.english_get_saved_revision_batch(p_mode text default 'smart',p_count integer default 20) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); m text:=lower(btrim(coalesce(p_mode,'smart'))); n integer:=greatest(1,least(100,coalesce(p_count,20))); candidate_n integer; raw jsonb; outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if m='new' then
    with b as (
      select c.*,coalesce(qm.concept_id,scm.concept_id,c.question_id) concept_key,coalesce(qm.concept_id,scm.concept_id) concept_id,
        ce.coverage_state concept_state,ce.confidence_score concept_confidence,
        row_number() over(partition by coalesce(qm.concept_id,scm.concept_id,c.question_id) order by c.created_at desc nulls last,c.question_id) rn
      from english.saved_revision_candidates(uid) c
      left join english.saved_items si on si.user_id=uid and si.practice_question_id=c.question_id
      left join english.saved_concept_mappings scm on scm.saved_id=si.saved_id and scm.user_id=uid
      left join english.question_concept_mappings qm on qm.question_id=c.question_id
      left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=coalesce(qm.concept_id,scm.concept_id)
      where not c.mastered and c.never_revised
    )
    select coalesce(jsonb_agg(j order by created_at desc nulls last),'[]'::jsonb) into outv from (
      select english.question_payload(uid,b.question_id)||jsonb_strip_nulls(jsonb_build_object(
        'smartMySaved',true,'smartMySavedLane','new','smartMySavedReason','Never Revised in My Saved',
        'conceptId',b.concept_id,'conceptCoverage',b.concept_state,'conceptConfidence',b.concept_confidence)) j,b.created_at
      from b where rn=1 order by b.created_at desc nulls last,b.question_id limit n
    ) x;
    return outv;
  end if;
  if m not in ('smart','weak','difficult','starred','random','all') then raise exception 'Unknown My Saved mode: %',p_mode; end if;
  candidate_n:=least(100,greatest(n,n*4));
  raw:=public.english_get_saved_revision_batch_core_20260830(m,candidate_n);
  if m<>'all' then raw:=english.concept_dedupe_payload(uid,raw,candidate_n); end if;
  return english.rotate_fresh_batch(uid,'mySavedRevision',raw,n,90);
end $$;

create or replace function public.english_get_starred_batch(p_mode text default 'smart',p_count integer default 20,p_from_day integer default null,p_to_day integer default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); n integer:=greatest(1,least(50,coalesce(p_count,20))); raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_starred_batch_core_20260830(p_mode,least(50,greatest(n,n*4)),p_from_day,p_to_day);
  if lower(btrim(coalesce(p_mode,'smart')))<>'all' then raw:=english.concept_dedupe_payload(uid,raw,50); end if;
  return english.rotate_fresh_batch(uid,'starredRevision',raw,n,90);
end $$;

create or replace function public.english_get_route_view(
  p_route text,p_origin text default null,p_status text default null,p_category text default null,p_limit integer default 100,p_offset integer default 0
) returns jsonb
language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), params as (
 select lower(btrim(coalesce(p_route,''))) route,nullif(btrim(coalesce(p_origin,'')),'') origin,
        nullif(lower(btrim(coalesce(p_status,''))),'') status,nullif(lower(btrim(coalesce(p_category,''))),'') category
), saved as (
 select distinct si.practice_question_id question_id from english.saved_items si cross join uid
 where si.user_id=uid.id and si.active and nullif(btrim(si.practice_question_id),'') is not null
), raw_base as (
 select q.question_id,q.topic,english.learning_category(q.topic) category,r.route,r.fast_track_status,r.origins,r.entered_fast_track_at,
   r.next_fast_track_check,r.fast_track_mastered_at,r.last_route_reason,r.updated_at,coalesce(s.status,'New') learning_status,
   coalesce(s.mastered,false) mastered,coalesce(s.wrong,0) wrong,coalesce(d.difficult,false) difficult,cm.concept_id,
   coalesce(ce.coverage_state,'unseen') concept_state,coalesce(ce.confidence_score,0) concept_confidence,ce.next_review concept_next_review,
   p.route requested_route,
   case when p.route='fast_track' then lower(coalesce(r.fast_track_status,'ready'))
     when p.route='targeted' then lower(case when coalesce(d.difficult,false) then 'Difficult' else coalesce(s.status,'Learning') end)
     else 'unclassified' end view_status
 from english.questions q cross join uid cross join params p
 left join english.learning_route_state r on r.user_id=uid.id and r.question_id=q.question_id
 left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=q.question_id
 left join english.question_concept_mappings cm on cm.question_id=q.question_id
 left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=cm.concept_id
 where uid.id is not null and q.active and (
   (p.route in ('fast_track','targeted') and r.route=p.route and english.route_origin_matches(r.origins,p.origin))
   or (p.route='unclassified' and q.question_id in (select question_id from saved)
       and (r.route is null or r.route in ('unclassified','starred_unresolved')) and (p.origin is null or p.origin='From My Saved')))
), deduped as (
 select rb.*,row_number() over(partition by case when rb.requested_route='targeted' then coalesce(rb.concept_id,rb.question_id) else rb.question_id end order by
   case rb.concept_state when 'weak' then 6 when 'retention_risk' then 5 when 'seen' then 4 when 'unseen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
   rb.difficult desc,rb.wrong desc,rb.updated_at desc nulls last,rb.question_id) concept_pick from raw_base rb
), base as (select * from deduped where requested_route<>'targeted' or concept_pick=1),
filtered as (select b.* from base b cross join params p where (p.status is null or b.view_status=p.status) and (p.category is null or lower(b.category)=p.category)),
statuses as (select view_status,count(*)::int n from base group by view_status order by n desc,view_status),
categories as (select category,count(*)::int n from base group by category order by n desc,category),
page as (
 select * from filtered order by
   case when requested_route='targeted' then case concept_state when 'weak' then 1 when 'retention_risk' then 2 when 'seen' then 3 when 'unseen' then 4 when 'secure' then 5 when 'exam_ready' then 6 else 4 end else 0 end,
   case view_status when 'ready' then 1 when 'waiting' then 2 when 'persistent weak' then 3 when 'weak' then 4 when 'fragile' then 5 when 'difficult' then 6 when 'mastered' then 9 else 7 end,
   concept_next_review nulls first,updated_at desc nulls last,question_id
 limit greatest(1,least(250,coalesce(p_limit,100))) offset greatest(0,coalesce(p_offset,0))
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'route',(select route from params),'origin',(select origin from params),'total',(select count(*) from base),
 'filteredTotal',(select count(*) from filtered),'rawQuestionTotal',(select count(*) from raw_base),
 'statuses',coalesce((select jsonb_agg(jsonb_build_object('status',view_status,'count',n) order by n desc,view_status) from statuses),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('category',category,'count',n) order by n desc,category) from categories),'[]'::jsonb),
 'items',coalesce((select jsonb_agg(english.question_payload((select id from uid),p.question_id)||jsonb_build_object(
   'learningRoute',coalesce(p.route,'unclassified'),'viewStatus',p.view_status,'fastTrackStatus',p.fast_track_status,
   'fastTrackOrigins',coalesce(p.origins,'{}'::text[]),'fastTrackReason',p.last_route_reason,'fastTrackEnteredAt',p.entered_fast_track_at,
   'fastTrackNextCheck',p.next_fast_track_check,'fastTrackMasteredAt',p.fast_track_mastered_at,'learningStatus',p.learning_status,
   'wrong',p.wrong,'difficult',p.difficult,'conceptId',p.concept_id,'conceptCoverage',p.concept_state,
   'conceptConfidence',p.concept_confidence,'conceptNextReview',p.concept_next_review,
   'routeHistory',coalesce((select jsonb_agg(jsonb_build_object('at',e.event_at,'type',e.event_type,'from',e.from_route,'to',e.to_route,'origin',e.origin,'reason',e.reason) order by e.event_at)
     from english.learning_route_events e where e.user_id=(select id from uid) and e.question_id=p.question_id),'[]'::jsonb)
 ) order by case when p.requested_route='targeted' then case p.concept_state when 'weak' then 1 when 'retention_risk' then 2 when 'seen' then 3 when 'unseen' then 4 when 'secure' then 5 when 'exam_ready' then 6 else 4 end else 0 end,
 p.updated_at desc nulls last,p.question_id) from page p),'[]'::jsonb)
) end;
$$;
