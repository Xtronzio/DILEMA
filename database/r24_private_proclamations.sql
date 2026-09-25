-- R24 · Proclamas privadas: solo las personas elegidas y el emisor pueden leerlas.
create table if not exists public.debate_private_proclamations (
 id bigint primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 sender_user_id uuid not null,
 text text not null,
 created_at timestamptz not null default now()
);
create table if not exists public.debate_private_proclamation_recipients (
 proclamation_id bigint not null references public.debate_private_proclamations(id) on delete cascade,
 player_id text not null,
 user_id uuid not null,
 primary key (proclamation_id,player_id)
);
create index if not exists debate_private_proclamations_round_latest
 on public.debate_private_proclamations(round_id,id desc);
create index if not exists debate_private_proclamation_recipients_user
 on public.debate_private_proclamation_recipients(user_id,proclamation_id);
alter table public.debate_private_proclamations enable row level security;
alter table public.debate_private_proclamation_recipients enable row level security;
revoke all on public.debate_private_proclamations from public,anon,authenticated;
revoke all on public.debate_private_proclamation_recipients from public,anon,authenticated;
grant select on public.debate_private_proclamations to authenticated;
grant select on public.debate_private_proclamation_recipients to authenticated;
create policy "Read own proclamation recipient" on public.debate_private_proclamation_recipients
 for select to authenticated using ((select auth.uid())=user_id);
create policy "Read sent or received proclamation" on public.debate_private_proclamations
 for select to authenticated using (
   (select auth.uid())=sender_user_id
   or exists (
     select 1 from public.debate_private_proclamation_recipients pr
     where pr.proclamation_id=id and pr.user_id=(select auth.uid())
   )
 );

create or replace function public.publish_debate_proclamation_to_players(p_round_id bigint,p_text text,p_recipients text[])
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v_room bigint;v_phase text;v_paused boolean;v_me text;v_sender text;v_user uuid;
 v_text text;v_dp bigint;v_count integer;v_names text;v_event text;v_total integer;v_event_id bigint;
begin
 v_text:=nullif(trim(regexp_replace(coalesce(p_text,''),'[\r\n\t]+',' ','g')),'');
 if v_text is null or length(v_text)>180 then raise exception 'Proclamation must be between 1 and 180 characters'; end if;
 if p_recipients is null or coalesce(array_length(p_recipients,1),0)=0
    or array_position(p_recipients,null) is not null
    or (select count(distinct id) from unnest(p_recipients) as id)<>array_length(p_recipients,1)
 then raise exception 'Select at least one unique recipient'; end if;
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Proclamation unavailable'; end if;
 v_user:=auth.uid();
 select player_id,name into v_me,v_sender from public.players
  where room_id=v_room and user_id=v_user and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Not active'; end if;
 select count(*),string_agg(name,', ' order by created_at,player_id)
 into v_count,v_names from public.players
 where room_id=v_room and abandoned_at is null and presence='present'
 and player_id=any(p_recipients);
 if v_count<>array_length(p_recipients,1) then raise exception 'A recipient is no longer at the table'; end if;
 select count(*) into v_total from public.players
  where room_id=v_room and abandoned_at is null and presence='present';
 select id into v_dp from public.debate_proclamations
  where round_id=p_round_id and player_id=v_me and used_at is null order by id limit 1 for update;
 if v_dp is null then raise exception 'No proclamation available'; end if;
 update public.debate_proclamations set used_at=now() where id=v_dp;
 v_event:='PROCLAMA DE '||coalesce(v_sender,'JUGADOR')||' PARA '||
   case when v_count=v_total then 'LA MESA' else v_names end||' · '||v_text;
 v_event_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
 insert into public.debate_private_proclamations(id,round_id,sender_user_id,text)
 values (v_event_id,p_round_id,v_user,v_event);
 insert into public.debate_private_proclamation_recipients(proclamation_id,player_id,user_id)
 select v_event_id,p.player_id,p.user_id from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
 and p.player_id=any(p_recipients);
 return v_event;
end $function$;
revoke all on function public.publish_debate_proclamation_to_players(bigint,text,text[]) from public,anon;
grant execute on function public.publish_debate_proclamation_to_players(bigint,text,text[]) to authenticated;

-- Clientes anteriores: enviar a todos o a una persona también respeta los destinatarios.
create or replace function public.publish_debate_proclamation(p_round_id bigint,p_text text,p_scope text,p_target_player_id text default null)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare v_room bigint;v_ids text[];
begin
 if p_scope not in ('GRUPAL','DIRIGIDA') then raise exception 'Invalid proclamation audience'; end if;
 select room_id into v_room from public.rounds where id=p_round_id;
 if p_scope='GRUPAL' then
   if p_target_player_id is not null then raise exception 'Group proclamation cannot have a target'; end if;
   select array_agg(player_id order by created_at,player_id) into v_ids
   from public.players where room_id=v_room and abandoned_at is null and presence='present';
 else
   v_ids:=array[p_target_player_id];
 end if;
 return public.publish_debate_proclamation_to_players(p_round_id,p_text,v_ids);
end $function$;

create or replace function public.use_debate_proclamation(p_round_id bigint)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare v_text text;
begin
 select p.text into v_text from public.debate_proclamations dp
 join public.proclamations p on p.id=dp.proclamation_id
 where dp.round_id=p_round_id and dp.user_id=auth.uid() and dp.used_at is null limit 1;
 if v_text is null then raise exception 'No proclamation available'; end if;
 return public.use_debate_proclamation_text(p_round_id,v_text);
end $function$;
