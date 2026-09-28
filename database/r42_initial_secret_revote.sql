-- R42: sorteo de un re-voto inicial; bloqueo de la ronda para evitar duplicados al entrar desde varios móviles.
CREATE OR REPLACE FUNCTION public.init_debate_engine(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_count bigint; v_needed bigint;
begin
  select room_id into v_room from rounds where id=p_round_id for update;
  if v_room is null then raise exception 'Round not found'; end if;
  if not exists(select 1 from players where room_id=v_room and user_id=auth.uid()) then raise exception 'Not in room'; end if;

  insert into debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
  select p_round_id,1,p.player_id,p.user_id,v.choice
  from votes v join players p on p.player_id=v.player_id and p.room_id=v_room
  where v.round_id=p_round_id
  on conflict(round_id,cycle_number,player_id) do nothing;

  update rounds set debate_phase='debate',vote_cycle=1,twist_request_open=true
  where id=p_round_id and debate_phase='initial_vote';

  if not exists(select 1 from debate_proclamations where round_id=p_round_id) then
    select count(*) into v_count from players where room_id=v_room and abandoned_at is null and presence='present';
    v_needed:=floor(v_count/2.0);
    insert into debate_proclamations(round_id,player_id,user_id)
    select p_round_id,pp.player_id,pp.user_id
    from players pp where pp.room_id=v_room and pp.abandoned_at is null and pp.presence='present'
    order by random() limit v_needed;
  end if;
  if not exists(select 1 from debate_secret_revotes where round_id=p_round_id) then
    perform public.draw_debate_secret_revote(p_round_id);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.start_debate_engine(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_host text; v_me text; v_count bigint; v_needed bigint; va bigint; vb bigint; v_twist text;
begin
 select room_id into v_room from rounds where id=p_round_id for update;
 select host_id into v_host from rooms where id=v_room;
 select player_id into v_me from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if v_me is null or v_host<>v_me then raise exception 'Host only'; end if;

 insert into debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 select p_round_id,1,p.player_id,p.user_id,v.choice
 from votes v join players p on p.player_id=v.player_id and p.room_id=v_room
 where v.round_id=p_round_id and p.abandoned_at is null
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;

 update rounds set status='debate',debate_phase='debate',vote_cycle=1,twist_request_open=true where id=p_round_id;

 if not exists(select 1 from debate_proclamations where round_id=p_round_id) then
   select count(*) into v_count from players where room_id=v_room and abandoned_at is null;
   v_needed:=floor(v_count/2.0);
   insert into debate_proclamations(round_id,proclamation_id,player_id,user_id)
   select p_round_id, prs.id, pls.player_id, pls.user_id
   from (
     select p.*,row_number() over(order by random()) rn
     from players p where p.room_id=v_room and p.abandoned_at is null
     order by random() limit v_needed
   ) pls
   join (
     select id,row_number() over(order by random()) rn
     from proclamations where active=true and audience='teen'
     order by random() limit v_needed
   ) prs using(rn);
 end if;

 if not exists(select 1 from debate_secret_revotes where round_id=p_round_id) then
   perform public.draw_debate_secret_revote(p_round_id);
 end if;

 select count(*) filter(where choice='A'),count(*) filter(where choice='B') into va,vb
 from debate_vote_cycles where round_id=p_round_id and cycle_number=1;

 if (va+vb)>1 and (va=0 or vb=0) then
   v_twist:=null;
 end if;
 return jsonb_build_object('votes_a',va,'votes_b',vb,'unanimous',((va+vb)>1 and (va=0 or vb=0)),'twist',v_twist);
end $function$
;
