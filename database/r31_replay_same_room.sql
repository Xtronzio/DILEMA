alter table public.debate_selections add column if not exists last_round_id bigint not null default 0;
update public.debate_selections s set last_round_id=coalesce((select max(r.id) from public.rounds r where r.room_id=s.room_id and r.started_at<s.updated_at),0)
where s.last_round_id=0;

create or replace function public.debate_begin_selection(p_room bigint) returns void
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms;
begin
 select * into r from public.rooms where id=p_room for update;
 if r.id is null or r.mode<>'debate' or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede iniciar la selección'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 insert into public.debate_selections(room_id,phase,last_round_id) values(p_room,'filters',coalesce((select max(id) from public.rounds where room_id=p_room),0))
 on conflict(room_id) do update set
 phase='filters',stage=public.debate_selections.stage+1,intensity=null,theme=null,options='[]'::jsonb,last_round_id=coalesce((select max(id) from public.rounds where room_id=p_room),0),updated_at=clock_timestamp()
 where public.debate_selections.phase='finished'
 or exists(select 1 from public.rounds where room_id=p_room and id>public.debate_selections.last_round_id);
end $fn$;

create or replace function public.debate_selection_state(p_room bigint) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms; s public.debate_selections; mine text; counts jsonb; total int; voted int;
begin
 select * into r from public.rooms where id=p_room;
 if r.id is null or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'No perteneces a esta mesa'; end if;
 if r.mode<>'debate' or r.status<>'waiting' then return '{}'::jsonb; end if;
 select * into s from public.debate_selections where room_id=p_room;
 if s.room_id is null or s.phase='finished'
 or exists(select 1 from public.rounds where room_id=p_room and id>s.last_round_id)
 then return '{}'::jsonb; end if;
 select choice into mine from public.debate_selection_votes where room_id=p_room and stage=s.stage and user_id=auth.uid();
 select coalesce(jsonb_object_agg(choice,n),'{}'::jsonb) into counts
 from (select choice,count(*) n from public.debate_selection_votes where room_id=p_room and stage=s.stage group by choice) t;
 select count(*) into total from public.players where room_id=p_room and abandoned_at is null and presence='present';
 select count(*) into voted from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present';
 return jsonb_build_object('phase',s.phase,'stage',s.stage,'intensity',s.intensity,'theme',s.theme,'options',s.options,'my_vote',mine,'counts',counts,'total',total,'voted',voted,'is_host',r.host_id=(select player_id from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null limit 1));
end $fn$;

create or replace function public.debate_random_next(p_room bigint) returns bigint
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms; s public.debate_selections; d public.dilemmas; new_id bigint;
begin
 select * into r from public.rooms where id=p_room for update;
 select * into s from public.debate_selections where room_id=p_room;
 if r.status<>'waiting' or r.mode<>'debate' or s.phase<>'random' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede pedir otro dilema'; end if;
 if exists(select 1 from public.rounds where room_id=p_room and id>s.last_round_id) then raise exception 'Inicia una nueva selección desde el hall'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 select * into d from public.dilemmas where audience='teen' and active=true and intensity<=s.intensity
 and id not in(select dilemma_id from public.debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null and created_at>=s.updated_at)
 order by random() limit 1;
 if d.id is null then raise exception 'No quedan dilemas aleatorios para esta intensidad'; end if;
 insert into public.debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by)
 values(p_room,d.id,d.question,d.option_a,d.option_b,d.category,auth.uid()) returning id into new_id;
 return new_id;
end $fn$;