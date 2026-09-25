create table if not exists public.debate_pause_proposals (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 desired_paused boolean not null,
 proposer_id text not null,
 proposer_user_id uuid not null,
 status text not null default 'open' check(status in ('open','accepted','rejected')),
 created_at timestamptz not null default now()
);
create unique index if not exists debate_pause_proposals_one_open on public.debate_pause_proposals(round_id) where status='open';
alter table public.debate_pause_proposals enable row level security;
revoke all on public.debate_pause_proposals from public, anon, authenticated;
create table if not exists public.debate_pause_votes (
 id bigint generated always as identity primary key,
 proposal_id bigint not null references public.debate_pause_proposals(id) on delete cascade,
 player_id text not null,
 user_id uuid not null,
 choice text not null check(choice in ('YES','NO')),
 created_at timestamptz not null default now(),
 unique(proposal_id,player_id)
);
alter table public.debate_pause_votes enable row level security;
revoke all on public.debate_pause_votes from public, anon, authenticated;

create or replace function public.propose_debate_pause(p_round_id bigint,p_desired_paused boolean)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_room bigint;v_phase text;v_paused boolean;v_player text;v_id bigint;v_players bigint;
begin
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused=p_desired_paused then raise exception 'Pause proposal unavailable'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_id from public.debate_pause_proposals where round_id=p_round_id and status='open' limit 1;
 if v_id is not null then raise exception 'Table decision already open'; end if;
 insert into public.debate_pause_proposals(round_id,desired_paused,proposer_id,proposer_user_id)
 values(p_round_id,p_desired_paused,v_player,auth.uid()) returning id into v_id;
 insert into public.debate_pause_votes(proposal_id,player_id,user_id,choice) values(v_id,v_player,auth.uid(),'YES');
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 if v_players=1 then
   update public.debate_pause_proposals set status='accepted' where id=v_id;
   update public.rounds set paused=p_desired_paused where id=p_round_id;
 end if;
 return jsonb_build_object('id',v_id,'yes',1,'players',v_players);
end $$;
create or replace function public.get_debate_pause_proposal(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_room bigint;v_player text;v_id bigint;v_desired boolean;v_proposer text;v_yes bigint;v_no bigint;v_players bigint;v_mine text;
begin
 select room_id into v_room from public.rounds where id=p_round_id;
 select player_id into v_player from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if v_player is null then raise exception 'Not in room'; end if;
 select id,desired_paused,proposer_id into v_id,v_desired,v_proposer
 from public.debate_pause_proposals where round_id=p_round_id and status='open' order by id desc limit 1;
 if v_id is null then return jsonb_build_object('open',false); end if;
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from public.debate_pause_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.proposal_id=v_id and p.abandoned_at is null and p.presence='present';
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select choice into v_mine from public.debate_pause_votes where proposal_id=v_id and player_id=v_player;
 return jsonb_build_object('open',true,'id',v_id,'desired_paused',v_desired,'proposer_me',v_player=v_proposer,
 'mine',v_mine,'yes',v_yes,'no',v_no,'voted',v_yes+v_no,'players',v_players);
end $$;
create or replace function public.cast_debate_pause_vote(p_proposal_id bigint,p_choice text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_round bigint;v_room bigint;v_proposer text;v_desired boolean;v_player text;v_players bigint;v_yes bigint;v_no bigint;v_need bigint;v_voted bigint;v_result text:='open';
begin
 if p_choice not in ('YES','NO') then raise exception 'Invalid choice'; end if;
 select round_id into v_round from public.debate_pause_proposals where id=p_proposal_id;
 if v_round is null then raise exception 'Proposal not found'; end if;
 select room_id into v_room from public.rounds where id=v_round for update;
 select proposer_id,desired_paused into v_proposer,v_desired from public.debate_pause_proposals where id=p_proposal_id and status='open' for update;
 if v_proposer is null then raise exception 'Proposal closed'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 if v_player=v_proposer then raise exception 'Proposer has already voted YES'; end if;
 insert into public.debate_pause_votes(proposal_id,player_id,user_id,choice) values(p_proposal_id,v_player,auth.uid(),p_choice)
 on conflict(proposal_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO'),count(*) into v_yes,v_no,v_voted
 from public.debate_pause_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.proposal_id=p_proposal_id and p.abandoned_at is null and p.presence='present';
 if v_yes>=v_need then
   v_result:='accepted';
   update public.rounds set paused=v_desired where id=v_round;
 elsif v_no>v_players-v_need or v_voted>=v_players then
   v_result:='rejected';
 end if;
 if v_result<>'open' then update public.debate_pause_proposals set status=v_result where id=p_proposal_id; end if;
 return jsonb_build_object('status',v_result,'yes',v_yes,'no',v_no,'players',v_players);
end $$;
create or replace function public.set_debate_paused(p_round_id bigint,p_paused boolean)
returns void language plpgsql security definer set search_path to '' as $$
begin
 raise exception 'Pause now requires a table vote';
end $$;
revoke all on function public.propose_debate_pause(bigint,boolean),public.get_debate_pause_proposal(bigint),public.cast_debate_pause_vote(bigint,text) from public,anon;
grant execute on function public.propose_debate_pause(bigint,boolean),public.get_debate_pause_proposal(bigint),public.cast_debate_pause_vote(bigint,text) to authenticated;