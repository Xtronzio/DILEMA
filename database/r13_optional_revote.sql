-- DILEMA R13: optional re-vote, opened by any present player without permission from the table.
-- Applied to the live Supabase project on 2026-09-24.

create table if not exists public.debate_optional_revote_windows (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 vote_cycle bigint not null,
 opened_by uuid not null,
 opened_at timestamptz not null default now(),
 unique(round_id,vote_cycle)
);
alter table public.debate_optional_revote_windows enable row level security;
revoke all on public.debate_optional_revote_windows from anon,authenticated;
revoke all on sequence public.debate_optional_revote_windows_id_seq from anon,authenticated;
create or replace function public.get_optional_debate_revote(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_window public.debate_optional_revote_windows%rowtype;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle;
 return jsonb_build_object('open',v_window.id is not null,'cycle',v_cycle);
end $$;
create or replace function public.open_optional_debate_revote(p_round_id bigint)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 insert into public.debate_optional_revote_windows(round_id,vote_cycle,opened_by)
 values(p_round_id,v_cycle,(select auth.uid())) on conflict(round_id,vote_cycle) do nothing;
end $$;
create or replace function public.cast_optional_debate_revote(p_round_id bigint,p_choice text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_player text;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 if not exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle) then raise exception 'Revote window closed'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
end $$;
revoke all on function public.get_optional_debate_revote(bigint),public.open_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) from public,anon;
grant execute on function public.get_optional_debate_revote(bigint),public.open_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) to authenticated;

-- The old approval ballot RPCs are retired. The GIRO re-vote RPC stays available.
revoke execute on function public.propose_debate_revote(bigint),public.cast_debate_revote_proposal_vote(bigint,text),public.get_debate_revote_proposal(bigint) from authenticated;
