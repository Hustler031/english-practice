-- Historical origins[] is cumulative. Bank exception must be based on the
-- actual latest entry into Fast Track, not merely on an old Bank origin tag.
do $reconcile_entry_origin$
declare
  x record;
  ev record;
  v_star_action text;
  v_star_at timestamptz;
  v_resolved_at timestamptz;
begin
  for x in
    select r.*,
           le.origin as latest_entry_origin
    from english.learning_route_state r
    cross join lateral english.fast_track_evidence(r.user_id,r.question_id) e
    left join lateral (
      select re.origin,re.event_at,re.event_type
      from english.learning_route_events re
      where re.user_id=r.user_id and re.question_id=r.question_id
        and re.to_route='fast_track'
        and (re.event_type in ('BOOTSTRAP','ROUTE','RECOVER') or re.from_route is distinct from 'fast_track')
      order by re.event_at desc limit 1
    ) le on true
    where r.route='fast_track'
      and not e.eligible
      and coalesce(le.origin,'') not in ('Historical Clean Bank','Bank Coverage')
  loop
    select * into ev from english.fast_track_evidence(x.user_id,x.question_id);

    update english.learning_route_state set
      route='unclassified',fast_track_status=null,
      entered_fast_track_at=null,next_fast_track_check=null,fast_track_mastered_at=null,
      pending_failure_decision=false,kept_failure_count=0,
      last_route_reason='Awaiting global Fast Track evidence: 10 spaced checkpoints, >=80% accuracy, last 4 clean',
      updated_at=now()
    where user_id=x.user_id and question_id=x.question_id;

    perform english.route_event(
      x.user_id,x.question_id,'RECONCILE','fast_track','unclassified','Global Evidence v2',
      'Latest Fast Track entry was not Bank Coverage and does not meet global evidence',
      jsonb_build_object(
        'latestEntryOrigin',x.latest_entry_origin,
        'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
        'accuracyPercent',coalesce(ev.accuracy_percent,0),
        'last4Correct',coalesce(ev.last4_correct,0)
      ),
      'global-evidence-v2:entry-origin:'||x.user_id::text||':'||x.question_id
    );

    -- Restore a Star only when the latest UNSTAR was exactly the legacy
    -- automatic STAR_RESOLVED event. Never override a later manual UNSTAR.
    select s.action,s.event_at into v_star_action,v_star_at
    from english.star_events s
    where s.user_id=x.user_id and s.question_id=x.question_id
    order by s.event_at desc,s.id desc limit 1;

    select re.event_at into v_resolved_at
    from english.learning_route_events re
    where re.user_id=x.user_id and re.question_id=x.question_id
      and re.event_type='STAR_RESOLVED' and re.origin='From Starred'
    order by re.event_at desc limit 1;

    if v_star_action='UNSTAR' and v_resolved_at is not null
       and abs(extract(epoch from (v_star_at-v_resolved_at)))<1 then
      insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action)
      values(x.user_id,x.question_id,now(),(now() at time zone 'Asia/Kolkata')::date,null,'STAR');
      update english.learning_route_state set starred_resolved_at=null,updated_at=now()
      where user_id=x.user_id and question_id=x.question_id;
      perform english.recompute_question_state(x.user_id,x.question_id);
    end if;
  end loop;
end
$reconcile_entry_origin$;
