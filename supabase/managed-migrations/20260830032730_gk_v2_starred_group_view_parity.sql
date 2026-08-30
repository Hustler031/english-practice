-- Read-only old Starred day-group selector parity.
create or replace function public.gk_get_starred_group_batch(
  p_age_from integer default null,
  p_age_to integer default null,
  p_earlier boolean default false,
  p_kind text default 'smart',
  p_count integer default 20
) returns jsonb
language plpgsql
volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  kind_name text:=lower(btrim(coalesce(p_kind,'smart')));
  n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with rows as (
    select q.question_id,
      coalesce(s.learning_status,'New') learning_state,
      coalesce(s.next_review<=now(),false) due,
      coalesce(s.difficult,false) difficult,
      coalesce(s.unconfirmed_guess,false) guessed,
      s.starred_at,
      (select max(a.attempted_at) from gk.attempts a where a.user_id=uid and a.question_id=q.question_id and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision,
      case coalesce(s.learning_status,'New') when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700 when 'Learning' then 500 when 'Strong' then 180 when 'Proven Mastered' then 20 else 300 end
        +case when coalesce(s.next_review<=now(),false) then 300 else 0 end
        +case when coalesce(s.difficult,false) then 180 else 0 end
        +case when coalesce(s.unconfirmed_guess,false) then 240 else 0 end as priority
    from gk.question_state s
    join gk.questions q on q.question_id=s.question_id and q.active
    where s.user_id=uid and coalesce(s.marked_review,false)
      and (
        (coalesce(p_earlier,false) and s.starred_at is null)
        or (
          not coalesce(p_earlier,false) and s.starred_at is not null
          and greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) between coalesce(p_age_from,0) and coalesce(p_age_to,2147483647)
        )
      )
  ), ranked as (
    select r.*,row_number() over(order by
      case when kind_name='random' then random() else 0 end,
      case when kind_name='smart' then priority else 0 end desc,
      case when kind_name='all' then extract(epoch from coalesce(starred_at,to_timestamp(0))) else 0 end desc,
      question_id
    ) ord from rows r
  ), chosen as(select * from ranked order by ord limit n)
  select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
  return out;
end
$$;
revoke execute on function public.gk_get_starred_group_batch(integer,integer,boolean,text,integer) from public,anon;
grant execute on function public.gk_get_starred_group_batch(integer,integer,boolean,text,integer) to authenticated;
