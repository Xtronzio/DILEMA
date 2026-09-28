-- FIN DEBATE requiere unanimidad también en la decisión tras voto A/B unánime.
-- Si la mesa completa la votación sin mayoría para seguir o girar y sin unanimidad para cerrar, continúa el debate.
CREATE OR REPLACE FUNCTION public.cast_debate_unanimity_choice(p_round_id bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_player text;v_players bigint;va bigint;vb bigint;v_id bigint;v_outcome text;v_continue bigint;v_giro bigint;v_finish bigint;v_need bigint;
begin
 if p_choice not in ('CONTINUE','GIRO','FINISH') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' then raise exception 'No active debate'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where d.choice='A'),count(*) filter(where d.choice='B') into va,vb
 from public.debate_vote_cycles d join public.players p on p.room_id=v_room and p.player_id=d.player_id
 where d.round_id=p_round_id and d.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 if v_players<2 or not ((va=v_players and vb=0) or (vb=v_players and va=0)) then raise exception 'The vote is not unanimous'; end if;
 insert into public.debate_unanimity_decisions(round_id,vote_cycle) values(p_round_id,v_cycle)
 on conflict(round_id,vote_cycle) do nothing;
 select id,outcome into v_id,v_outcome from public.debate_unanimity_decisions where round_id=p_round_id and vote_cycle=v_cycle;
 if v_outcome is not null then raise exception 'Already decided'; end if;
 insert into public.debate_unanimity_votes(decision_id,player_id,user_id,choice)
 values(v_id,v_player,(select auth.uid()),p_choice)
 on conflict(decision_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) filter(where v.choice='CONTINUE'),count(*) filter(where v.choice='GIRO'),count(*) filter(where v.choice='FINISH')
 into v_continue,v_giro,v_finish from public.debate_unanimity_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.decision_id=v_id and p.abandoned_at is null and p.presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 if v_continue>=v_need then v_outcome:='CONTINUE';
 elsif v_giro>=v_need then
   perform public.launch_debate_twist(p_round_id,'unanimity');
   v_outcome:='GIRO';
 elsif v_finish=v_players then
   update public.rounds set debate_phase='finished',status='finished',twist_request_open=false where id=p_round_id;
   v_outcome:='FINISH';
 elsif v_continue+v_giro+v_finish=v_players then
   v_outcome:='CONTINUE';
 end if;
 if v_outcome is not null then update public.debate_unanimity_decisions set outcome=v_outcome where id=v_id; end if;
 return jsonb_build_object('outcome',v_outcome,'voted',v_continue+v_giro+v_finish,'players',v_players);
end $function$
;
