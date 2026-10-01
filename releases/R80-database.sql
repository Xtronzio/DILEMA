begin;
create table if not exists private.debate_limbo_proposals(
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 target_user_id uuid not null, target_player_id text not null,target_name text not null,
 proposer_user_id uuid not null, duration_seconds integer not null check(duration_seconds in(0,180,300,600)),
 status text not null default 'open' check(status in('open','accepted','rejected')),
 created_at timestamptz not null default now(),accepted_at timestamptz,until_at timestamptz
);
create unique index if not exists limbo_one_open on private.debate_limbo_proposals(round_id) where status='open';
create index if not exists limbo_target_active on private.debate_limbo_proposals(target_user_id,round_id) where status='accepted';
create table if not exists private.debate_limbo_votes(
 proposal_id bigint references private.debate_limbo_proposals(id) on delete cascade,
 user_id uuid not null,choice text not null check(choice in('YES','NO')),primary key(proposal_id,user_id)
);
alter table private.debate_limbo_proposals enable row level security;
alter table private.debate_limbo_votes enable row level security;
revoke all on private.debate_limbo_proposals,private.debate_limbo_votes from public,anon,authenticated;

create or replace function private.limbo_blocked(p_room bigint,p_user uuid) returns boolean
language sql security definer set search_path='' as $$
 select exists(select 1 from private.debate_limbo_proposals l join public.rounds r on r.id=l.round_id
 join public.rooms room on room.id=r.room_id
 where r.room_id=p_room and l.target_user_id=p_user and l.status='accepted'
 and r.debate_phase<>'finished' and room.status<>'waiting'
 and (l.until_at is null or l.until_at>clock_timestamp()))
$$;
revoke all on function private.limbo_blocked(bigint,uuid) from public,anon,authenticated;

create or replace function private.limbo_return_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_room bigint;v_user uuid;
begin
 if tg_table_name='players' then
  if new.presence<>'present' then return new;end if;
  v_room:=new.room_id;v_user:=new.user_id;
 else
  if new.action<>'return' or new.status<>'open' then return new;end if;
  select room_id into v_room from public.rounds where id=new.round_id;
  select user_id into v_user from public.players where room_id=v_room and player_id=new.player_id limit 1;
 end if;
 if private.limbo_blocked(v_room,v_user) then raise exception 'Limbo active: return is blocked';end if;
 return new;
end $$;
revoke all on function private.limbo_return_guard() from public,anon,authenticated;
drop trigger if exists limbo_return_guard on public.players;
create trigger limbo_return_guard before insert or update on public.players for each row execute function private.limbo_return_guard();
drop trigger if exists limbo_request_guard on public.debate_presence_requests;
create trigger limbo_request_guard before insert or update on public.debate_presence_requests for each row execute function private.limbo_return_guard();

create or replace function private.resolve_limbo(p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare l private.debate_limbo_proposals%rowtype;v_room bigint;v_phase text;v_players bigint;v_yes bigint;v_no bigint;v_need bigint;v_host text;v_next text;
begin
 select * into l from private.debate_limbo_proposals where id=p_id;
 if l.id is null or l.status<>'open' then return;end if;
 select room_id,debate_phase into v_room,v_phase from public.rounds where id=l.round_id for update;
 select * into l from private.debate_limbo_proposals where id=p_id for update;
 if l.status<>'open' then return;end if;
 if v_phase<>'debate' or not exists(select 1 from public.players where room_id=v_room and user_id=l.target_user_id and abandoned_at is null and presence='present') then
  update private.debate_limbo_proposals set status='rejected' where id=p_id;return;
 end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from private.debate_limbo_votes v where v.proposal_id=p_id and exists(select 1 from public.players p where p.room_id=v_room and p.user_id=v.user_id and p.abandoned_at is null and p.presence='present');
 v_need:=floor(v_players/2.0)::bigint+1;
 if v_yes>=v_need then
  select host_id into v_host from public.rooms where id=v_room for update;
  if v_host=l.target_player_id then
   select player_id into v_next from public.players where room_id=v_room and abandoned_at is null and presence='present' and user_id<>l.target_user_id order by created_at,player_id limit 1;
   if v_next is null then update private.debate_limbo_proposals set status='rejected' where id=p_id;return;end if;
   update public.rooms set host_id=v_next where id=v_room;
  end if;
  update private.debate_limbo_proposals set status='accepted',accepted_at=clock_timestamp(),until_at=case when duration_seconds=0 then null else clock_timestamp()+make_interval(secs=>duration_seconds) end where id=p_id;
  update public.players set presence='absent' where room_id=v_room and user_id=l.target_user_id;
  update public.debate_presence_requests set status='rejected' where round_id=l.round_id and player_id=l.target_player_id and status='open';
 elsif v_no>v_players-v_need or v_yes+v_no>=v_players then
  update private.debate_limbo_proposals set status='rejected' where id=p_id;
 end if;
end $$;
revoke all on function private.resolve_limbo(bigint) from public,anon,authenticated;

create or replace function private.limbo_state(p_round bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_room bigint;v_phase text;v_paused boolean;l private.debate_limbo_proposals%rowtype;m private.debate_limbo_proposals%rowtype;v_yes bigint;v_no bigint;v_players bigint;v_mine text;v_targets jsonb;v_me text;v_presence text;
begin
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round;
 select player_id,presence into v_me,v_presence from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if auth.uid() is null or v_me is null then raise exception 'Not in room';end if;
 select * into l from private.debate_limbo_proposals where round_id=p_round and status='open' limit 1;
 if l.id is not null then perform private.resolve_limbo(l.id);select * into l from private.debate_limbo_proposals where id=l.id;end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select coalesce(jsonb_agg(jsonb_build_object('id',player_id,'name',name) order by created_at,player_id),'[]'::jsonb) into v_targets
 from public.players where room_id=v_room and abandoned_at is null and presence='present' and user_id<>auth.uid();
 select * into m from private.debate_limbo_proposals where round_id=p_round and target_user_id=auth.uid() and status='accepted' order by id desc limit 1;
 if l.status='open' then
  select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no from private.debate_limbo_votes v where proposal_id=l.id and exists(select 1 from public.players p where p.room_id=v_room and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
  select choice into v_mine from private.debate_limbo_votes where proposal_id=l.id and user_id=auth.uid();
 end if;
 select presence into v_presence from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 return jsonb_build_object('server_now',clock_timestamp(),'phase',v_phase,'paused',v_paused,'present',v_presence='present','targets',v_targets,
 'blocked',private.limbo_blocked(v_room,auth.uid()),'until_at',m.until_at,'until_end',m.id is not null and m.duration_seconds=0,
 'proposal',case when l.status='open' then jsonb_build_object('id',l.id,'name',l.target_name,'duration',l.duration_seconds,'proposer_me',l.proposer_user_id=auth.uid(),'yes',v_yes,'no',v_no,'players',v_players,'mine',v_mine) else null end);
end $$;
revoke all on function private.limbo_state(bigint) from public,anon;
grant execute on function private.limbo_state(bigint) to authenticated;

create or replace function private.limbo_action(p_round bigint,p_target text,p_duration integer,p_proposal bigint,p_choice text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_room bigint;v_phase text;v_paused boolean;v_cycle bigint;v_me text;v_target public.players%rowtype;v_id bigint;l private.debate_limbo_proposals%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select room_id,debate_phase,paused,vote_cycle into v_room,v_phase,v_paused,v_cycle from public.rounds where id=p_round for update;
 select player_id into v_me from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Not active';end if;
 if p_proposal is not null then
  select * into l from private.debate_limbo_proposals where id=p_proposal and round_id=p_round for update;
  if l.id is null or l.status<>'open' or v_phase<>'debate' then return jsonb_build_object('status','closed');end if;
  if p_choice is null or p_choice not in('YES','NO') then raise exception 'Invalid choice';end if;
  if l.proposer_user_id=auth.uid() then raise exception 'Proposer already voted YES';end if;
  insert into private.debate_limbo_votes values(l.id,auth.uid(),p_choice) on conflict(proposal_id,user_id) do update set choice=excluded.choice;
  perform private.resolve_limbo(l.id);
  return jsonb_build_object('status',(select status from private.debate_limbo_proposals where id=l.id));
 end if;
 perform private.context_guard(p_round);
 if v_phase<>'debate' or v_paused or p_duration is null or p_duration not in(0,180,300,600) then raise exception 'Limbo unavailable';end if;
 if exists(select 1 from public.debate_pause_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_presence_requests where round_id=p_round and status='open')
 or exists(select 1 from public.debate_twist_proposals where round_id=p_round and vote_cycle=v_cycle and status='open')
 or exists(select 1 from public.debate_revote_proposals where round_id=p_round and vote_cycle=v_cycle and status='open')
 or exists(select 1 from public.debate_optional_revote_windows where round_id=p_round and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Another proposal must be resolved first';end if;
 select * into v_target from public.players where room_id=v_room and player_id=p_target and abandoned_at is null and presence='present' and user_id<>auth.uid() limit 1;
 if v_target.id is null then raise exception 'Target unavailable';end if;
 insert into private.debate_limbo_proposals(round_id,target_user_id,target_player_id,target_name,proposer_user_id,duration_seconds)
 values(p_round,v_target.user_id,v_target.player_id,v_target.name,auth.uid(),p_duration) returning id into v_id;
 insert into private.debate_limbo_votes values(v_id,auth.uid(),'YES');
 return jsonb_build_object('id',v_id,'status','open');
end $$;
revoke all on function private.limbo_action(bigint,text,integer,bigint,text) from public,anon;
grant execute on function private.limbo_action(bigint,text,integer,bigint,text) to authenticated;
create or replace function public.propose_debate_limbo(p_round_id bigint,p_target_id text,p_duration_seconds integer) returns jsonb
language sql security invoker set search_path='' as $$select private.limbo_action(p_round_id,p_target_id,p_duration_seconds,null,null)$$;
create or replace function public.cast_debate_limbo_vote(p_round_id bigint,p_proposal_id bigint,p_choice text) returns jsonb
language sql security invoker set search_path='' as $$select private.limbo_action(p_round_id,null,null,p_proposal_id,p_choice)$$;
revoke all on function public.propose_debate_limbo(bigint,text,integer),public.cast_debate_limbo_vote(bigint,bigint,text) from public,anon;
grant execute on function public.propose_debate_limbo(bigint,text,integer),public.cast_debate_limbo_vote(bigint,bigint,text) to authenticated;

create or replace function private.change_lobby_size(p_room bigint,p_delta integer) returns bigint
language plpgsql security definer set search_path='' as $$
declare r public.rooms%rowtype;v_count bigint;v_next bigint;
begin
 if auth.uid() is null or p_delta is null or abs(p_delta)<>1 then raise exception 'Invalid request';end if;
 select * into r from public.rooms where id=p_room for update;
 if r.status<>'waiting' or not exists(select 1 from public.players where room_id=p_room and player_id=r.host_id and user_id=auth.uid() and abandoned_at is null) then raise exception 'Host required in hall';end if;
 select count(*) into v_count from public.players where room_id=p_room and abandoned_at is null;
 v_next:=greatest(v_count,case when r.mode='debate' then 1 else 2 end,least(20,r.expected_players+p_delta));
 update public.rooms set expected_players=v_next where id=p_room;return v_next;
end $$;
revoke all on function private.change_lobby_size(bigint,integer) from public,anon;
grant execute on function private.change_lobby_size(bigint,integer) to authenticated;
create or replace function public.change_lobby_size(p_room_id bigint,p_delta integer) returns bigint
language sql security invoker set search_path='' as $$select private.change_lobby_size(p_room_id,p_delta)$$;
revoke all on function public.change_lobby_size(bigint,integer) from public,anon;
grant execute on function public.change_lobby_size(bigint,integer) to authenticated;

create or replace function private.context_guard(p_round bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 perform 1 from public.rounds where id=p_round for update;
 if exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open') then raise exception 'Another proposal must be resolved first';end if;
end $$;

do $replace$ declare v_def text;begin
 select pg_get_functiondef('public.get_debate_state(bigint)'::regprocedure) into v_def;
 if strpos(v_def,'''limbo_state''')=0 then
  v_def:=replace(v_def,'''context_state'',private.context_state(p_round_id)', '''context_state'',private.context_state(p_round_id),''limbo_state'',private.limbo_state(p_round_id)');
  execute v_def;
 end if;
end $replace$;

do $coherent$ declare d text;begin
 select pg_get_functiondef('public.get_debate_state(bigint)'::regprocedure) into d;
 if strpos(d,'v_limbo jsonb')=0 then
  d:=replace(d,'declare v_room bigint;','declare v_limbo jsonb;v_room bigint;');
  d:=replace(d,'select count(*) filter(where abandoned_at is null)','v_limbo:=private.limbo_state(p_round_id);'||chr(10)||' select count(*) filter(where abandoned_at is null)');
  d:=replace(d,'''limbo_state'',private.limbo_state(p_round_id)', '''limbo_state'',v_limbo');
  execute d;
 end if;
end $coherent$;
revoke execute on function public.get_debate_state(bigint) from public,anon;
grant execute on function public.get_debate_state(bigint) to authenticated;

notify pgrst,'reload schema';
commit;
