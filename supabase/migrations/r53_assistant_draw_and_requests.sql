create table public.debate_assistant_tokens (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 user_id uuid not null,
 grant_key text not null,
 granted_at timestamptz not null default now(),
 used_at timestamptz,
 unique(round_id, grant_key)
);
create index debate_assistant_tokens_owner_idx on public.debate_assistant_tokens(round_id,user_id) where used_at is null;
alter table public.debate_assistant_tokens enable row level security;
revoke all on public.debate_assistant_tokens from public,anon,authenticated;

create table public.debate_assistant_requests (
 round_id bigint not null references public.rounds(id) on delete cascade,
 cycle_number bigint not null,
 user_id uuid not null,
 requested_at timestamptz not null default now(),
 used_at timestamptz,
 primary key(round_id,cycle_number,user_id)
);
alter table public.debate_assistant_requests enable row level security;
revoke all on public.debate_assistant_requests from public,anon,authenticated;

create table public.debate_assistant_approvals (
 round_id bigint not null references public.rounds(id) on delete cascade,
 cycle_number bigint not null,
 approved_at timestamptz not null default now(),
 primary key(round_id,cycle_number)
);
alter table public.debate_assistant_approvals enable row level security;
revoke all on public.debate_assistant_approvals from public,anon,authenticated;

alter table public.debate_assistant_guides add column source text not null default 'token';
alter table public.debate_assistant_guides drop constraint debate_assistant_guides_round_id_user_id_cycle_number_choic_key;
alter table public.debate_assistant_guides add constraint debate_assistant_guides_source_key unique(round_id,user_id,cycle_number,choice,source);

create function public.draw_debate_assistant(p_round_id bigint,p_grant_key text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare v_room bigint;v_user uuid;
begin
 select room_id into v_room from public.rounds where id=p_round_id;
 if v_room is null then return; end if;
 select p.user_id into v_user from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null
 and not exists(select 1 from public.debate_assistant_tokens t where t.round_id=p_round_id and t.user_id=p.user_id and t.used_at is null)
 order by random() limit 1;
 if v_user is not null then
  insert into public.debate_assistant_tokens(round_id,user_id,grant_key)
  values(p_round_id,v_user,p_grant_key) on conflict(round_id,grant_key) do nothing;
 end if;
end $fn$;

create function public.draw_debate_assistant_round_trigger()
returns trigger language plpgsql security definer set search_path to '' as $fn$
begin
 if new.debate_phase='debate' and (old.debate_phase is distinct from 'debate' or old.vote_cycle is distinct from new.vote_cycle) then
  perform public.draw_debate_assistant(new.id,'cycle:'||new.vote_cycle);
 end if;
 return new;
end $fn$;
create trigger debate_assistant_round_draw after update of debate_phase,vote_cycle on public.rounds
for each row execute function public.draw_debate_assistant_round_trigger();

create function public.draw_debate_assistant_optional_trigger()
returns trigger language plpgsql security definer set search_path to '' as $fn$
begin
 if old.closed_at is null and new.closed_at is not null then
  perform public.draw_debate_assistant(new.round_id,'optional:'||new.id);
 end if;
 return new;
end $fn$;
create trigger debate_assistant_optional_draw after update of closed_at on public.debate_optional_revote_windows
for each row execute function public.draw_debate_assistant_optional_trigger();

create function public.get_debate_assistant_access(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_present boolean;
 v_players bigint;v_requests bigint;v_token boolean;v_mine boolean;v_group_used boolean;v_assigned bigint;v_used bigint;v_guide boolean;v_approved boolean;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id;
 if v_room is null or auth.uid() is null then raise exception 'Not in debate'; end if;
 select exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') into v_present;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select exists(select 1 from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null) into v_token;
 select exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid()),
        exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and used_at is not null)
 into v_mine,v_group_used;
 select count(*),count(*) filter(where used_at is not null) into v_assigned,v_used from public.debate_assistant_tokens where round_id=p_round_id;
 select exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) into v_approved;
 select exists(select 1 from public.debate_assistant_guides g join public.debate_vote_cycles v
 on v.round_id=g.round_id and v.cycle_number=g.cycle_number and v.user_id=g.user_id and v.choice=g.choice
 where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid()) into v_guide;
 return jsonb_build_object('cycle',v_cycle,'players',v_players,'requests',v_requests,'approved',v_approved,
  'mine_requested',v_mine,'mine_group_used',v_group_used,'token',v_token,'mine_guide',v_guide,'assigned',v_assigned,'used',v_used,
  'active',v_phase='debate' and not v_paused and v_present);
end $fn$;

create function public.request_debate_assistant(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_players bigint;v_requests bigint;v_eligible bigint;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Help unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Wait for revote'; end if;
 if exists(select 1 from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null) then raise exception 'Use your drawn guide first'; end if;
 if not exists(select 1 from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid()) then raise exception 'Vote first'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 if exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) then raise exception 'Request already closed'; end if;
 insert into public.debate_assistant_requests(round_id,cycle_number,user_id) values(p_round_id,v_cycle,auth.uid()) on conflict do nothing;
 select count(*) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*) into v_eligible from public.players p where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
 and not exists(select 1 from public.debate_assistant_tokens t where t.round_id=p_round_id and t.user_id=p.user_id and t.used_at is null);
 if v_eligible>0 and v_requests>=least(v_players/2+1,v_eligible) then
  insert into public.debate_assistant_approvals(round_id,cycle_number) values(p_round_id,v_cycle) on conflict do nothing;
 end if;
 return public.get_debate_assistant_access(p_round_id);
end $fn$;

create or replace function public.prepare_debate_assistant(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_room bigint;v_dilemma bigint;v_phase text;v_cycle bigint;v_paused boolean;v_choice text;
 v_question text;v_a text;v_b text;v_twist text;v_source text;v_guide public.debate_assistant_guides%rowtype;
 v_approved boolean;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select room_id,dilemma_id,debate_phase,vote_cycle,paused into v_room,v_dilemma,v_phase,v_cycle,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Assistant unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Wait for revote'; end if;
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() limit 1;
 if v_choice not in ('A','B') then raise exception 'Vote before opening the assistant'; end if;
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
   where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and used_at is null
   returning 'group' into v_source;
  end if;
 end if;
 if v_source is null then
  select * into v_guide from public.debate_assistant_guides
  where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice
  order by id desc limit 1;
  if v_guide.id is null then raise exception 'Guide not available'; end if;
  v_source:=v_guide.source;
 else
  insert into public.debate_assistant_guides(round_id,user_id,cycle_number,choice,source)
  values(p_round_id,auth.uid(),v_cycle,v_choice,v_source)
  on conflict(round_id,user_id,cycle_number,choice,source) do nothing;
  select * into v_guide from public.debate_assistant_guides
  where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice and source=v_source;
 end if;
 return jsonb_build_object('status',case when v_guide.status='ready' then 'ready' else 'draft' end,
  'guide',v_guide.guide,'mode',v_guide.mode,'source',v_source,'question',v_question,'option_a',v_a,'option_b',v_b,
  'choice',v_choice,'twist',v_twist,'cycle',v_cycle);
end $fn$;

create or replace function public.save_debate_assistant(p_round_id bigint,p_cycle bigint,p_choice text,p_source text,p_guide jsonb,p_mode text)
returns boolean language plpgsql security definer set search_path to '' as $fn$
declare v_room bigint;v_phase text;v_cycle bigint;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_choice not in ('A','B') or p_source not in ('token','group') or p_mode not in ('IA','BASICA') or p_guide is null
 or length(p_guide::text)>8500 or jsonb_typeof(p_guide)<>'object' then raise exception 'Invalid guide'; end if;
 select room_id,debate_phase,vote_cycle into v_room,v_phase,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or v_phase<>'debate' or v_cycle<>p_cycle then raise exception 'Round changed'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if not exists(select 1 from public.debate_vote_cycles where round_id=p_round_id and cycle_number=p_cycle and user_id=auth.uid() and choice=p_choice) then raise exception 'Vote changed'; end if;
 update public.debate_assistant_guides set guide=p_guide,mode=p_mode,status='ready'
 where round_id=p_round_id and user_id=auth.uid() and cycle_number=p_cycle and choice=p_choice and source=p_source
 and (status='pending' or (mode='BASICA' and p_mode='IA'));
 return found;
end $fn$;

revoke all on function public.draw_debate_assistant(bigint,text),public.draw_debate_assistant_round_trigger(),public.draw_debate_assistant_optional_trigger() from public,anon,authenticated;
revoke all on function public.get_debate_assistant_access(bigint),public.request_debate_assistant(bigint),public.prepare_debate_assistant(bigint),public.save_debate_assistant(bigint,bigint,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.get_debate_assistant_access(bigint),public.request_debate_assistant(bigint),public.prepare_debate_assistant(bigint),public.save_debate_assistant(bigint,bigint,text,text,jsonb,text) to authenticated;
