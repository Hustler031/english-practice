create or replace function public.english_get_saved_revision_hub() returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,english,auth
as $$
with c as (select * from english.saved_revision_candidates(auth.uid())),
stats as (
 select count(*)::int saved,count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and never_revised)::int never_revised,count(*) filter(where not mastered and due)::int due,
 count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where not mastered and starred)::int starred,
 count(*) filter(where mastered)::int mastered from c
), days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,count(*)::int saved,
 count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and due)::int due,count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where mastered)::int mastered
 from c group by 1 order by 1 desc
), day_meta as (
 select greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1)::int current_day
)
select jsonb_build_object(
 'version','V3','currentDay',m.current_day,
 'stats',jsonb_build_object('saved',s.saved,'eligible',s.eligible,'controlledNew',s.controlled_new,'neverRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'mastered',s.mastered),
 'available',jsonb_build_object('smart',s.eligible,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'random',s.eligible,'all',s.eligible),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((select jsonb_agg(jsonb_build_object('date',d,'day',greatest(1,(d-date '2026-08-14')+1),'label',to_char(d,'DD Mon YYYY'),'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,'weak',weak,'difficult',difficult,'mastered',mastered) order by d desc) from days),'[]'::jsonb)
) from stats s cross join day_meta m;
$$;
revoke execute on function public.english_get_saved_revision_hub() from public,anon;
grant execute on function public.english_get_saved_revision_hub() to authenticated,service_role;

create or replace function public.english_get_starred_guidance(p_from_day integer default null,p_to_day integer default null)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,english,auth
as $$
declare
 h jsonb; r jsonb;
 active_n integer; never_n integer; due_n integer; due_weak_n integer; days14_n integer; days7_n integer;
 priority text; focus text; recommendation text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 h:=public.english_get_starred_hub(p_from_day,p_to_day);
 r:=public.english_get_starred_rotation_stats(p_from_day,p_to_day);
 active_n:=coalesce((h#>>'{stats,active}')::int,0);
 never_n:=coalesce((h#>>'{stats,neverRevised}')::int,0);
 due_n:=coalesce((h#>>'{stats,due}')::int,0);
 due_weak_n:=coalesce((r->>'dueWeak')::int,0);
 days14_n:=coalesce((r->>'days14Plus')::int,coalesce((h#>>'{stats,longOverdue}')::int,0));
 days7_n:=coalesce((r->>'days7Plus')::int,0);
 if never_n>=greatest(5,ceil(active_n*.25)::int) or days14_n>=greatest(5,ceil(active_n*.20)::int) then priority:='High';
 elsif never_n>0 or days7_n>0 then priority:='Moderate'; else priority:='Healthy'; end if;
 if due_weak_n>=8 then focus:='Due weak recall';
 elsif due_n>=8 then focus:='Overdue retention';
 elsif priority='High' then focus:='Coverage rotation'; else focus:='Balanced retention + rotation'; end if;
 if due_weak_n>=8 then recommendation:='Smart Mix prioritises due Weak / Fragile recall'||case when never_n>0 then ' while protecting first exposure for '||never_n||' Never Revised Starred questions' else '' end||'.';
 elsif due_n>=8 then recommendation:='The current Smart set emphasises spaced retention'||case when never_n>0 then ' while rotating through '||never_n||' Never Revised Starred questions' else '' end||'.';
 elsif priority='High' then recommendation:='The rotation backlog is currently the stronger need, so coverage rotation receives priority.';
 elsif never_n>0 then recommendation:=never_n||' current Starred questions have never been revised through Starred Revision; Smart Mix protects that coverage.';
 else recommendation:='Most active Starred questions already have Starred Revision exposure, so Smart Mix balances due retention with longest-not-revised rotation.'; end if;
 return jsonb_build_object('rotationPriority',priority,'focus',focus,'recommendation',recommendation,'dueWeak',due_weak_n,'due',due_n,'neverRevised',never_n,'days7Plus',days7_n,'days14Plus',days14_n);
end;
$$;
revoke execute on function public.english_get_starred_guidance(integer,integer) from public,anon;
grant execute on function public.english_get_starred_guidance(integer,integer) to authenticated,service_role;
