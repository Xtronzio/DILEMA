begin;

-- Reject direct client edits to shared context; approved server functions run as their owner.
create or replace function private.shared_context_write_guard() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if current_user in ('anon','authenticated') and old.context is distinct from new.context then
  raise exception 'Shared context requires table approval';
 end if;
 return new;
end $$;
revoke all on function private.shared_context_write_guard() from public,anon,authenticated;
create trigger shared_context_write_guard before update of context on public.rounds
 for each row execute function private.shared_context_write_guard();

alter table private.debate_context_requests add column if not exists proposed_text text;
alter table private.debate_context_requests drop constraint if exists debate_context_requests_status_check;
alter table private.debate_context_requests add constraint debate_context_requests_status_check
 check(status in ('open','approved','review','published','rejected','cancelled'));
alter table private.debate_context_requests add constraint debate_context_text_check
 check(proposed_text is null or length(proposed_text) between 1 and 3000);
drop index if exists private.debate_context_one_open;
create unique index debate_context_one_open on private.debate_context_requests(round_id)
 where status in ('open','approved','review');

create table private.debate_context_review_votes(
 request_id bigint not null references private.debate_context_requests(id) on delete cascade,
 user_id uuid not null references auth.users(id),choice boolean not null,
 primary key(request_id,user_id)
);
alter table private.debate_context_review_votes enable row level security;
revoke all on private.debate_context_review_votes from public,anon,authenticated;

create or replace function private.context_state(p_round bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare room bigint;c text;phase text;paused boolean;req private.debate_context_requests;
 n bigint;y bigint;no_count bigint;myvote boolean;context_count bigint;outcome text;
begin
 select room_id,context,debate_phase,r.paused into room,c,phase,paused from public.rounds r where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room';end if;
 update private.debate_context_requests r set status='cancelled' where round_id=p_round and status in('open','approved','review')
 and (phase is distinct from 'debate' or paused or not exists(select 1 from public.players where room_id=room and user_id=r.requester and presence='present' and abandoned_at is null));
 select * into req from private.debate_context_requests where round_id=p_round order by id desc limit 1;
 select count(*) into n from public.players where room_id=room and presence='present' and abandoned_at is null;
 select count(*) into context_count from private.debate_context_requests where round_id=p_round and status='published';
 if coalesce((select length(p.context)>0 from public.debate_dilemma_proposals p where p.room_id=room and p.status='launched' and p.created_at<=(select created_at from public.rounds where id=p_round) order by p.id desc limit 1),false) then context_count:=context_count+1;end if;
 if req.status in('open','approved','review') then
  if req.status='review' then
   select count(*) filter(where v.choice),count(*) filter(where not v.choice) into y,no_count
   from private.debate_context_review_votes v where v.request_id=req.id
   and exists(select 1 from public.players p where p.room_id=room and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
   select choice into myvote from private.debate_context_review_votes where request_id=req.id and user_id=auth.uid();
  else
   select count(*) filter(where v.choice),count(*) filter(where not v.choice) into y,no_count
   from private.debate_context_votes v where v.request_id=req.id
   and exists(select 1 from public.players p where p.room_id=room and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
   select choice into myvote from private.debate_context_votes where request_id=req.id and user_id=auth.uid();
  end if;
  if req.status in('open','review') then
   if y>n/2 then
    if req.status='open' then
     update private.debate_context_requests set status='approved' where id=req.id;req.status:='approved';
    else
     c:=concat_ws(E'\n\n',nullif(c,''),req.proposed_text);
     if length(c)>12000 then raise exception 'Context limit reached';end if;
     update public.rounds set context=c where id=p_round;
     update private.debate_context_requests set status='published' where id=req.id;
     req.status:='published';context_count:=context_count+1;
    end if;
   elsif no_count>n/2 or y+no_count>=n then
    update private.debate_context_requests set status='rejected' where id=req.id;req.status:='rejected';
   end if;
  end if;
 end if;
 return jsonb_build_object('context',c,'count',context_count,'players',n,
  'id',case when req.status in('open','approved','review') then req.id else null end,
  'status',req.status,'mine',myvote,'requester_me',req.requester=auth.uid(),'voted',coalesce(y,0)+coalesce(no_count,0),
  'proposed_text',case when req.status='review' then req.proposed_text else null end,
  'last_id',req.id,'last_status',req.status);
end $$;

create or replace function private.context_guard(p_round bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 perform 1 from public.rounds where id=p_round for update;
 if exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open') then raise exception 'Another proposal must be resolved first';end if;
end $$;

create or replace function private.context_submit(p_round bigint,p_id bigint,p_text text) returns void
language plpgsql security definer set search_path='' as $$
declare r public.rounds;req private.debate_context_requests;
begin
 select * into r from public.rounds where id=p_round for update;
 if auth.uid() is null or r.debate_phase is distinct from 'debate' or r.paused or not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active';end if;
 select * into req from private.debate_context_requests where id=p_id and round_id=p_round and requester=auth.uid() and status='approved';
 if req.id is null then raise exception 'Context not approved';end if;
 if length(trim(coalesce(p_text,''))) not between 1 and 3000 then raise exception 'Invalid context';end if;
 if length(concat_ws(E'\n\n',nullif(r.context,''),trim(p_text)))>12000 then raise exception 'Context limit reached';end if;
 update private.debate_context_requests set proposed_text=trim(p_text),status='review' where id=p_id;
 insert into private.debate_context_review_votes(request_id,user_id,choice) values(p_id,auth.uid(),true);
 perform private.context_state(p_round);
end $$;

create or replace function private.context_review_vote(p_round bigint,p_id bigint,p_yes boolean) returns void
language plpgsql security definer set search_path='' as $$
declare r public.rounds;req private.debate_context_requests;
begin
 select * into r from public.rounds where id=p_round for update;
 if auth.uid() is null or p_yes is null or r.debate_phase is distinct from 'debate' or r.paused
 or not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active';end if;
 select * into req from private.debate_context_requests where id=p_id and round_id=p_round and status='review';
 if req.id is null then raise exception 'Voting closed';end if;
 insert into private.debate_context_review_votes(request_id,user_id,choice) values(p_id,auth.uid(),p_yes) on conflict do nothing;
 perform private.context_state(p_round);
end $$;
revoke all on function private.context_review_vote(bigint,bigint,boolean) from public,anon;
grant execute on function private.context_review_vote(bigint,bigint,boolean) to authenticated;
create or replace function public.debate_review_context(p_round bigint,p_id bigint,p_yes boolean) returns void
language sql security invoker set search_path='' as $$select private.context_review_vote(p_round,p_id,p_yes)$$;
revoke all on function public.debate_review_context(bigint,bigint,boolean) from public,anon;
grant execute on function public.debate_review_context(bigint,bigint,boolean) to authenticated;

create or replace function private.context_cancel(p_round bigint,p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.rounds where id=p_round for update;
 if auth.uid() is null then raise exception 'Authentication required';end if;
 update private.debate_context_requests set status='cancelled' where id=p_id and round_id=p_round and requester=auth.uid() and status in('open','approved','review');
 if not found then raise exception 'Request unavailable';end if;
end $$;

-- Preserve existing guides while making reuse depend on accepted context.
alter table public.debate_assistant_guides add column context_signature text;
update public.debate_assistant_guides g set context_signature=md5(coalesce(r.context,'')) from public.rounds r where r.id=g.round_id;
alter table public.debate_assistant_guides alter column context_signature set not null;
alter table public.debate_assistant_guides alter column context_signature set default md5('');
alter table public.debate_assistant_guides drop constraint debate_assistant_guides_source_key;
alter table public.debate_assistant_guides add constraint debate_assistant_guides_source_key unique(round_id,user_id,cycle_number,choice,source,context_signature);

-- Assistant function replacements follow below.

CREATE OR REPLACE FUNCTION public.prepare_debate_assistant(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_dilemma bigint;v_phase text;v_cycle bigint;v_paused boolean;v_choice text;
 v_question text;v_a text;v_b text;v_twist text;v_source text;v_guide public.debate_assistant_guides%rowtype;
 v_approved boolean;v_signature text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select room_id,dilemma_id,debate_phase,vote_cycle,paused into v_room,v_dilemma,v_phase,v_cycle,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Assistant unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Wait for revote'; end if;
 perform private.context_guard(p_round_id);
 select md5(coalesce(context,'')) into v_signature from public.rounds where id=p_round_id;
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() limit 1;
 if v_choice is null or v_choice not in ('A','B') then raise exception 'Vote before opening the assistant'; end if;
 select question,option_a,option_b into v_question,v_a,v_b from public.dilemmas where id=v_dilemma;
 if v_question is null then raise exception 'Dilemma unavailable'; end if;
 select text into v_twist from public.debate_twists where round_id=p_round_id order by id desc limit 1;
 update public.debate_assistant_tokens set used_at=now()
 where id=(select id from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null order by granted_at,id limit 1)
 returning 'token' into v_source;
 if v_source is null then
  select exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) into v_approved;
  if v_approved then
   update public.debate_assistant_requests set used_at=now()
   where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice and used_at is null
   returning 'group' into v_source;
  end if;
 end if;
 if v_source is null then
  select * into v_guide from public.debate_assistant_guides
  where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice
  order by (context_signature=v_signature) desc,id desc limit 1;
  if v_guide.id is null then raise exception 'Guide not available';end if;
  v_source:=v_guide.source;
 end if;
 insert into public.debate_assistant_guides(round_id,user_id,cycle_number,choice,source,context_signature)
 values(p_round_id,auth.uid(),v_cycle,v_choice,v_source,v_signature)
 on conflict(round_id,user_id,cycle_number,choice,source,context_signature) do nothing;
 select * into v_guide from public.debate_assistant_guides
 where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice and source=v_source and context_signature=v_signature;
 return jsonb_build_object('status',case when v_guide.status='ready' then 'ready' else 'draft' end,
  'guide',v_guide.guide,'mode',v_guide.mode,'source',v_source,'question',v_question,'option_a',v_a,'option_b',v_b,
  'context_signature',v_signature,'choice',v_choice,'twist',v_twist,'cycle',v_cycle,'context',(select context from public.rounds where id=p_round_id));
end $function$;

CREATE OR REPLACE FUNCTION public.get_debate_assistant_access(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_present boolean;
 v_players bigint;v_requests bigint;v_token boolean;v_mine boolean;v_group_used boolean;v_assigned bigint;v_used bigint;v_guide boolean;v_approved boolean;v_choice text;v_prior_guide boolean;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id;
 if v_room is null or auth.uid() is null then raise exception 'Not in debate'; end if;
 select exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') into v_present;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(distinct r.user_id) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid();
 select exists(select 1 from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null) into v_token;
 select exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice),
        exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice and used_at is not null)
 into v_mine,v_group_used;
 select count(*),count(*) filter(where used_at is not null) into v_assigned,v_used from public.debate_assistant_tokens where round_id=p_round_id;
 select exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) into v_approved;
 select exists(select 1 from public.debate_assistant_guides g join public.debate_vote_cycles v
 on v.round_id=g.round_id and v.cycle_number=g.cycle_number and v.user_id=g.user_id and v.choice=g.choice
 where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid()) into v_guide;
 return jsonb_build_object('context_signature',(select md5(coalesce(context,'')) from public.rounds where id=p_round_id),'cycle',v_cycle,'players',v_players,'requests',v_requests,'approved',v_approved,
  'mine_requested',v_mine,'mine_group_used',v_group_used,'token',v_token,'mine_guide',v_guide,'assigned',v_assigned,'used',v_used,
  'can_request',not v_token and not v_mine and v_choice in ('A','B') and (not v_approved or exists(select 1 from public.debate_assistant_guides g where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid() and g.choice<>v_choice and g.status='ready')),
  'active',v_phase='debate' and not v_paused and v_present);
end $function$;

CREATE OR REPLACE FUNCTION public.save_debate_assistant(p_round_id bigint, p_cycle bigint, p_choice text, p_source text, p_guide jsonb, p_mode text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_phase text;v_cycle bigint;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_choice not in ('A','B') or p_source not in ('token','group') or p_mode not in ('IA','BASICA') or p_guide is null
 or length(p_guide::text)>8500 or jsonb_typeof(p_guide)<>'object' then raise exception 'Invalid guide'; end if;
 select room_id,debate_phase,vote_cycle into v_room,v_phase,v_cycle from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_cycle<>p_cycle then raise exception 'Round changed'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if not exists(select 1 from public.debate_vote_cycles where round_id=p_round_id and cycle_number=p_cycle and user_id=auth.uid() and choice=p_choice) then raise exception 'Vote changed'; end if;
 update public.debate_assistant_guides set guide=p_guide,mode=p_mode,status='ready'
 where round_id=p_round_id and user_id=auth.uid() and cycle_number=p_cycle and choice=p_choice and source=p_source
 and context_signature=(select md5(coalesce(context,'')) from public.rounds where id=p_round_id)
 and (status='pending' or (mode='BASICA' and p_mode='IA'));
 return found;
end $function$;

create or replace function private.save_context_guide(p_round bigint,p_cycle bigint,p_choice text,p_source text,p_guide jsonb,p_mode text,p_signature text) returns boolean
language plpgsql security definer set search_path='' as $$
declare c text;room bigint;
begin
 select context,room_id into c,room from public.rounds where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active';end if;
 if p_signature is distinct from md5(coalesce(c,'')) then return false;end if;
 perform private.context_guard(p_round);
 return public.save_debate_assistant(p_round,p_cycle,p_choice,p_source,p_guide,p_mode);
end $$;
revoke all on function private.save_context_guide(bigint,bigint,text,text,jsonb,text,text) from public,anon;
grant execute on function private.save_context_guide(bigint,bigint,text,text,jsonb,text,text) to authenticated;
create or replace function public.save_debate_assistant_context(p_round_id bigint,p_cycle bigint,p_choice text,p_source text,p_guide jsonb,p_mode text,p_signature text) returns boolean
language sql security invoker set search_path='' as $$select private.save_context_guide(p_round_id,p_cycle,p_choice,p_source,p_guide,p_mode,p_signature)$$;
revoke all on function public.save_debate_assistant_context(bigint,bigint,text,text,jsonb,text,text) from public,anon;
grant execute on function public.save_debate_assistant_context(bigint,bigint,text,text,jsonb,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
