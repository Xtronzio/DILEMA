-- DILEMA R10: collective re-vote. Applied to the live Supabase project on 2026-09-24.
-- Kept here so the database engine can be restored alongside the web app.

create table if not exists public.debate_revote_proposals (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 vote_cycle bigint not null,
 proposal_number bigint not null,
 status text not null default 'open' check (status in ('open','accepted','rejected')),
 created_at timestamptz not null default now(),
 unique(round_id,vote_cycle,proposal_number)
);
create table if not exists public.debate_revote_votes (
 id bigint generated always as identity primary key,
 proposal_id bigint not null references public.debate_revote_proposals(id) on delete cascade,
 player_id text not null,
 user_id uuid not null,
 choice text not null check (choice in ('YES','NO')),
 created_at timestamptz not null default now(),
 unique(proposal_id,player_id)
);
alter table public.debate_revote_proposals enable row level security;
alter table public.debate_revote_votes enable row level security;
revoke all on public.debate_revote_proposals, public.debate_revote_votes from anon, authenticated;
revoke all on sequence public.debate_revote_proposals_id_seq, public.debate_revote_votes_id_seq from anon, authenticated;
create or replace function public.get_debate_revote_proposal(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_room bigint; v_cycle bigint; v_proposal public.debate_revote_proposals%rowtype; v_yes bigint; v_no bigint; v_mine text; v_players bigint;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_proposal from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle order by proposal_number desc limit 1;
 if v_proposal.id is null then return null; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from public.debate_revote_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.proposal_id=v_proposal.id and p.abandoned_at is null and p.presence='present';
 select choice into v_mine from public.debate_revote_votes where proposal_id=v_proposal.id and user_id=(select auth.uid());
 return jsonb_build_object('proposal',v_proposal.proposal_number,'status',v_proposal.status,'yes',v_yes,'no',v_no,'voted',v_yes+v_no,'players',v_players,'mine',v_mine);
end $$;
create or replace function public.propose_debate_revote(p_round_id bigint)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_num bigint; v_status text;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 select proposal_number,status into v_num,v_status from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle order by proposal_number desc limit 1;
 if v_status='accepted' then raise exception 'Revote already accepted'; end if;
 if v_status='open' then return v_num; end if;
 v_num:=coalesce(v_num,0)+1;
 insert into public.debate_revote_proposals(round_id,vote_cycle,proposal_number) values(p_round_id,v_cycle,v_num);
 return v_num;
end $$;
create or replace function public.cast_debate_revote_proposal_vote(p_round_id bigint,p_choice text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_room bigint; v_cycle bigint; v_phase text; v_player text; v_id bigint; v_players bigint; v_yes bigint; v_no bigint; v_need bigint;
begin
 if p_choice not in ('YES','NO') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' then raise exception 'No active debate'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_id from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open' order by proposal_number desc limit 1;
 if v_id is null then raise exception 'No open revote proposal'; end if;
 insert into public.debate_revote_votes(proposal_id,player_id,user_id,choice) values(v_id,v_player,(select auth.uid()),p_choice)
 on conflict(proposal_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from public.debate_revote_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.proposal_id=v_id and p.abandoned_at is null and p.presence='present';
 if v_yes>=v_need then
   update public.debate_revote_proposals set status='accepted' where id=v_id;
   update public.rounds set debate_phase='twist',twist_request_open=false where id=p_round_id;
   return true;
 elsif v_no>=v_need then
   update public.debate_revote_proposals set status='rejected' where id=v_id;
 end if;
 return false;
end $$;
create or replace function public.cast_debate_revote(p_round_id bigint,p_choice text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_room bigint; v_cycle bigint; v_phase text; v_player text;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'twist' then raise exception 'Revote unavailable'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 if not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle)
 and not exists(select 1 from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='accepted')
 then raise exception 'No approved revote'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle+1,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
end $$;
create or replace function public.complete_debate_revote(p_round_id bigint)
returns boolean language plpgsql security definer set search_path = ''
as $$
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
 return true;
end $$;
revoke all on function public.get_debate_revote_proposal(bigint),public.propose_debate_revote(bigint),public.cast_debate_revote_proposal_vote(bigint,text),public.cast_debate_revote(bigint,text),public.complete_debate_revote(bigint) from public,anon;
grant execute on function public.get_debate_revote_proposal(bigint),public.propose_debate_revote(bigint),public.cast_debate_revote_proposal_vote(bigint,text),public.cast_debate_revote(bigint,text),public.complete_debate_revote(bigint) to authenticated;

-- Remove the original automatic GIRO in the initial unanimous vote.
do $$
declare v_definition text;
begin
 select pg_get_functiondef(p.oid) into v_definition
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='start_debate_engine' and p.prokind='f';
 if v_definition is null or position('select public.launch_debate_twist(p_round_id,''unanimity'') into v_twist;' in v_definition)=0
 then raise exception 'Expected unanimity launch not found'; end if;
 v_definition:=replace(v_definition,
 'select public.launch_debate_twist(p_round_id,''unanimity'') into v_twist;',
 'v_twist:=null;');
 execute v_definition;
end $$;
