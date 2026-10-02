-- R91: automatic random proposal, replacement and accepted dilemma launch.

CREATE OR REPLACE FUNCTION private.random_dilemma(p_room bigint) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE r public.rooms%rowtype;s public.debate_selections%rowtype;d public.dilemmas%rowtype;pid bigint;
BEGIN
 SELECT * INTO r FROM public.rooms WHERE id=p_room FOR UPDATE;
 IF auth.uid() IS NULL OR r.id IS NULL OR r.mode<>'debate' OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=p_room AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Not in room';END IF;
 IF r.status<>'waiting' THEN RETURN NULL;END IF;
 SELECT * INTO s FROM public.debate_selections WHERE room_id=p_room;
 IF s.room_id IS NULL OR s.phase<>'random' OR EXISTS(SELECT 1 FROM public.rounds WHERE room_id=p_room AND id>s.last_round_id) THEN RETURN NULL;END IF;
 SELECT id INTO pid FROM public.debate_dilemma_proposals WHERE room_id=p_room AND status IN ('open','accepted') ORDER BY id DESC LIMIT 1;
 IF pid IS NOT NULL THEN RETURN pid;END IF;
 SELECT * INTO d FROM public.dilemmas dm WHERE dm.source_kind='catalog' AND dm.audience='teen' AND dm.active AND dm.intensity<=s.intensity
 ORDER BY EXISTS(SELECT 1 FROM public.debate_dilemma_proposals pr WHERE pr.room_id=p_room AND pr.dilemma_id=dm.id AND pr.status='rejected' AND pr.created_at>=s.updated_at),
 (SELECT max(pr.created_at) FROM public.debate_dilemma_proposals pr WHERE pr.room_id=p_room AND pr.dilemma_id=dm.id AND pr.created_at>=s.updated_at) NULLS FIRST,random() LIMIT 1;
 IF d.id IS NULL THEN RAISE EXCEPTION 'No active catalog dilemmas';END IF;
 INSERT INTO public.debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by)
 VALUES(p_room,d.id,d.question,d.option_a,d.option_b,d.category,auth.uid()) RETURNING id INTO pid;
 RETURN pid;
END $fn$;

CREATE OR REPLACE FUNCTION private.launch_approved_dilemma(p_id bigint) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE p public.debate_dilemma_proposals%rowtype;r public.rooms%rowtype;did bigint;rid bigint;room bigint;
BEGIN
 SELECT room_id INTO room FROM public.debate_dilemma_proposals WHERE id=p_id;
 SELECT * INTO r FROM public.rooms WHERE id=room FOR UPDATE;
 IF auth.uid() IS NULL OR r.id IS NULL OR r.mode<>'debate' OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.id AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Not in room';END IF;
 SELECT * INTO p FROM public.debate_dilemma_proposals WHERE id=p_id FOR UPDATE;
 IF p.status='launched' THEN RETURN r.active_round_id;END IF;
 IF p.status<>'accepted' OR r.status<>'waiting' THEN RAISE EXCEPTION 'Dilemma not approved';END IF;
 did:=p.dilemma_id;
 IF did IS NULL THEN
  INSERT INTO public.dilemmas(audience,category,intensity,question,option_a,option_b,active) VALUES('custom','PERSONALIZADO',1,p.question,p.option_a,p.option_b,true) RETURNING id INTO did;
 END IF;
 INSERT INTO public.rounds(room_id,round_number,dilemma_id,status,started_at,context)
 VALUES(r.id,coalesce((SELECT max(round_number) FROM public.rounds WHERE room_id=r.id),0)+1,did,'voting',now(),p.context) RETURNING id INTO rid;
 UPDATE public.rooms SET status='playing' WHERE id=r.id;
 UPDATE public.debate_dilemma_proposals SET status='launched' WHERE id=p_id;
 UPDATE public.debate_selections SET phase='finished' WHERE room_id=r.id;
 RETURN rid;
END $fn$;

REVOKE ALL ON FUNCTION private.random_dilemma(bigint),private.launch_approved_dilemma(bigint) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.debate_choose(p_room bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.debate_selections; r public.rooms; option_ids text[]; ranked text[]; tied text[]; winner text; selected_theme text; selected_intensity int; eligible bigint[]; candidate bigint; total int; voted int; rank_n int; rank_next int; d public.dilemmas; host_user uuid;
begin
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'The table must resolve the session proposal first';end if;
 select * into r from public.rooms where id=p_room for update;
 select * into s from public.debate_selections where room_id=p_room for update;
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
   perform private.random_dilemma(p_room);
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

CREATE OR REPLACE FUNCTION public.debate_vote_proposal(p_id bigint, p_yes boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.debate_dilemma_proposals; r public.rooms;
begin
 if p_yes is null then raise exception 'Invalid choice';end if;
 perform 1 from public.rooms where id=(select room_id from public.debate_dilemma_proposals where id=p_id) for update;
 select * into p from debate_dilemma_proposals where id=p_id for update;
 select * into r from rooms where id=p.room_id;
 if p.id is null or p.status <> 'open' or r.status <> 'waiting' or auth.uid() is null or not exists(select 1 from players where room_id=p.room_id and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Votación cerrada'; end if;
 insert into debate_dilemma_proposal_votes(proposal_id,user_id,choice) values(p_id,auth.uid(),p_yes);
 perform debate_recount_proposal(p_id);
end $function$;

CREATE OR REPLACE FUNCTION public.debate_recount_proposal(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.debate_dilemma_proposals; total integer; yes_count integer; votes_count integer;
begin
 perform 1 from public.rooms where id=(select room_id from public.debate_dilemma_proposals where id=p_id) for update;
 select * into p from debate_dilemma_proposals where id=p_id for update;
 if p.status <> 'open' or not exists(select 1 from public.rooms where id=p.room_id and status='waiting') then return; end if;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=p.room_id and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not in room';end if;
 select count(*) into total from players where room_id=p.room_id and abandoned_at is null and presence='present';
 select count(*) filter(where v.choice), count(*) into yes_count,votes_count from debate_dilemma_proposal_votes v join players pl on pl.user_id=v.user_id and pl.room_id=p.room_id where v.proposal_id=p_id and pl.abandoned_at is null and pl.presence='present';
 if total>0 and yes_count > total/2 then update debate_dilemma_proposals set status='accepted' where id=p_id;
 perform private.launch_approved_dilemma(p_id);
 elsif total>0 and votes_count>=total then update debate_dilemma_proposals set status='rejected' where id=p_id;
 perform private.random_dilemma(p.room_id);
 end if;
end $function$;

CREATE OR REPLACE FUNCTION public.debate_start_approved(p_id bigint) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE room bigint;
BEGIN
 SELECT room_id INTO room FROM public.debate_dilemma_proposals WHERE id=p_id;
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.rooms r JOIN public.players p ON p.room_id=r.id AND p.player_id=r.host_id WHERE r.id=room AND p.user_id=auth.uid() AND p.abandoned_at IS NULL AND p.presence='present') THEN RAISE EXCEPTION 'Host only';END IF;
 RETURN private.launch_approved_dilemma(p_id);
END $fn$;

CREATE OR REPLACE FUNCTION public.debate_random_next(p_room bigint) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.rooms r JOIN public.players p ON p.room_id=r.id AND p.player_id=r.host_id WHERE r.id=p_room AND p.user_id=auth.uid() AND p.abandoned_at IS NULL AND p.presence='present') THEN RAISE EXCEPTION 'Host only';END IF;
 RETURN private.random_dilemma(p_room);
END $fn$;

CREATE OR REPLACE FUNCTION public.debate_proposal_state(p_room bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.debate_dilemma_proposals; r public.rooms; yes_count integer; no_count integer; total integer; mine boolean;
begin
 select * into r from rooms where id=p_room;
 if r.id is null or auth.uid() is null or not exists(select 1 from players where room_id=p_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'No perteneces a esta mesa'; end if;
 if r.mode <> 'debate' or r.status <> 'waiting' then return '{}'::jsonb; end if;
 select * into p from debate_dilemma_proposals where room_id=p_room and status in ('open','accepted') order by id desc limit 1;
 if p.id is null and exists(select 1 from public.debate_selections where room_id=p_room and phase='random') and exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then
  perform private.random_dilemma(p_room);
  select * into p from debate_dilemma_proposals where room_id=p_room and status in ('open','accepted') order by id desc limit 1;
 end if;
 if p.status='accepted' and exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then perform private.launch_approved_dilemma(p.id);return '{}'::jsonb;end if;
 if p.id is null then return jsonb_build_object('rejected_ids',coalesce((select jsonb_agg(dilemma_id) from debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null),'[]'::jsonb)); end if;
 select count(*) filter(where choice),count(*) filter(where not choice) into yes_count,no_count from debate_dilemma_proposal_votes where proposal_id=p.id;
 select count(*) into total from players where room_id=p_room and abandoned_at is null and presence='present';
 select choice into mine from debate_dilemma_proposal_votes where proposal_id=p.id and user_id=auth.uid();
 return jsonb_build_object('id',p.id,'status',p.status,'dilemma_id',p.dilemma_id,'question',p.question,'option_a',p.option_a,'option_b',p.option_b,'category',p.category,'context',p.context,'yes',yes_count,'no',no_count,'total',total,'my_vote',mine,'has_voted',exists(select 1 from debate_dilemma_proposal_votes where proposal_id=p.id and user_id=auth.uid()),'rejected_ids',coalesce((select jsonb_agg(dilemma_id) from debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.debate_propose_with_context(p_room bigint,p_question text,p_a text,p_b text,p_context text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE r public.rooms%rowtype;pid bigint;
BEGIN
 SELECT * INTO r FROM public.rooms WHERE id=p_room FOR UPDATE;
 IF auth.uid() IS NULL OR r.id IS NULL OR r.mode<>'debate' OR r.status<>'waiting' OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=p_room AND player_id=r.host_id AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Solo el anfitrión puede proponer';END IF;
 IF EXISTS(SELECT 1 FROM private.debate_session_proposals WHERE room_id=p_room AND status='open') THEN RAISE EXCEPTION 'The table must resolve the session proposal first';END IF;
 IF EXISTS(SELECT 1 FROM public.debate_dilemma_proposals WHERE room_id=p_room AND status IN('open','accepted')) THEN RAISE EXCEPTION 'Ya hay un dilema propuesto';END IF;
 IF length(trim(coalesce(p_question,''))) NOT BETWEEN 1 AND 1000 OR length(trim(coalesce(p_a,''))) NOT BETWEEN 1 AND 500 OR length(trim(coalesce(p_b,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Completa la pregunta y ambas opciones';END IF;
 IF length(coalesce(p_context,''))>3000 THEN RAISE EXCEPTION 'Context too long';END IF;
 INSERT INTO public.debate_dilemma_proposals(room_id,question,option_a,option_b,category,proposed_by,context) VALUES(p_room,trim(p_question),trim(p_a),trim(p_b),'PERSONALIZADO',auth.uid(),trim(coalesce(p_context,''))) RETURNING id INTO pid;
 INSERT INTO public.debate_dilemma_proposal_votes(proposal_id,user_id,choice) VALUES(pid,auth.uid(),true);
 PERFORM public.debate_recount_proposal(pid);
 RETURN pid;
END $fn$;

NOTIFY pgrst, 'reload schema';
