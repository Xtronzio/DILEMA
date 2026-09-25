
alter table public.dilemmas add column if not exists debate_theme text;
update public.dilemmas set debate_theme =
 case
 when question ilike 'SOLO PUEDES SALVAR A UNO.%' or question ilike 'Una persona que ha cometido un crimen terrible%' then '¿A QUIÉN SALVAS?'
 when question ilike '%¿SE LO DICES?' or question ilike '%¿LE AVISAS?' or question ilike '%¿AVISAS A LA OTRA%' or question ilike '%¿DICES QUIÉN FUE?' or question ilike '%¿ROMPES LA PROMESA?' or question ilike '%¿RECONOCES QUE HAS SIDO TÚ?' then '¿LO CUENTAS?'
 when question ilike '%¿CONSIDERAS QUE TE HA TRAICIONADO?' or question ilike '%¿SIGUES OBLIGADA A GUARDAR EL SUYO?' or question ilike '%¿PUEDES PEDIRLE QUE DEJE%' or question ilike '%¿VAS?' or question ilike '%¿TENÍA QUE HABÉRTELO PREGUNTADO?' or question ilike '%¿SE LO DICES A ELLA?' then '¿TRAICIONAS?'
 when question ilike 'Cinco personas van a morir%' or question ilike '%¿QUÉ ELIGES?' then '¿QUÉ SACRIFICAS?'
 when question ilike '%¿LOS LEES?' or question ilike '%¿QUIERES SABERLA?' or question ilike '%¿LO BORRAS?' then '¿ACEPTAS EL TRATO?'
 else '¿TE METES?'
 end
 where audience='teen' and active=true and debate_theme is null;

create table if not exists public.debate_selections(
 room_id bigint primary key references public.rooms(id) on delete cascade,
 phase text not null check(phase in ('filters','questions','runoff','random','finished')),
 stage integer not null default 1,
 intensity integer,
 theme text,
 options jsonb not null default '[]'::jsonb,
 updated_at timestamptz not null default now()
);
create table if not exists public.debate_selection_votes(
 room_id bigint not null references public.debate_selections(room_id) on delete cascade,
 stage integer not null,
 user_id uuid not null,
 choice text not null,
 primary key(room_id,stage,user_id)
);
create index if not exists debate_selection_votes_stage_idx on public.debate_selection_votes(room_id,stage);
alter table public.debate_selections enable row level security;
alter table public.debate_selection_votes enable row level security;
revoke all on public.debate_selections,public.debate_selection_votes from anon,authenticated;

create or replace function public.debate_selection_state(p_room bigint) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms; s public.debate_selections; mine text; counts jsonb; total int; voted int;
begin
 select * into r from public.rooms where id=p_room;
 if r.id is null or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'No perteneces a esta mesa'; end if;
 if r.mode<>'debate' or r.status<>'waiting' then return '{}'::jsonb; end if;
 select * into s from public.debate_selections where room_id=p_room;
 if s.room_id is null then return '{}'::jsonb; end if;
 select choice into mine from public.debate_selection_votes where room_id=p_room and stage=s.stage and user_id=auth.uid();
 select coalesce(jsonb_object_agg(choice,n),'{}'::jsonb) into counts
 from (select choice,count(*) n from public.debate_selection_votes where room_id=p_room and stage=s.stage group by choice) t;
 select count(*) into total from public.players where room_id=p_room and abandoned_at is null and presence='present';
 select count(*) into voted from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present';
 return jsonb_build_object('phase',s.phase,'stage',s.stage,'intensity',s.intensity,'theme',s.theme,'options',s.options,'my_vote',mine,'counts',counts,'total',total,'voted',voted,'is_host',r.host_id=(select player_id from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null limit 1));
end $fn$;
create or replace function public.debate_begin_selection(p_room bigint) returns void
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms;
begin
 select * into r from public.rooms where id=p_room for update;
 if r.id is null or r.mode<>'debate' or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede iniciar la selección'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 insert into public.debate_selections(room_id,phase) values(p_room,'filters')
 on conflict(room_id) do nothing;
end $fn$;
create or replace function public.debate_random_next(p_room bigint) returns bigint
language plpgsql security definer set search_path=public as $fn$
declare r public.rooms; s public.debate_selections; d public.dilemmas; new_id bigint; host_user uuid;
begin
 select * into r from public.rooms where id=p_room for update;
 select * into s from public.debate_selections where room_id=p_room;
 if r.status<>'waiting' or r.mode<>'debate' or s.phase<>'random' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede pedir otro dilema'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 select * into d from public.dilemmas where audience='teen' and active=true and intensity<=s.intensity
 and id not in(select dilemma_id from public.debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null)
 order by random() limit 1;
 if d.id is null then raise exception 'No quedan dilemas aleatorios para esta intensidad'; end if;
 insert into public.debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by)
 values(p_room,d.id,d.question,d.option_a,d.option_b,d.category,auth.uid()) returning id into new_id;
 return new_id;
end $fn$;
create or replace function public.debate_choose(p_room bigint,p_choice text) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare s public.debate_selections; r public.rooms; option_ids text[]; ranked text[]; tied text[]; winner text; selected_theme text; selected_intensity int; eligible bigint[]; candidate bigint; total int; voted int; rank_n int; rank_next int; d public.dilemmas; host_user uuid;
begin
 select * into s from public.debate_selections where room_id=p_room for update;
 select * into r from public.rooms where id=p_room;
 if s.room_id is null or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Selección cerrada';end if;
 if s.phase not in ('filters','questions','runoff') then raise exception 'Selección cerrada';end if;
 if s.phase='filters' then
  selected_intensity:=split_part(p_choice,'|',1)::int;
  selected_theme:=split_part(p_choice,'|',2);
  if selected_intensity not in(1,2,3) or selected_theme not in('¿A QUIÉN SALVAS?','¿LO CUENTAS?','¿TRAICIONAS?','¿TE METES?','¿QUÉ SACRIFICAS?','¿ACEPTAS EL TRATO?','ALEATORIO') then raise exception 'Opción inválida'; end if;
  if not exists(select 1 from public.dilemmas where audience='teen' and active=true and intensity<=selected_intensity and (selected_theme='ALEATORIO' or debate_theme=selected_theme)) then raise exception 'No hay dilemas en esta categoría e intensidad'; end if;
 else
  if not exists(select 1 from jsonb_array_elements_text(s.options) x where x=p_choice) then raise exception 'Dilema fuera de la selección'; end if;
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
  if selected_theme='ALEATORIO' then
   update public.debate_selections set phase='random',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options='[]'::jsonb,updated_at=now() where room_id=p_room;
   return public.debate_selection_state(p_room);
  end if;
  select array_agg(id order by random()) into eligible from public.dilemmas where audience='teen' and active=true and intensity<=selected_intensity and debate_theme=selected_theme;
  if eligible is null then raise exception 'No quedan dilemas'; end if;
  update public.debate_selections set phase='questions',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options=to_jsonb(eligible[1:least(4,cardinality(eligible))]),updated_at=now() where room_id=p_room;
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
end $fn$;
revoke all on function public.debate_selection_state(bigint),public.debate_begin_selection(bigint),public.debate_random_next(bigint),public.debate_choose(bigint,text) from public,anon,authenticated;
grant execute on function public.debate_selection_state(bigint),public.debate_begin_selection(bigint),public.debate_random_next(bigint),public.debate_choose(bigint,text) to authenticated;
