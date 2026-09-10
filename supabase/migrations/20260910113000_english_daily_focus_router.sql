-- Daily Focus is an execution layer over existing intelligence. It does not replace
-- Starred, My Saved, Bank Coverage, or Fast Track routing.

create table if not exists english.daily_focus_batches (
  user_id uuid not null,
  batch_date date not null,
  status text not null default 'active' check (status in ('active','completed')),
  repair_target integer not null default 50 check (repair_target between 0 and 50),
  coverage_target integer not null default 50 check (coverage_target between 0 and 50),
  fast_track_target integer not null default 50 check (fast_track_target between 0 and 50),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id,batch_date)
);

create table if not exists english.daily_focus_items (
  user_id uuid not null,
  batch_date date not null,
  lane text not null check (lane in ('repair','coverage','fast_track')),
  sequence integer not null check (sequence between 1 and 50),
  question_id text not null references english.questions(question_id),
  concept_key text not null,
  status text not null default 'New' check (status in ('New','Completed')),
  reasons text[] not null default '{}'::text[],
  selection_snapshot jsonb not null default '{}'::jsonb,
  selected_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (user_id,batch_date,lane,sequence),
  unique (user_id,batch_date,question_id),
  unique (user_id,batch_date,concept_key),
  foreign key (user_id,batch_date) references english.daily_focus_batches(user_id,batch_date) on delete cascade
);

create unique index if not exists daily_focus_one_active_batch_per_user
  on english.daily_focus_batches(user_id) where status='active';
create index if not exists daily_focus_items_resume_idx
  on english.daily_focus_items(user_id,batch_date,lane,status,sequence);

alter table english.daily_focus_batches enable row level security;
alter table english.daily_focus_items enable row level security;

create or replace function english.focus_concept_key(p_question_id text)
returns text
language sql stable security definer
set search_path='pg_catalog','english','auth'
as $function$
select coalesce(
  (select min(nullif(m.concept_id,'')) from english.question_concept_mappings m where m.question_id=p_question_id),
  nullif(q.concept_id,''),q.question_id
)
from english.questions q where q.question_id=p_question_id;
$function$;

create or replace function english.focus_conflicts_with_required_daily(p_user_id uuid,p_question_id text,p_batch_date date)
returns boolean
language sql stable security definer
set search_path='pg_catalog','english','auth'
as $function$
select exists(select 1 from english.daily_current d where d.user_id=p_user_id and d.question_id=p_question_id)
  or exists(select 1 from english.grammar_daily_items g where g.batch_date=p_batch_date and g.question_id=p_question_id)
  or exists(select 1 from english.phrasal_daily_items p where p.batch_date=p_batch_date and p.question_id=p_question_id);
$function$;

create or replace function english.create_daily_focus(p_user_id uuid,p_batch_date date)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_repair integer:=0; v_coverage integer:=0; v_fast integer:=0; v_need integer:=0;
begin
  if p_user_id is null or p_batch_date is null then raise exception 'user and batch date are required'; end if;

  insert into english.daily_focus_batches(user_id,batch_date,status)
  values(p_user_id,p_batch_date,'active') on conflict(user_id,batch_date) do nothing;

  if exists(select 1 from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date) then
    select count(*) filter(where lane='repair'),count(*) filter(where lane='coverage'),count(*) filter(where lane='fast_track')
      into v_repair,v_coverage,v_fast
    from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date;
    return jsonb_build_object('ok',true,'existing',true,'repair',v_repair,'coverage',v_coverage,'fastTrack',v_fast);
  end if;

  -- Repair: front-load highest-risk Weak/PW evidence.
  with ranked as (
    select q.question_id,english.focus_concept_key(q.question_id) concept_key,s.status,s.next_review,s.last_attempt,
      array_remove(array[
        case when s.status='Persistent Weak' then 'Persistent Weak' when s.status='Weak' then 'Weak' end,
        case when english.route_has_active_star(p_user_id,q.question_id) then 'Starred' end,
        case when english.route_is_saved(p_user_id,q.question_id) then 'My Saved' end
      ],null) reasons,
      row_number() over(partition by english.focus_concept_key(q.question_id)
        order by case s.status when 'Persistent Weak' then 0 else 1 end,s.next_review nulls first,s.last_attempt nulls first,q.question_id) concept_pick
    from english.question_state s
    join english.questions q on q.question_id=s.question_id and q.active
    where s.user_id=p_user_id and s.status in ('Persistent Weak','Weak') and not coalesce(s.mastered,false)
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=q.question_id and r.route='fast_track')
  ), chosen as (
    select * from ranked where concept_pick=1
    order by case status when 'Persistent Weak' then 0 else 1 end,next_review nulls first,last_attempt nulls first,question_id limit 20
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'repair',row_number() over(order by case status when 'Persistent Weak' then 0 else 1 end,next_review nulls first,last_attempt nulls first,question_id)::int,
    question_id,concept_key,reasons,jsonb_build_object('source','central_intelligence','repairSource','weak','state',status)
  from chosen on conflict do nothing;

  -- Repair: reserve room for Starred Intelligence.
  with base as (
    select c.*,q.question_id qid,english.focus_concept_key(q.question_id) concept_key,
      array_remove(array['Starred',case when c.state in ('Persistent Weak','Weak') then c.state end],null) reasons
    from english.starred_revision_candidates(p_user_id) c
    join english.questions q on q.question_id=c.question_id and q.active
    where not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=q.question_id or f.concept_key=english.focus_concept_key(q.question_id)))
      and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=q.question_id and r.route='fast_track')
  ), chosen as (
    select * from base order by due desc,difficult desc,never_revised desc,days_since_revision desc nulls last,qid limit 15
  ), numbered as (
    select *,coalesce((select max(sequence) from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='repair'),0)
      + row_number() over(order by due desc,difficult desc,never_revised desc,days_since_revision desc nulls last,qid)::int seq from chosen
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'repair',seq,qid,concept_key,reasons,
    jsonb_build_object('source','starred_intelligence','repairSource','starred','due',due,'difficult',difficult,'neverRevised',never_revised)
  from numbered where seq<=50 on conflict do nothing;

  -- Repair: reserve room for My Saved Intelligence.
  with base as (
    select c.*,q.question_id qid,english.focus_concept_key(q.question_id) concept_key,
      array_remove(array['My Saved',case when c.state in ('Persistent Weak','Weak') then c.state end,case when c.starred then 'Starred' end],null) reasons
    from english.saved_revision_candidates(p_user_id) c
    join english.questions q on q.question_id=c.question_id and q.active
    where not c.mastered
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=q.question_id or f.concept_key=english.focus_concept_key(q.question_id)))
      and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=q.question_id and r.route='fast_track')
  ), chosen as (
    select * from base order by due desc,difficult desc,starred desc,never_revised desc,days_since_revision desc nulls last,created_at desc nulls last,qid limit 15
  ), numbered as (
    select *,coalesce((select max(sequence) from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='repair'),0)
      + row_number() over(order by due desc,difficult desc,starred desc,never_revised desc,days_since_revision desc nulls last,created_at desc nulls last,qid)::int seq from chosen
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'repair',seq,qid,concept_key,reasons,
    jsonb_build_object('source','saved_intelligence','repairSource','saved','due',due,'difficult',difficult,'starred',starred,'neverRevised',never_revised)
  from numbered where seq<=50 on conflict do nothing;

  select greatest(0,50-count(*)) into v_need from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='repair';
  if v_need>0 then
    with unioned as (
      select q.question_id,english.focus_concept_key(q.question_id) concept_key,
        case s.status when 'Persistent Weak' then 1000 when 'Weak' then 900 else 0 end score,
        case s.status when 'Persistent Weak' then 'Persistent Weak' else 'Weak' end source
      from english.question_state s join english.questions q on q.question_id=s.question_id and q.active
      where s.user_id=p_user_id and s.status in ('Persistent Weak','Weak') and not coalesce(s.mastered,false)
      union all
      select c.question_id,english.focus_concept_key(c.question_id),case when c.due then 820 else 700 end,'Starred'
      from english.starred_revision_candidates(p_user_id) c
      union all
      select c.question_id,english.focus_concept_key(c.question_id),case when c.due then 800 else 680 end,'My Saved'
      from english.saved_revision_candidates(p_user_id) c where not c.mastered
    ), grouped as (
      select u.question_id,u.concept_key,max(u.score) score,array_agg(distinct u.source) reasons
      from unioned u join english.questions q on q.question_id=u.question_id and q.active
      where u.concept_key is not null
        and not english.focus_conflicts_with_required_daily(p_user_id,u.question_id,p_batch_date)
        and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=u.question_id or f.concept_key=u.concept_key))
        and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=u.question_id and r.route='fast_track')
      group by u.question_id,u.concept_key order by max(u.score) desc,u.question_id limit v_need
    ), numbered as (
      select *,coalesce((select max(sequence) from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='repair'),0)
        + row_number() over(order by score desc,question_id)::int seq from grouped
    )
    insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
    select p_user_id,p_batch_date,'repair',seq,question_id,concept_key,reasons,
      jsonb_build_object('source','central_intelligence','repairSource','priority_fill','score',score)
    from numbered where seq<=50 on conflict do nothing;
  end if;

  -- Coverage 1: 20 previously encountered canonical concepts that are still incomplete.
  with raw as (
    select q.question_id,english.focus_concept_key(q.question_id) concept_key,s.status,s.last_attempt,s.next_review,ce.coverage_state,ce.confidence_score,
      row_number() over(partition by english.focus_concept_key(q.question_id)
        order by case s.status when 'Fragile' then 0 when 'Learning' then 1 else 2 end,s.next_review nulls first,s.last_attempt nulls first,q.question_id) concept_pick
    from english.questions q
    join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id)
    where english.is_genuine_bank_question(q) and coalesce(s.attempts,0)>0 and not coalesce(s.mastered,false)
      and s.status not in ('Persistent Weak','Weak')
      and coalesce(ce.coverage_state,'seen') not in ('secure','exam_ready')
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=q.question_id or f.concept_key=english.focus_concept_key(q.question_id)))
      and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=q.question_id and r.route='fast_track')
  ), chosen as (
    select * from raw where concept_pick=1 order by case status when 'Fragile' then 0 when 'Learning' then 1 else 2 end,next_review nulls first,last_attempt nulls first,question_id limit 20
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'coverage',row_number() over(order by case status when 'Fragile' then 0 when 'Learning' then 1 else 2 end,next_review nulls first,last_attempt nulls first,question_id)::int,
    question_id,concept_key,array['Previously Seen','Coverage Incomplete'],
    jsonb_strip_nulls(jsonb_build_object('source','central_intelligence','coverageKind','familiar','state',status,'conceptCoverage',coverage_state,'conceptConfidence',confidence_score))
  from chosen on conflict do nothing;

  -- Coverage 2: 30 genuinely new canonical concepts, not merely new variants.
  with raw as (
    select q.question_id,english.focus_concept_key(q.question_id) concept_key,english.learning_category(q.topic) category,
      row_number() over(partition by english.focus_concept_key(q.question_id) order by q.question_id) concept_pick
    from english.questions q
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    where english.is_genuine_bank_question(q) and coalesce(s.attempts,0)=0 and not coalesce(s.mastered,false)
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=q.question_id or f.concept_key=english.focus_concept_key(q.question_id)))
      and not exists(select 1 from english.concept_evidence ce where ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id) and coalesce(ce.attempts,0)>0)
      and not exists(select 1 from english.question_state s2 where s2.user_id=p_user_id and coalesce(s2.attempts,0)>0 and english.focus_concept_key(s2.question_id)=english.focus_concept_key(q.question_id))
  ), deduped as (
    select * from raw where concept_pick=1
  ), chosen as (
    select *,row_number() over(order by category,question_id)::int bank_ord from deduped order by category,question_id limit 30
  ), numbered as (
    select *,coalesce((select max(sequence) from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='coverage'),0)+bank_ord seq from chosen
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'coverage',seq,question_id,concept_key,array['New Canonical Concept'],
    jsonb_build_object('source','central_intelligence','coverageKind','new','category',category)
  from numbered where seq<=50 on conflict do nothing;

  -- Safety fill prevents an impossible mandatory lane if one source pool is temporarily short.
  select greatest(0,50-count(*)) into v_need from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='coverage';
  if v_need>0 then
    with raw as (
      select q.question_id,english.focus_concept_key(q.question_id) concept_key,coalesce(s.attempts,0) attempts,s.last_attempt,
        row_number() over(partition by english.focus_concept_key(q.question_id) order by coalesce(s.attempts,0),s.last_attempt nulls first,q.question_id) concept_pick
      from english.questions q
      left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
      where english.is_genuine_bank_question(q) and not coalesce(s.mastered,false)
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
        and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=q.question_id or f.concept_key=english.focus_concept_key(q.question_id)))
        and not exists(select 1 from english.learning_route_state r where r.user_id=p_user_id and r.question_id=q.question_id and r.route='fast_track')
    ), chosen as (
      select * from raw where concept_pick=1 order by attempts,last_attempt nulls first,question_id limit v_need
    ), numbered as (
      select *,coalesce((select max(sequence) from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date and lane='coverage'),0)
        + row_number() over(order by attempts,last_attempt nulls first,question_id)::int seq from chosen
    )
    insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
    select p_user_id,p_batch_date,'coverage',seq,question_id,concept_key,array['Coverage Fill'],
      jsonb_build_object('source','central_intelligence','coverageKind','fill','priorAttempts',attempts)
    from numbered where seq<=50 on conflict do nothing;
  end if;

  -- Fast Track: consume the existing route state and its existing eligibility contract.
  with base as (
    select r.question_id,english.focus_concept_key(r.question_id) concept_key,r.fast_track_status,r.origins,r.last_route_reason,r.next_fast_track_check,r.updated_at,
      coalesce(ce.coverage_state,'unseen') concept_state,coalesce(ce.confidence_score,0) concept_confidence,
      case when r.fast_track_status='retention_watch' then 0 when r.fast_track_status='ready' then 1 else 2 end wait_ord
    from english.learning_route_state r
    join english.questions q on q.question_id=r.question_id and q.active
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(r.question_id)
    where r.user_id=p_user_id and r.route='fast_track' and r.fast_track_status<>'mastered'
      and (r.fast_track_status='ready' or (r.fast_track_status in ('waiting','retention_watch') and r.next_fast_track_check<=now()))
      and nullif(english.route_targeted_reason(p_user_id,r.question_id),'') is null
      and not english.focus_conflicts_with_required_daily(p_user_id,r.question_id,p_batch_date)
      and not exists(select 1 from english.daily_focus_items f where f.user_id=p_user_id and f.batch_date=p_batch_date and (f.question_id=r.question_id or f.concept_key=english.focus_concept_key(r.question_id)))
  ), deduped as (
    select *,row_number() over(partition by concept_key order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id) concept_pick
    from base
  ), chosen as (
    select * from deduped where concept_pick=1 order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id limit 50
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'fast_track',row_number() over(order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id)::int,
    question_id,concept_key,array['Fast Track Mastery'],
    jsonb_build_object('source','existing_fast_track','fastTrackStatus',fast_track_status,'origins',origins,'reason',last_route_reason,'conceptCoverage',concept_state,'conceptConfidence',concept_confidence)
  from chosen on conflict do nothing;

  select count(*) filter(where lane='repair'),count(*) filter(where lane='coverage'),count(*) filter(where lane='fast_track')
    into v_repair,v_coverage,v_fast
  from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date;

  update english.daily_focus_batches
  set repair_target=v_repair,coverage_target=v_coverage,fast_track_target=v_fast,updated_at=now()
  where user_id=p_user_id and batch_date=p_batch_date;

  return jsonb_build_object('ok',true,'existing',false,'repair',v_repair,'coverage',v_coverage,'fastTrack',v_fast,'total',v_repair+v_coverage+v_fast);
end;
$function$;

create or replace function english.reconcile_daily_focus(p_user_id uuid,p_batch_date date)
returns void
language plpgsql security definer
set search_path='pg_catalog','english','auth'
as $function$
begin
  update english.daily_focus_items f
  set status='Completed',
      completed_at=coalesce(f.completed_at,(select max(x.attempted_at) from english.attempts x where x.user_id=f.user_id and x.question_id=f.question_id and x.attempted_at>=f.selected_at))
  where f.user_id=p_user_id and f.batch_date=p_batch_date and f.status='New'
    and exists(select 1 from english.attempts x where x.user_id=f.user_id and x.question_id=f.question_id and x.attempted_at>=f.selected_at);

  update english.daily_focus_batches b
  set status=case when exists(select 1 from english.daily_focus_items f where f.user_id=b.user_id and f.batch_date=b.batch_date and f.status='New') then 'active' else 'completed' end,
      completed_at=case when exists(select 1 from english.daily_focus_items f where f.user_id=b.user_id and f.batch_date=b.batch_date and f.status='New') then null else coalesce(b.completed_at,now()) end,
      updated_at=now()
  where b.user_id=p_user_id and b.batch_date=p_batch_date;
end;
$function$;

create or replace function english.daily_focus_summary(p_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
  v_done integer:=0; v_total integer:=0;
  v_repair_done integer:=0; v_repair_total integer:=0;
  v_coverage_done integer:=0; v_coverage_total integer:=0;
  v_fast_done integer:=0; v_fast_total integer:=0;
begin
  select * into v_batch from english.daily_focus_batches where user_id=p_user_id order by batch_date desc limit 1;
  if not found then return jsonb_build_object('ok',false,'reason','no-batch'); end if;

  select count(*),count(*) filter(where status='Completed'),
         count(*) filter(where lane='repair'),count(*) filter(where lane='repair' and status='Completed'),
         count(*) filter(where lane='coverage'),count(*) filter(where lane='coverage' and status='Completed'),
         count(*) filter(where lane='fast_track'),count(*) filter(where lane='fast_track' and status='Completed')
    into v_total,v_done,v_repair_total,v_repair_done,v_coverage_total,v_coverage_done,v_fast_total,v_fast_done
  from english.daily_focus_items where user_id=p_user_id and batch_date=v_batch.batch_date;

  return jsonb_build_object(
    'ok',true,'today',v_today,'batchDate',v_batch.batch_date,'carryover',(v_batch.batch_date<v_today and v_batch.status='active'),
    'status',v_batch.status,'total',v_total,'completed',v_done,'remaining',greatest(0,v_total-v_done),'nominalTarget',150,
    'lanes',jsonb_build_object(
      'repair',jsonb_build_object('target',v_repair_total,'nominalTarget',50,'completed',v_repair_done,'remaining',greatest(0,v_repair_total-v_repair_done),'done',(v_repair_total>0 and v_repair_done=v_repair_total)),
      'coverage',jsonb_build_object('target',v_coverage_total,'nominalTarget',50,'completed',v_coverage_done,'remaining',greatest(0,v_coverage_total-v_coverage_done),'done',(v_coverage_total>0 and v_coverage_done=v_coverage_total)),
      'fastTrack',jsonb_build_object('target',v_fast_total,'nominalTarget',50,'completed',v_fast_done,'remaining',greatest(0,v_fast_total-v_fast_done),'done',(v_fast_total>0 and v_fast_done=v_fast_total))
    )
  );
end;
$function$;

create or replace function english.ensure_daily_focus(p_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;
  perform pg_advisory_xact_lock(hashtext('english.ensure_daily_focus'),hashtext(p_user_id::text));

  select * into v_batch from english.daily_focus_batches where user_id=p_user_id order by batch_date desc limit 1;
  if not found then
    perform english.create_daily_focus(p_user_id,v_today);
  else
    perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
    select * into v_batch from english.daily_focus_batches where user_id=p_user_id and batch_date=v_batch.batch_date;
    if v_batch.status='completed' and v_batch.batch_date<v_today then
      perform english.create_daily_focus(p_user_id,v_today);
    end if;
  end if;

  select * into v_batch from english.daily_focus_batches where user_id=p_user_id order by batch_date desc limit 1;
  perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
  return english.daily_focus_summary(p_user_id);
end;
$function$;

create or replace function english.daily_focus_after_attempt_trigger()
returns trigger
language plpgsql security definer
set search_path='pg_catalog','english','auth'
as $function$
declare v_batch date;
begin
  update english.daily_focus_items f
  set status='Completed',completed_at=coalesce(f.completed_at,new.attempted_at)
  from english.daily_focus_batches b
  where b.user_id=new.user_id and b.batch_date=f.batch_date and b.status='active'
    and f.user_id=new.user_id and f.question_id=new.question_id and f.status='New' and f.selected_at<=new.attempted_at
  returning f.batch_date into v_batch;

  if v_batch is not null and not exists(select 1 from english.daily_focus_items f where f.user_id=new.user_id and f.batch_date=v_batch and f.status='New') then
    update english.daily_focus_batches set status='completed',completed_at=coalesce(completed_at,now()),updated_at=now()
    where user_id=new.user_id and batch_date=v_batch;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_daily_focus_after_attempt on english.attempts;
create trigger trg_daily_focus_after_attempt after insert on english.attempts
for each row execute function english.daily_focus_after_attempt_trigger();

create or replace function public.english_get_daily_focus_summary()
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  return english.ensure_daily_focus(uid);
end;
$function$;

create or replace function public.english_get_daily_focus_lane(p_lane text)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid(); v_lane text:=lower(btrim(coalesce(p_lane,''))); v_summary jsonb; v_batch date; outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_lane not in ('repair','coverage','fast_track') then raise exception 'Unknown Daily Focus lane'; end if;
  v_summary:=english.ensure_daily_focus(uid);
  v_batch:=(v_summary->>'batchDate')::date;

  select coalesce(jsonb_agg(
    english.question_payload(uid,f.question_id)
    || jsonb_build_object(
      'dailyFocus',true,'dailyFocusLane',f.lane,'dailyFocusSequence',f.sequence,'dailyFocusBatchDate',f.batch_date,
      'dailyFocusReasons',f.reasons,'selectionReason',array_to_string(f.reasons,' · '),'dailyFocusSnapshot',f.selection_snapshot
    )
    || case when f.lane='fast_track' then jsonb_strip_nulls(jsonb_build_object(
      'fastTrack',true,'fastTrackStatus',r.fast_track_status,'fastTrackOrigins',r.origins,
      'fastTrackReason',r.last_route_reason,'fastTrackNextCheck',r.next_fast_track_check,'fastTrackFailureDecision',r.pending_failure_decision
    )) else '{}'::jsonb end
    order by f.sequence
  ),'[]'::jsonb) into outv
  from english.daily_focus_items f
  left join english.learning_route_state r on r.user_id=f.user_id and r.question_id=f.question_id
  where f.user_id=uid and f.batch_date=v_batch and f.lane=v_lane and f.status='New';
  return outv;
end;
$function$;

grant execute on function public.english_get_daily_focus_summary() to authenticated;
grant execute on function public.english_get_daily_focus_lane(text) to authenticated;
