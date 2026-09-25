-- R28 · Giros para el dilema inicial y salida de respaldo si se agotan.
insert into public.dilemma_twists(id,dilemma_id,text,pressure,active) values
 (101,1,'En tu móvil hay un secreto que una amiga te contó bajo la promesa de no compartirlo. Tus padres también lo leerían.','B',true),
 (102,1,'Tus padres ya revisaron una conversación una vez, la entendieron mal y te castigaron injustamente.','B',true),
 (103,1,'Tus padres tienen indicios concretos de que te están amenazando por mensajes y temen por tu seguridad.','A',true),
 (104,1,'Una persona adulta desconocida te pide por el móvil que mantengas vuestra conversación en secreto.','A',true)
on conflict (id) do nothing;
CREATE OR REPLACE FUNCTION public.launch_debate_twist(p_round_id bigint, p_trigger text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;va bigint;vb bigint;v_pressure text;v_twist dilemma_twists%rowtype;v_id bigint;
begin
 select room_id,vote_cycle into v_room,v_cycle from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select count(*) filter(where choice='A'),count(*) filter(where choice='B') into va,vb from debate_vote_cycles d join players p on p.player_id=d.player_id and p.room_id=v_room where d.round_id=p_round_id and d.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 if p_trigger='unanimity' then
   if va>0 and vb=0 then v_pressure:='B'; elsif vb>0 and va=0 then v_pressure:='A'; else raise exception 'Vote is not unanimous'; end if;
 elsif p_trigger='requested' then
   if va>vb then v_pressure:='B'; elsif vb>va then v_pressure:='A'; else v_pressure:='LATERAL'; end if;
 else raise exception 'Invalid trigger'; end if;
 select dt.* into v_twist from dilemma_twists dt join rounds r on r.dilemma_id=dt.dilemma_id
 where r.id=p_round_id and dt.active=true and (dt.pressure=v_pressure or (v_pressure='LATERAL' and dt.pressure in('A','B','LATERAL')))
 and not exists(select 1 from debate_twists x where x.round_id=p_round_id and x.twist_id=dt.id)
 order by case when dt.pressure=v_pressure then 0 else 1 end,random() limit 1;
 if v_twist.id is null then
   insert into debate_twists(round_id,twist_id,text,pressure,source,trigger,vote_cycle)
   values(p_round_id,null,
     case mod(v_cycle,3)
       when 0 then 'Tu decisión afectará también a alguien a quien aprecias. ¿Mantienes tu postura?'
       when 1 then 'La decisión que tomes se aplicará a todos los casos similares, sin excepciones. ¿Sigues pensando lo mismo?'
       else 'La persona afectada te pide que le expliques tu elección cara a cara. ¿Qué le dirías?'
     end,
     v_pressure,'manual',p_trigger,v_cycle) returning id into v_id;
 else
   insert into debate_twists(round_id,twist_id,text,pressure,source,trigger,vote_cycle)
   values(p_round_id,v_twist.id,v_twist.text,v_twist.pressure,'manual',p_trigger,v_cycle) returning id into v_id;
 end if;
 update rounds set debate_phase='twist',twist_request_open=false where id=p_round_id;
 return v_id;
end $function$
;
