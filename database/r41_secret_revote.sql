-- R41 · Sorteo y uso individual del re-voto secreto.
-- La tabla se consulta solo desde funciones verificadas: nadie puede leer la identidad del agraciado.
create table if not exists public.debate_secret_revotes (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 player_id text not null,
 user_id uuid not null,
 grant_cycle bigint not null,
 granted_at timestamptz not null default now(),
 used_at timestamptz,
 used_cycle bigint,
 from_choice text check (from_choice in ('A','B')),
 to_choice text check (to_choice in ('A','B'))
);
create unique index if not exists debate_secret_revotes_one_unspent on public.debate_secret_revotes(round_id,player_id) where used_at is null;
alter table public.debate_secret_revotes enable row level security;
revoke all on public.debate_secret_revotes from public,anon,authenticated;

create or replace function public.draw_debate_secret_revote(p_round_id bigint)
returns void language plpgsql security definer set search_path to '' as $function$
declare v_room bigint; v_cycle bigint; v_player text; v_user uuid;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null then raise exception 'Round not found'; end if;
 select p.player_id,p.user_id into v_player,v_user
 from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null
   and not exists (select 1 from public.debate_secret_revotes s where s.round_id=p_round_id and s.player_id=p.player_id and s.used_at is null)
 order by random() limit 1;
 if v_player is null then return; end if;
 insert into public.debate_secret_revotes(round_id,player_id,user_id,grant_cycle)
 values (p_round_id,v_player,v_user,v_cycle);
end $function$;
revoke all on function public.draw_debate_secret_revote(bigint) from public,anon,authenticated;

create or replace function public.cast_debate_secret_revote(p_round_id bigint,p_choice text)
returns void language plpgsql security definer set search_path to '' as $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_player text; v_resource bigint; v_old text;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Secret revote unavailable'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Public revote in progress'; end if;
 select player_id into v_player from public.players
 where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_resource from public.debate_secret_revotes
 where round_id=p_round_id and player_id=v_player and user_id=(select auth.uid()) and used_at is null for update;
 if v_resource is null then raise exception 'No secret revote available'; end if;
 select choice into v_old from public.debate_vote_cycles
 where round_id=p_round_id and cycle_number=v_cycle and player_id=v_player for update;
 if v_old is null then raise exception 'Vote missing'; end if;
 if v_old=p_choice then raise exception 'Choose a different option'; end if;
 update public.debate_vote_cycles set choice=p_choice where round_id=p_round_id and cycle_number=v_cycle and player_id=v_player;
 update public.debate_secret_revotes set used_at=now(),used_cycle=v_cycle,from_choice=v_old,to_choice=p_choice where id=v_resource;
end $function$;
revoke all on function public.cast_debate_secret_revote(bigint,text) from public,anon;
grant execute on function public.cast_debate_secret_revote(bigint,text) to authenticated;

CREATE OR REPLACE FUNCTION public.complete_debate_revote(p_round_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; vp bigint; vv bigint;
begin
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'twist' then return false; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 select count(*) into vp from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into vv from public.debate_vote_cycles d join public.players p on p.room_id=v_room and p.player_id=d.player_id
 where d.round_id=p_round_id and d.cycle_number=v_cycle+1 and p.abandoned_at is null and p.presence='present';
 if vp=0 or vv<vp then return false; end if;
 update public.rounds set vote_cycle=v_cycle+1,debate_phase='debate',twist_request_open=true where id=p_round_id;
 delete from public.debate_twist_requests where round_id=p_round_id and vote_cycle<=v_cycle;
 perform public.draw_debate_proclamation(p_round_id);
 perform public.draw_debate_secret_revote(p_round_id);
 return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.cast_optional_debate_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_player text;v_window bigint;v_players bigint;v_voted bigint;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 select id into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null;
 if v_window is null then raise exception 'Revote window closed'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into public.debate_optional_revote_choices(window_id,player_id,user_id,choice)
 values(v_window,v_player,(select auth.uid()),p_choice) on conflict(window_id,player_id) do nothing;
 if not found then raise exception 'Already revoted this cycle'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into v_voted from public.debate_optional_revote_choices c join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window and p.abandoned_at is null and p.presence='present';
 if v_players>0 and v_voted>=v_players then
   update public.debate_optional_revote_windows set closed_at=now() where id=v_window;
   perform public.draw_debate_proclamation(p_round_id);
   perform public.draw_debate_secret_revote(p_round_id);
 end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select count(*) filter(where abandoned_at is null), count(*) filter(where abandoned_at is null and presence='present'), count(*) filter(where abandoned_at is null and presence='absent'), count(*) filter(where abandoned_at is not null)
 into vtotal,vp,v_absent,v_abandoned from players where room_id=v_room;
 select count(*) filter(where choice='A'),count(*) filter(where choice='B') into va,vb
 from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*) into vr from debate_twist_requests dtr join players p on p.player_id=dtr.player_id and p.room_id=v_room
 where dtr.round_id=p_round_id and dtr.vote_cycle=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where dvc.choice='A'),count(*) filter(where dvc.choice='B') into v_next,v_next_a,v_next_b from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle+1 and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where used_at is not null) into v_pro_assigned,v_pro_used from debate_proclamations where round_id=p_round_id;
 select count(*),count(*) filter(where used_at is not null),coalesce(bool_or(user_id=auth.uid() and used_at is null),false)
 into v_secret_assigned,v_secret_used,v_secret_mine from debate_secret_revotes where round_id=p_round_id;
 if v_close>0 then
   select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no
   from debate_close_votes dcv join players p on p.player_id=dcv.player_id and p.room_id=v_room
   where dcv.round_id=p_round_id and dcv.proposal_number=v_close and p.abandoned_at is null and p.presence='present';
 end if;
 return jsonb_build_object('phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine);
end $function$
;
