-- DILEMA R14: one optional vote per player/cycle; disable GIRO during pause.
-- Applied to live Supabase on 2026-09-24.

create table if not exists public.debate_optional_revote_choices (
 id bigint generated always as identity primary key,
 window_id bigint not null references public.debate_optional_revote_windows(id) on delete cascade,
 player_id text not null,
 user_id uuid not null,
 choice text not null check (choice in ('A','B')),
 created_at timestamptz not null default now(),
 unique(window_id,player_id)
);
alter table public.debate_optional_revote_choices enable row level security;
revoke all on public.debate_optional_revote_choices from anon,authenticated;
revoke all on sequence public.debate_optional_revote_choices_id_seq from anon,authenticated;
create or replace function public.get_optional_debate_revote(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_window public.debate_optional_revote_windows%rowtype;v_done boolean;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle;
 select exists(select 1 from public.debate_optional_revote_choices where window_id=v_window.id and user_id=(select auth.uid())) into v_done;
 return jsonb_build_object('open',v_window.id is not null,'cycle',v_cycle,'mine_done',v_done);
end $$;
create or replace function public.cast_optional_debate_revote(p_round_id bigint,p_choice text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_player text;v_window bigint;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 select id into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle;
 if v_window is null then raise exception 'Revote window closed'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into public.debate_optional_revote_choices(window_id,player_id,user_id,choice)
 values(v_window,v_player,(select auth.uid()),p_choice) on conflict(window_id,player_id) do nothing;
 if not found then raise exception 'Already revoted this cycle'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
end $$;
revoke all on function public.get_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) from public,anon;
grant execute on function public.get_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) to authenticated;

do $$
declare d text;
begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='propose_debate_twist_vote' and p.prokind='f';
 if position('v_open boolean;v_num bigint;' in d)=0 then raise exception 'Unexpected GIRO proposal function'; end if;
 d:=replace(d,'v_open boolean;v_num bigint;','v_open boolean;v_paused boolean;v_num bigint;');
 d:=replace(d,'select room_id,vote_cycle,debate_phase,twist_request_open into v_room,v_cycle,v_phase,v_open from rounds where id=p_round_id;','select room_id,vote_cycle,debate_phase,twist_request_open,paused into v_room,v_cycle,v_phase,v_open,v_paused from rounds where id=p_round_id;');
 d:=replace(d,'if v_phase<>''debate'' or not coalesce(v_open,false) then','if v_phase<>''debate'' or not coalesce(v_open,false) or v_paused then');
 execute d;
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='cast_debate_twist_vote' and p.prokind='f';
 if position('v_num bigint;v_player text;' in d)=0 then raise exception 'Unexpected GIRO vote function'; end if;
 d:=replace(d,'v_num bigint;v_player text;','v_num bigint;v_phase text;v_paused boolean;v_player text;');
 d:=replace(d,'select room_id,vote_cycle into v_room,v_cycle from rounds where id=p_round_id;', 'select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from rounds where id=p_round_id;
 if v_room is null or v_phase<>''debate'' or v_paused then raise exception ''GIRO vote unavailable''; end if;');
 execute d;
end $$;
