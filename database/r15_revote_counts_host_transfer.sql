
alter table public.debate_optional_revote_windows add column if not exists closed_at timestamptz;
create or replace function public.get_optional_debate_revote(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_room bigint;v_cycle bigint;v_window public.debate_optional_revote_windows%rowtype;v_done boolean;v_a bigint;v_b bigint;v_players bigint;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle;
 select exists(select 1 from public.debate_optional_revote_choices where window_id=v_window.id and user_id=(select auth.uid())) into v_done;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where c.choice='A'),count(*) filter(where c.choice='B') into v_a,v_b
 from public.debate_optional_revote_choices c join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window.id and p.abandoned_at is null and p.presence='present';
 return jsonb_build_object('open',v_window.id is not null and v_window.closed_at is null,'used',v_window.id is not null,
 'cycle',v_cycle,'mine_done',v_done,'votes_a',v_a,'votes_b',v_b,'voted',v_a+v_b,'players',v_players);
end $$;
create or replace function public.cast_optional_debate_revote(p_round_id bigint,p_choice text)
returns void language plpgsql security definer set search_path = ''
as $$
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
 if v_players>0 and v_voted>=v_players then update public.debate_optional_revote_windows set closed_at=now() where id=v_window; end if;
end $$;
revoke all on function public.get_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) from public,anon;
grant execute on function public.get_optional_debate_revote(bigint),public.cast_optional_debate_revote(bigint,text) to authenticated;


do $$
declare d text;
begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='leave_debate_temporarily' and p.prokind='f';
 if d is null or position('v_event_id bigint;' in d)=0 or position('update players set presence=''absent'' where room_id=v_room and player_id=v_me and abandoned_at is null;' in d)=0 then raise exception 'Unexpected absence function'; end if;
 d:=replace(d,'v_event_id bigint;','v_event_id bigint;v_host text;v_next_host text;');
 d:=replace(d,
 'update players set presence=''absent'' where room_id=v_room and player_id=v_me and abandoned_at is null;',
 'select host_id into v_host from rooms where id=v_room for update;
 if v_host=v_me then
   select player_id into v_next_host from players
   where room_id=v_room and player_id<>v_me and abandoned_at is null and presence=''present''
   order by created_at,player_id limit 1;
   if v_next_host is null then raise exception ''Another present player is needed before the host can leave temporarily''; end if;
   update rooms set host_id=v_next_host where id=v_room;
 end if;
 update players set presence=''absent'' where room_id=v_room and player_id=v_me and abandoned_at is null;');
 execute d;
end $$;