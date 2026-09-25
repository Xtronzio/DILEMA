-- R23 · Una proclama dirigida a cualquier selección de integrantes de la mesa.
-- Los destinatarios aparecen en el aviso visible para toda la mesa.

create or replace function public.publish_debate_proclamation_to_players(p_round_id bigint,p_text text,p_recipients text[])
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v_room bigint;v_phase text;v_paused boolean;v_me text;v_sender text;
 v_text text;v_dp bigint;v_count integer;v_names text;v_event text;v_total integer;
begin
 v_text:=nullif(trim(regexp_replace(coalesce(p_text,''),'[\r\n\t]+',' ','g')),'');
 if v_text is null or length(v_text)>180 then raise exception 'Proclamation must be between 1 and 180 characters'; end if;
 if p_recipients is null or coalesce(array_length(p_recipients,1),0)=0
    or array_position(p_recipients,null) is not null
    or (select count(distinct id) from unnest(p_recipients) as id)<>array_length(p_recipients,1)
 then raise exception 'Select at least one unique recipient'; end if;
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Proclamation unavailable'; end if;
 select player_id,name into v_me,v_sender from public.players
  where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
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
 insert into public.debate_events(id,round_id,event_type,text)
 values ((extract(epoch from clock_timestamp())*1000000)::bigint,p_round_id,'proclamation',v_event);
 return v_event;
end $function$;
revoke all on function public.publish_debate_proclamation_to_players(bigint,text,text[]) from public,anon;
grant execute on function public.publish_debate_proclamation_to_players(bigint,text,text[]) to authenticated;
