-- R82: host opens admissions; the present table decides each applicant.
create table private.world_dilemma_history (
 scope text not null, conflict_key text not null, created_at timestamptz not null default now(),
 primary key(scope,conflict_key)
);
alter table private.world_dilemma_history enable row level security;
revoke all on private.world_dilemma_history from public,anon,authenticated;
create function private.world_key(p_id bigint) returns text language sql stable security definer set search_path='' as $$
 select case when d.news_meta->>'url' is not null then 'news:'||split_part(split_part(d.news_meta->>'url','#',1),'?',1) else 'dilemma:'||md5(lower(regexp_replace(d.question,'\s+',' ','g'))) end from public.dilemmas d where id=p_id
$$;
create function private.world_seen(p_id bigint,p_user uuid,p_room bigint) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.world_dilemma_history h where h.conflict_key=private.world_key(p_id) and (h.scope='user:'||p_user::text or h.scope='room:'||p_room::text or (p_room is not null and exists(select 1 from public.players p where p.room_id=p_room and p.abandoned_at is null and h.scope='user:'||p.user_id::text))))
 or (p_room is not null and exists(select 1 from public.rounds r where r.room_id=p_room and private.world_key(r.dilemma_id)=private.world_key(p_id)))
$$;
create function private.remember_world(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.dilemmas where id=p_id and active) then raise exception 'Invalid dilemma';end if;
 insert into private.world_dilemma_history(scope,conflict_key) values('user:'||auth.uid()::text,private.world_key(p_id)) on conflict do nothing;
end $$;
create function public.remember_world_dilemma(p_id bigint) returns void language sql set search_path='' as $$ select private.remember_world(p_id) $$;
create function private.archive_world_round() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.dilemmas where id=new.dilemma_id and source_kind='current') or exists(select 1 from public.debate_selections where room_id=new.room_id and theme like 'ACTUALIDAD IA:%' and phase in('questions','runoff')) then
  insert into private.world_dilemma_history(scope,conflict_key) values('room:'||new.room_id::text,private.world_key(new.dilemma_id)) on conflict do nothing;
  insert into private.world_dilemma_history(scope,conflict_key) select 'user:'||user_id::text,private.world_key(new.dilemma_id) from public.players where room_id=new.room_id and abandoned_at is null and user_id is not null on conflict do nothing;
 end if;return new;
end $$;
create trigger archive_world_round after insert on public.rounds for each row execute function private.archive_world_round();
-- Filter cached and fallback proposals identically, without generating more AI calls.
create function private.fresh_world_candidates(p_ids jsonb,p_user uuid,p_room bigint,p_intensity integer,p_theme text) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids jsonb;kind text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' or p_user is null or p_intensity not between 1 and 3 then raise exception 'Forbidden';end if;
 if p_room is not null and not exists(select 1 from public.players where room_id=p_room and user_id=p_user and presence='present' and abandoned_at is null) then raise exception 'Not in room';end if;
 select jsonb_agg(id) into ids from (select distinct on(private.world_key(d.id)) d.id from public.dilemmas d where d.active and d.audience='teen' and d.id in(select value::bigint from jsonb_array_elements_text(coalesce(p_ids,'[]')) x(value)) and not private.world_seen(d.id,p_user,p_room) order by private.world_key(d.id),d.id limit 3) t;
 if ids is not null then return jsonb_build_object('ids',ids);end if;
 select jsonb_agg(id) into ids from (
  select distinct on (private.world_key(d.id)) d.id,d.created_at from public.dilemmas d where d.active and d.audience='teen' and d.source_kind='current' and d.news_meta->>'date'>=to_char(current_date-14,'YYYY-MM-DD') and d.news_meta->>'date'<=to_char(current_date+1,'YYYY-MM-DD') and not private.world_seen(d.id,p_user,p_room) order by private.world_key(d.id),abs(d.intensity-p_intensity),(d.debate_theme=p_theme) desc,d.created_at desc limit 3
 ) t;kind:='previous_news';
 if ids is null then
  select jsonb_agg(id) into ids from (select d.id from public.dilemmas d where d.active and d.audience='teen' and d.source_kind='catalog' and not private.world_seen(d.id,p_user,p_room) order by abs(d.intensity-p_intensity),(d.debate_theme=p_theme) desc,random() limit 3) t;
  kind:='catalog';
 end if;
 return jsonb_build_object('ids',coalesce(ids,'[]'::jsonb),'fallback',kind);
end $$;
create function public.fresh_world_candidates(p_ids jsonb,p_user uuid,p_room bigint,p_intensity integer,p_theme text) returns jsonb language sql set search_path='' as $$ select private.fresh_world_candidates(p_ids,p_user,p_room,p_intensity,p_theme) $$;
create table private.debate_admission_settings (
 room_id bigint primary key references public.rooms(id) on delete cascade,
 round_id bigint not null references public.rounds(id) on delete cascade,
 enabled boolean not null default false
);
create table private.debate_admissions (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 player_id text not null, name text not null, avatar text not null, motto text,
 status text not null default 'queued' check(status in('queued','open','accepted','rejected','cancelled')),
 created_at timestamptz not null default now(), decided_at timestamptz
);
create unique index admission_pending_user on private.debate_admissions(round_id,user_id) where status in('queued','open');
create unique index admission_one_open on private.debate_admissions(round_id) where status='open';
create index admission_queue on private.debate_admissions(round_id,status,id);
create index admission_owner on private.debate_admissions(user_id,id);
create table private.debate_admission_votes (
 request_id bigint not null references private.debate_admissions(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 choice boolean not null, primary key(request_id,user_id)
);
alter table private.debate_admission_settings enable row level security;
alter table private.debate_admissions enable row level security;
alter table private.debate_admission_votes enable row level security;
revoke all on private.debate_admission_settings,private.debate_admissions,private.debate_admission_votes from public,anon,authenticated;

create function private.admission_busy(p_round bigint) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rounds; n bigint;a bigint;b bigint;
begin
 select * into r from public.rounds where id=p_round;
 if r.id is null or r.status<>'debate' or r.debate_phase<>'debate' or r.paused then return true;end if;
 if exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_pause_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_presence_requests where round_id=p_round and status='open')
 or exists(select 1 from public.debate_twist_proposals where round_id=p_round and vote_cycle=r.vote_cycle and status='open')
 or exists(select 1 from public.debate_revote_proposals where round_id=p_round and vote_cycle=r.vote_cycle and status='open')
 or exists(select 1 from public.debate_optional_revote_windows where round_id=p_round and vote_cycle=r.vote_cycle and closed_at is null) then return true;end if;
 select count(*) into n from public.players where room_id=r.room_id and presence='present' and abandoned_at is null;
 select count(*) filter(where v.choice='A'),count(*) filter(where v.choice='B') into a,b from public.debate_vote_cycles v join public.players p on p.room_id=r.room_id and p.player_id=v.player_id where v.round_id=p_round and v.cycle_number=r.vote_cycle and p.presence='present' and p.abandoned_at is null;
 return n>1 and (a=n or b=n) and not exists(select 1 from public.debate_unanimity_decisions where round_id=p_round and vote_cycle=r.vote_cycle and outcome is not null);
end $$;

create function private.admission_pump(p_round bigint) returns void language plpgsql security definer set search_path='' as $$
declare r public.rounds;q private.debate_admissions;n bigint;y bigint;z bigint;
begin
 select * into r from public.rounds where id=p_round for update;
 if r.id is null then return;end if;
 if r.debate_phase='finished' or not exists(select 1 from public.rooms where id=r.room_id and status='playing') then
  update private.debate_admissions set status='cancelled',decided_at=now() where round_id=p_round and status in('queued','open');
  update private.debate_admission_settings set enabled=false where round_id=p_round;return;
 end if;
 select * into q from private.debate_admissions where round_id=p_round and status='open';
 if q.id is not null then
  select count(*) into n from public.players where room_id=r.room_id and presence='present' and abandoned_at is null;
  select count(*) filter(where v.choice),count(*) filter(where not v.choice) into y,z from private.debate_admission_votes v where v.request_id=q.id and exists(select 1 from public.players p where p.room_id=r.room_id and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
  if y>n/2 then
   perform 1 from public.rooms where id=r.room_id for update;
   if (select count(*) from public.players where room_id=r.room_id and abandoned_at is null)>=20
   or exists(select 1 from public.players where room_id=r.room_id and (user_id=q.user_id or player_id=q.player_id)) then
    update private.debate_admissions set status='rejected',decided_at=now() where id=q.id;
   else
    insert into public.players(room_id,player_id,user_id,name,avatar,motto,presence) values(r.room_id,q.player_id,q.user_id,q.name,q.avatar,q.motto,'present');
    update public.rooms set expected_players=greatest(expected_players,(select count(*) from public.players where room_id=r.room_id and abandoned_at is null)) where id=r.room_id;
    update private.debate_admissions set status='accepted',decided_at=now() where id=q.id;
   end if;
  elsif z>n/2 or y+z>=n then update private.debate_admissions set status='rejected',decided_at=now() where id=q.id;
  else return;end if;
 end if;
 if private.admission_busy(p_round) or exists(select 1 from private.debate_admissions adm join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where adm.round_id=p_round and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)) then return;end if;
 -- FIFO, with one ballot at a time. The applicant never votes on admission.
 update private.debate_admissions set status='open' where id=(select id from private.debate_admissions where round_id=p_round and status='queued' order by id limit 1);
end $$;

create function private.admission_state(p_round bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rounds;q private.debate_admissions;n bigint;y bigint;z bigint;mine boolean;host boolean;
begin
 select * into r from public.rounds where id=p_round;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room';end if;
 perform private.admission_pump(p_round);
 select * into q from private.debate_admissions where round_id=p_round and status='open';
 select count(*) into n from public.players where room_id=r.room_id and presence='present' and abandoned_at is null;
 select exists(select 1 from public.rooms x join public.players p on p.room_id=x.id and p.player_id=x.host_id where x.id=r.room_id and p.user_id=auth.uid() and p.presence='present' and p.abandoned_at is null) into host;
 if q.id is not null then
  select count(*) filter(where v.choice),count(*) filter(where not v.choice) into y,z from private.debate_admission_votes v where request_id=q.id and exists(select 1 from public.players p where p.room_id=r.room_id and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
  select choice into mine from private.debate_admission_votes where request_id=q.id and user_id=auth.uid();
 end if;
 return jsonb_build_object('enabled',coalesce((select enabled from private.debate_admission_settings where room_id=r.room_id and round_id=p_round),false),'is_host',host,'id',q.id,'name',q.name,'yes',coalesce(y,0),'no',coalesce(z,0),'players',n,'mine',mine,'present',exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and presence='present' and abandoned_at is null),'queued',(select count(*) from private.debate_admissions where round_id=p_round and status='queued'),'needs_vote',exists(select 1 from private.debate_admissions where round_id=p_round and user_id=auth.uid() and status='accepted') and not exists(select 1 from public.debate_vote_cycles where round_id=p_round and cycle_number=r.vote_cycle and user_id=auth.uid()),'can_vote',not private.admission_busy(p_round) and q.id is null,'waiting_votes',(select count(*) from private.debate_admissions adm join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where adm.round_id=p_round and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)));
end $$;

create function private.set_admission(p_room bigint,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
declare rd bigint;
begin
 select id into rd from public.rounds where room_id=p_room order by id desc limit 1;
 perform 1 from public.rounds where id=rd for update;
 if auth.uid() is null or not exists(select 1 from public.rooms r join public.players p on p.room_id=r.id and p.player_id=r.host_id where r.id=p_room and r.mode='debate' and r.status='playing' and p.user_id=auth.uid() and p.abandoned_at is null and p.presence='present') then raise exception 'Host only';end if;
 insert into private.debate_admission_settings(room_id,round_id,enabled) values(p_room,rd,p_enabled) on conflict(room_id) do update set round_id=excluded.round_id,enabled=excluded.enabled;
end $$;

create function private.admission_available(p_room bigint) returns boolean language sql security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from private.debate_admission_settings s join public.rooms r on r.id=s.room_id join public.rounds rd on rd.id=s.round_id where r.id=p_room and r.status='playing' and r.mode='debate' and s.enabled and rd.debate_phase<>'finished' and rd.id=(select max(id) from public.rounds where room_id=p_room) and (select count(*) from public.players where room_id=p_room and abandoned_at is null)<20)
$$;

create function private.request_admission(p_room bigint,p_player text,p_name text,p_avatar text,p_motto text) returns bigint language plpgsql security definer set search_path='' as $$
declare rd bigint;rid bigint;
begin
 if auth.uid() is null or length(trim(p_player)) not between 1 and 100 or length(trim(p_name)) not between 1 and 16 or length(p_avatar) not between 1 and 100 or length(coalesce(p_motto,''))>50 then raise exception 'Invalid profile';end if;
 select id into rd from public.rounds where room_id=p_room order by id desc limit 1;
 perform 1 from public.rounds where id=rd for update;
 perform 1 from public.rooms where id=p_room for update;
 if not private.admission_available(p_room) then raise exception 'Admissions closed';end if;
 if exists(select 1 from public.players where room_id=p_room and (user_id=auth.uid() or player_id=p_player)) then raise exception 'Already a member';end if;
 select id into rid from private.debate_admissions where round_id=rd and user_id=auth.uid() and status in('queued','open');
 if rid is not null then return rid;end if;
 insert into private.debate_admissions(round_id,user_id,player_id,name,avatar,motto) values(rd,auth.uid(),p_player,trim(p_name),p_avatar,nullif(trim(p_motto),'')) returning id into rid;
 perform private.admission_pump(rd);return rid;
end $$;

create function private.my_admission(p_id bigint,p_cancel boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare q private.debate_admissions;r public.rounds;
begin
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if q.id is null then raise exception 'Not your request';end if;
 perform 1 from public.rounds where id=q.round_id for update;
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if p_cancel then
  if q.status='accepted' and exists(select 1 from public.players where room_id=(select room_id from public.rounds where id=q.round_id) and user_id=auth.uid() and abandoned_at is null) then perform public.abandon_debate((select room_id from public.rounds where id=q.round_id),null);end if;
  update private.debate_admissions set status='cancelled',decided_at=now() where id=p_id and status in('queued','open','accepted');
 end if;
 perform private.admission_pump(q.round_id);
 select * into q from private.debate_admissions where id=p_id;
 select * into r from public.rounds where id=q.round_id;
 if q.status='accepted' and not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and player_id=q.player_id) then return jsonb_build_object('status','removed');end if;
 return jsonb_build_object('status',q.status,'room_id',r.room_id,'player_id',q.player_id,'round_id',q.round_id);
end $$;

create function private.vote_admission(p_round bigint,p_id bigint,p_choice boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rounds;
begin
 select * into r from public.rounds where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and presence='present' and abandoned_at is null) then raise exception 'Not active';end if;
 perform private.admission_pump(p_round);
 if not exists(select 1 from private.debate_admissions where id=p_id and round_id=p_round and status='open') then return jsonb_build_object('status','closed');end if;
 insert into private.debate_admission_votes(request_id,user_id,choice) values(p_id,auth.uid(),p_choice) on conflict(request_id,user_id) do nothing;
 perform private.admission_pump(p_round);return private.admission_state(p_round);
end $$;

create function private.admission_initial_vote(p_round bigint,p_choice text) returns void language plpgsql security definer set search_path='' as $$
declare r public.rounds;pid text;
begin
 select * into r from public.rounds where id=p_round for update;
 if p_choice not in('A','B') or r.status<>'debate' or private.admission_busy(p_round) or exists(select 1 from private.debate_admissions where round_id=p_round and status='open') then raise exception 'Vote unavailable';end if;
 select player_id into pid from public.players where room_id=r.room_id and user_id=auth.uid() and presence='present' and abandoned_at is null;
 if pid is null or not exists(select 1 from private.debate_admissions where round_id=p_round and user_id=auth.uid() and status='accepted') then raise exception 'Not admitted';end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) values(p_round,r.vote_cycle,pid,auth.uid(),p_choice) on conflict(round_id,cycle_number,player_id) do nothing;
end $$;

-- Direct browser inserts cannot bypass the table vote during an active debate.
create function private.guard_active_admission() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in('anon','authenticated') and exists(select 1 from public.rooms where id=new.room_id and mode='debate' and status='playing') and (tg_op='INSERT' or new.room_id is distinct from old.room_id or new.user_id is distinct from old.user_id or new.player_id is distinct from old.player_id) then raise exception 'Table approval required';end if;
 return new;
end $$;
create trigger guard_active_admission before insert or update on public.players for each row execute function private.guard_active_admission();

create function public.set_debate_admission(p_room bigint,p_enabled boolean) returns void language sql set search_path='' as $$ select private.set_admission(p_room,p_enabled) $$;
create function public.debate_admission_available(p_room bigint) returns boolean language sql set search_path='' as $$ select private.admission_available(p_room) $$;
create function public.request_debate_admission(p_room bigint,p_player text,p_name text,p_avatar text,p_motto text) returns bigint language sql set search_path='' as $$ select private.request_admission(p_room,p_player,p_name,p_avatar,p_motto) $$;
create function public.my_debate_admission(p_id bigint,p_cancel boolean default false) returns jsonb language sql set search_path='' as $$ select private.my_admission(p_id,p_cancel) $$;
create function public.vote_debate_admission(p_round bigint,p_id bigint,p_choice boolean) returns jsonb language sql set search_path='' as $$ select private.vote_admission(p_round,p_id,p_choice) $$;
create function public.debate_admission_initial_vote(p_round bigint,p_choice text) returns void language sql set search_path='' as $$ select private.admission_initial_vote(p_round,p_choice) $$;

create or replace function private.context_guard(p_round bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 perform 1 from public.rounds where id=p_round for update;
 if exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions adm join public.rounds r on r.id=adm.round_id join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where r.id=p_round and r.debate_phase='debate' and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)) then raise exception 'Another proposal must be resolved first';end if;
end $$;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admission jsonb;v_limbo jsonb;v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 v_limbo:=private.limbo_state(p_round_id);
 v_admission:=private.admission_state(p_round_id);
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
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id),'limbo_state',v_limbo,'admission_state',v_admission);
end $function$;

CREATE OR REPLACE FUNCTION public.debate_choose(p_room bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.debate_selections; r public.rooms; option_ids text[]; ranked text[]; tied text[]; winner text; selected_theme text; selected_intensity int; eligible bigint[]; candidate bigint; total int; voted int; rank_n int; rank_next int; d public.dilemmas; host_user uuid;
begin
 select * into s from public.debate_selections where room_id=p_room for update;
 select * into r from public.rooms where id=p_room;
 if s.room_id is null or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Selección cerrada';end if;
 if s.phase not in ('filters','questions','runoff') then raise exception 'Selección cerrada';end if;
 if s.phase='filters' then
  selected_intensity:=split_part(p_choice,'|',1)::int;
  selected_theme:=split_part(p_choice,'|',2);
  if selected_theme like 'ACTUALIDAD IA:%' and substring(selected_theme from 15) not in('¿A QUIÉN SALVAS?','¿LO CUENTAS?','¿TRAICIONAS?','¿TE METES?','¿QUÉ SACRIFICAS?','¿ACEPTAS EL TRATO?','ALEATORIO') then raise exception 'Categoría inválida';end if;
  if selected_intensity not in(1,2,3) or (selected_theme not like 'ACTUALIDAD IA:%' and selected_theme not in('¿A QUIÉN SALVAS?','¿LO CUENTAS?','¿TRAICIONAS?','¿TE METES?','¿QUÉ SACRIFICAS?','¿ACEPTAS EL TRATO?','ALEATORIO')) then raise exception 'Opción inválida'; end if;
  if selected_theme not like 'ACTUALIDAD IA:%' and not exists(select 1 from public.dilemmas where source_kind='catalog' and audience='teen' and active=true and intensity<=selected_intensity and (selected_theme='ALEATORIO' or debate_theme=selected_theme)) then raise exception 'No hay dilemas en esta categoría e intensidad'; end if;
 else
  if not (p_choice='__DISCARD__' and s.phase='questions' and s.theme like 'ACTUALIDAD IA:%') and not exists(select 1 from jsonb_array_elements_text(s.options) x where x=p_choice) then raise exception 'Dilema fuera de la selección'; end if;
 end if;
 insert into public.debate_selection_votes(room_id,stage,user_id,choice) values(p_room,s.stage,auth.uid(),p_choice);
 select count(*) into total from public.players where room_id=p_room and abandoned_at is null and presence='present';
 select count(*) into voted from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present';
 if voted<total then return public.debate_selection_state(p_room);end if;
 select count(*) into rank_n from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice order by count(*) desc limit 1;
 select array_agg(choice order by random()) into ranked from
 (select v.choice,count(*) as n from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice order by n desc) q;
 select array_agg(choice order by random()) into tied from
 (select v.choice from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice having count(*)=rank_n) q;
 if s.phase='runoff' then
  winner:=case when cardinality(tied)=1 then tied[1] else tied[1+floor(random()*cardinality(tied))::int] end;
 elsif cardinality(tied)=1 then winner:=tied[1];
 else
  update public.debate_selections set phase='runoff',stage=s.stage+1,options=to_jsonb(tied[1:2]),updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
 if s.phase='filters' or (s.phase='runoff' and s.theme is null) then
  selected_intensity:=split_part(winner,'|',1)::int;
  selected_theme:=split_part(winner,'|',2);
  if selected_theme like 'ACTUALIDAD IA:%' then
   update public.debate_selections set phase='news_loading',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options='[]'::jsonb,updated_at=now() where room_id=p_room;
   return public.debate_selection_state(p_room);
  end if;
  if selected_theme='ALEATORIO' then
   update public.debate_selections set phase='random',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options='[]'::jsonb,updated_at=now() where room_id=p_room;
   return public.debate_selection_state(p_room);
  end if;
  select array_agg(id order by random()) into eligible from public.dilemmas where source_kind='catalog' and audience='teen' and active=true and intensity<=selected_intensity and debate_theme=selected_theme;
  if eligible is null then raise exception 'No quedan dilemas'; end if;
  update public.debate_selections set phase='questions',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options=to_jsonb(eligible[1:least(4,cardinality(eligible))]),updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
 if winner='__DISCARD__' then
  insert into private.world_dilemma_history(scope,conflict_key)
  select 'room:'||p_room::text,private.world_key(x::bigint) from jsonb_array_elements_text(s.options) x where x<>'__DISCARD__' on conflict do nothing;
  insert into private.world_dilemma_history(scope,conflict_key)
  select 'user:'||p.user_id::text,private.world_key(x::bigint) from public.players p cross join jsonb_array_elements_text(s.options) x where p.room_id=p_room and p.abandoned_at is null and p.user_id is not null and x<>'__DISCARD__' on conflict do nothing;
  update public.debate_selections set phase='news_loading',stage=s.stage+1,options='[]'::jsonb,updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
 candidate:=winner::bigint;
 select * into d from public.dilemmas where id=candidate and active=true;
 if d.id is null then raise exception 'Dilema no disponible'; end if;
 insert into public.rounds(room_id,round_number,dilemma_id,status,started_at)
 values(p_room,coalesce((select max(round_number) from public.rounds where room_id=p_room),0)+1,candidate,'voting',now());
 update public.rooms set status='playing' where id=p_room and status='waiting';
 update public.debate_selections set phase='finished',stage=s.stage+1,options='[]'::jsonb,updated_at=now() where room_id=p_room;
 return jsonb_build_object('phase','finished');
end $function$;

revoke all on function private.world_key(bigint) from public,anon,authenticated;
revoke all on function private.world_seen(bigint,uuid,bigint) from public,anon,authenticated;
revoke all on function private.remember_world(bigint) from public,anon,authenticated;
grant execute on function private.remember_world(bigint) to authenticated;
revoke all on function public.remember_world_dilemma(bigint) from public,anon,authenticated;
grant execute on function public.remember_world_dilemma(bigint) to authenticated;
revoke all on function private.archive_world_round() from public,anon,authenticated;
revoke all on function private.fresh_world_candidates(jsonb,uuid,bigint,integer,text) from public,anon,authenticated;
grant execute on function private.fresh_world_candidates(jsonb,uuid,bigint,integer,text) to service_role;
revoke all on function public.fresh_world_candidates(jsonb,uuid,bigint,integer,text) from public,anon,authenticated;
grant execute on function public.fresh_world_candidates(jsonb,uuid,bigint,integer,text) to service_role;
revoke all on function private.admission_busy(bigint) from public,anon,authenticated;
revoke all on function private.admission_pump(bigint) from public,anon,authenticated;
revoke all on function private.admission_state(bigint) from public,anon,authenticated;
revoke all on function private.set_admission(bigint,boolean) from public,anon,authenticated;
grant execute on function private.set_admission(bigint,boolean) to authenticated;
revoke all on function private.admission_available(bigint) from public,anon,authenticated;
grant execute on function private.admission_available(bigint) to authenticated;
revoke all on function private.request_admission(bigint,text,text,text,text) from public,anon,authenticated;
grant execute on function private.request_admission(bigint,text,text,text,text) to authenticated;
revoke all on function private.my_admission(bigint,boolean) from public,anon,authenticated;
grant execute on function private.my_admission(bigint,boolean) to authenticated;
revoke all on function private.vote_admission(bigint,bigint,boolean) from public,anon,authenticated;
grant execute on function private.vote_admission(bigint,bigint,boolean) to authenticated;
revoke all on function private.admission_initial_vote(bigint,text) from public,anon,authenticated;
grant execute on function private.admission_initial_vote(bigint,text) to authenticated;
revoke all on function private.guard_active_admission() from public,anon,authenticated;
revoke all on function public.set_debate_admission(bigint,boolean) from public,anon,authenticated;
grant execute on function public.set_debate_admission(bigint,boolean) to authenticated;
revoke all on function public.debate_admission_available(bigint) from public,anon,authenticated;
grant execute on function public.debate_admission_available(bigint) to authenticated;
revoke all on function public.request_debate_admission(bigint,text,text,text,text) from public,anon,authenticated;
grant execute on function public.request_debate_admission(bigint,text,text,text,text) to authenticated;
revoke all on function public.my_debate_admission(bigint,boolean) from public,anon,authenticated;
grant execute on function public.my_debate_admission(bigint,boolean) to authenticated;
revoke all on function public.vote_debate_admission(bigint,bigint,boolean) from public,anon,authenticated;
grant execute on function public.vote_debate_admission(bigint,bigint,boolean) to authenticated;
revoke all on function public.debate_admission_initial_vote(bigint,text) from public,anon,authenticated;
grant execute on function public.debate_admission_initial_vote(bigint,text) to authenticated;

create index admission_settings_round on private.debate_admission_settings(round_id);
create index admission_votes_user on private.debate_admission_votes(user_id);
create index world_history_conflict on private.world_dilemma_history(conflict_key,scope);
