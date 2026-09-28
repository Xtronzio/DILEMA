alter table public.debate_private_proclamations
  add column if not exists reply_enabled boolean not null default false;
alter table public.debate_private_proclamation_recipients
  add column if not exists reply_text text,
  add column if not exists replied_at timestamptz;

create or replace function public.publish_debate_proclamation_to_players(p_round_id bigint, p_text text, p_recipients text[])
returns text language plpgsql security definer set search_path to ''
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
 if v_me=any(p_recipients) then raise exception 'You cannot address a proclamation to yourself'; end if;
 select count(*),string_agg(name,', ' order by created_at,player_id)
 into v_count,v_names from public.players
 where room_id=v_room and abandoned_at is null and presence='present'
 and player_id=any(p_recipients);
 if v_count<>array_length(p_recipients,1) then raise exception 'A recipient is no longer at the table'; end if;
 select count(*) into v_total from public.players
  where room_id=v_room and abandoned_at is null and presence='present' and player_id<>v_me;
 select id into v_dp from public.debate_proclamations
  where round_id=p_round_id and player_id=v_me and used_at is null order by id limit 1 for update;
 if v_dp is null then raise exception 'No proclamation available'; end if;
 update public.debate_proclamations set used_at=now() where id=v_dp;
 v_event:=case when v_count=v_total then 'ANÓNIMO: '||v_text
   else coalesce(v_sender,'JUGADOR')||': '||v_text end;
 v_event_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
 insert into public.debate_private_proclamations(id,round_id,sender_user_id,text,reply_enabled)
 values (v_event_id,p_round_id,v_user,v_event,v_count<v_total);
 insert into public.debate_private_proclamation_recipients(proclamation_id,player_id,user_id)
 select v_event_id,p.player_id,p.user_id from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
 and p.player_id=any(p_recipients);
 return v_event;
end $function$;

create or replace function public.get_my_proclamation_to_reply(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_room bigint;v_phase text;v_paused boolean;v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select room_id,debate_phase,paused into v_room,v_phase,v_paused
 from public.rounds where id=p_round_id;
 if v_room is null or v_phase<>'debate' or v_paused then return null; end if;
 if not exists(select 1 from public.players
  where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present')
 then return null; end if;
 select jsonb_build_object('id',p.id,'text',p.text)
 into v_result from public.debate_private_proclamations p
 join public.debate_private_proclamation_recipients r on r.proclamation_id=p.id
 where p.round_id=p_round_id and p.reply_enabled and p.sender_user_id<>auth.uid()
 and r.user_id=auth.uid() and r.replied_at is null
 order by p.id desc limit 1;
 return v_result;
end $function$;

alter table public.debate_private_proclamations add column if not exists reply_to_id bigint references public.debate_private_proclamations(id);
create index if not exists debate_private_proclamations_reply_to_idx on public.debate_private_proclamations(reply_to_id) where reply_to_id is not null;

CREATE OR REPLACE FUNCTION public.reply_to_debate_proclamation(p_proclamation_id bigint, p_text text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_round bigint;v_room bigint;v_phase text;v_paused boolean;v_sender uuid;v_reply_enabled boolean;v_sender_player text;v_me text;v_name text;v_reply text;v_event_id bigint; begin if auth.uid() is null then raise exception 'Authentication required'; end if; v_reply:=nullif(btrim(translate(coalesce(p_text,''),chr(10)||chr(13)||chr(9),'   ')),''); if v_reply is null or length(v_reply)>180 then raise exception 'Reply must be between 1 and 180 characters'; end if; select p.round_id into v_round from public.debate_private_proclamations p where p.id=p_proclamation_id; if v_round is null then raise exception 'Proclamation unavailable'; end if; select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=v_round for update; if v_phase<>'debate' or v_paused then raise exception 'Reply unavailable'; end if; select p.sender_user_id,p.reply_enabled into v_sender,v_reply_enabled from public.debate_private_proclamations p where p.id=p_proclamation_id and p.round_id=v_round; if not v_reply_enabled or v_sender=auth.uid() then raise exception 'Reply unavailable'; end if; select player_id,name into v_me,v_name from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1; if v_me is null then raise exception 'Not active'; end if; select player_id into v_sender_player from public.players where room_id=v_room and user_id=v_sender limit 1; if v_sender_player is null then raise exception 'Sender unavailable'; end if; update public.debate_private_proclamation_recipients r set reply_text=v_reply,replied_at=now() where r.proclamation_id=p_proclamation_id and r.user_id=auth.uid() and r.replied_at is null; if not found then raise exception 'Already replied or not a recipient'; end if; v_event_id:=(extract(epoch from clock_timestamp())*1000000)::bigint; insert into public.debate_private_proclamations(id,round_id,sender_user_id,text,reply_enabled,reply_to_id) values(v_event_id,v_round,auth.uid(),coalesce(v_name,'JUGADOR')||' RESPONDE: '||v_reply,false,p_proclamation_id); insert into public.debate_private_proclamation_recipients(proclamation_id,player_id,user_id) values(v_event_id,v_sender_player,v_sender); return 'RESPUESTA ENVIADA'; end $function$
;
revoke all on function public.get_my_proclamation_to_reply(bigint) from public,anon,authenticated;
revoke all on function public.reply_to_debate_proclamation(bigint,text) from public,anon,authenticated;
grant execute on function public.get_my_proclamation_to_reply(bigint) to authenticated;
grant execute on function public.reply_to_debate_proclamation(bigint,text) to authenticated;
