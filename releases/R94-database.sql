-- R94: accept/discard use the same strict majority; two tied ballots then a draw.
ALTER TABLE public.debate_dilemma_proposals ADD COLUMN vote_cycle integer NOT NULL DEFAULT 1 CHECK(vote_cycle IN(1,2));
ALTER TABLE public.debate_dilemma_proposals ADD COLUMN resolved_by text CHECK(resolved_by IN('majority','draw'));
ALTER TABLE public.debate_dilemma_proposal_votes ADD COLUMN vote_cycle integer NOT NULL DEFAULT 1 CHECK(vote_cycle IN(1,2));
ALTER TABLE public.debate_dilemma_proposal_votes DROP CONSTRAINT debate_dilemma_proposal_votes_pkey;
ALTER TABLE public.debate_dilemma_proposal_votes ADD PRIMARY KEY(proposal_id,user_id,vote_cycle);

CREATE OR REPLACE FUNCTION public.debate_recount_proposal(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE p public.debate_dilemma_proposals%rowtype;total integer;yes_count integer;no_count integer;accept boolean;decision text;
BEGIN
 PERFORM 1 FROM public.rooms WHERE id=(SELECT room_id FROM public.debate_dilemma_proposals WHERE id=p_id) FOR UPDATE;
 SELECT * INTO p FROM public.debate_dilemma_proposals WHERE id=p_id FOR UPDATE;
 IF p.id IS NULL OR p.status<>'open' OR NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=p.room_id AND status='waiting') THEN RETURN;END IF;
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=p.room_id AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Not in room';END IF;
 SELECT count(*) INTO total FROM public.players WHERE room_id=p.room_id AND abandoned_at IS NULL AND presence='present';
 SELECT count(*) FILTER(WHERE v.choice),count(*) FILTER(WHERE NOT v.choice) INTO yes_count,no_count
 FROM public.debate_dilemma_proposal_votes v WHERE v.proposal_id=p_id AND v.vote_cycle=p.vote_cycle
 AND EXISTS(SELECT 1 FROM public.players pl WHERE pl.room_id=p.room_id AND pl.user_id=v.user_id AND pl.abandoned_at IS NULL AND pl.presence='present');
 IF total<=0 THEN RETURN;END IF;
 IF yes_count>total/2 THEN accept:=true;decision:='majority';
 ELSIF no_count>total/2 THEN accept:=false;decision:='majority';
 ELSIF yes_count+no_count>=total AND yes_count=no_count THEN
  IF p.vote_cycle=1 THEN UPDATE public.debate_dilemma_proposals SET vote_cycle=2 WHERE id=p_id;RETURN;
  ELSE accept:=random()<0.5;decision:='draw';END IF;
 ELSE RETURN;
 END IF;
 UPDATE public.debate_dilemma_proposals SET status=CASE WHEN accept THEN 'accepted' ELSE 'rejected' END,resolved_by=decision WHERE id=p_id;
 IF accept THEN PERFORM private.launch_approved_dilemma(p_id);
 ELSE PERFORM private.random_dilemma(p.room_id);END IF;
END $fn$;

CREATE OR REPLACE FUNCTION private.cast_dilemma_proposal_vote(p_id bigint,p_yes boolean,p_cycle integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE p public.debate_dilemma_proposals%rowtype;r public.rooms%rowtype;
BEGIN
 IF p_yes IS NULL THEN RAISE EXCEPTION 'Invalid choice';END IF;
 PERFORM 1 FROM public.rooms WHERE id=(SELECT room_id FROM public.debate_dilemma_proposals WHERE id=p_id) FOR UPDATE;
 SELECT * INTO p FROM public.debate_dilemma_proposals WHERE id=p_id FOR UPDATE;
 SELECT * INTO r FROM public.rooms WHERE id=p.room_id;
 IF p.id IS NULL OR p.status<>'open' OR r.status<>'waiting' OR r.mode<>'debate' OR auth.uid() IS NULL
 OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=p.room_id AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Votación cerrada';END IF;
 IF p_cycle IS NOT NULL AND p_cycle<>p.vote_cycle THEN RAISE EXCEPTION 'La votación anterior ha empatado. Vota de nuevo.';END IF;
 IF EXISTS(SELECT 1 FROM public.debate_dilemma_proposal_votes WHERE proposal_id=p_id AND user_id=auth.uid() AND vote_cycle=p.vote_cycle) THEN RAISE EXCEPTION 'Tu voto ya está registrado';END IF;
 INSERT INTO public.debate_dilemma_proposal_votes(proposal_id,user_id,choice,vote_cycle) VALUES(p_id,auth.uid(),p_yes,p.vote_cycle);
 PERFORM public.debate_recount_proposal(p_id);
END $fn$;
REVOKE ALL ON FUNCTION private.cast_dilemma_proposal_vote(bigint,boolean,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.cast_dilemma_proposal_vote(bigint,boolean,integer) TO authenticated;
CREATE OR REPLACE FUNCTION public.debate_vote_proposal_cycle(p_id bigint,p_yes boolean,p_cycle integer) RETURNS void
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $fn$ SELECT private.cast_dilemma_proposal_vote(p_id,p_yes,p_cycle) $fn$;
REVOKE ALL ON FUNCTION public.debate_vote_proposal_cycle(bigint,boolean,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.debate_vote_proposal_cycle(bigint,boolean,integer) TO authenticated;
-- Old pages can finish voting while clients update to R94.
CREATE OR REPLACE FUNCTION public.debate_vote_proposal(p_id bigint,p_yes boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN PERFORM private.cast_dilemma_proposal_vote(p_id,p_yes,NULL);END $fn$;

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
 select count(*) filter(where choice),count(*) filter(where not choice) into yes_count,no_count from debate_dilemma_proposal_votes where proposal_id=p.id and vote_cycle=p.vote_cycle and exists(select 1 from public.players pl where pl.room_id=p.room_id and pl.user_id=debate_dilemma_proposal_votes.user_id and pl.abandoned_at is null and pl.presence='present');
 select count(*) into total from players where room_id=p_room and abandoned_at is null and presence='present';
 select choice into mine from debate_dilemma_proposal_votes where proposal_id=p.id and vote_cycle=p.vote_cycle and user_id=auth.uid();
 return jsonb_build_object('id',p.id,'status',p.status,'vote_cycle',p.vote_cycle,'resolved_by',p.resolved_by,'dilemma_id',p.dilemma_id,'question',p.question,'option_a',p.option_a,'option_b',p.option_b,'category',p.category,'context',p.context,'yes',yes_count,'no',no_count,'total',total,'my_vote',mine,'has_voted',exists(select 1 from debate_dilemma_proposal_votes where proposal_id=p.id and vote_cycle=p.vote_cycle and user_id=auth.uid()),'rejected_ids',coalesce((select jsonb_agg(dilemma_id) from debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null),'[]'::jsonb));
end $function$
;
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
 -- World candidates can be discarded as soon as the table reaches a strict majority.
 if s.phase in('questions','runoff') and s.theme like 'ACTUALIDAD IA:%' and
 (select count(*) from public.debate_selection_votes v where v.room_id=p_room and v.stage=s.stage and v.choice='__DISCARD__' and exists(select 1 from public.players pl where pl.room_id=p_room and pl.user_id=v.user_id and pl.abandoned_at is null and pl.presence='present'))>total/2
 then winner:='__DISCARD__';
 else
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
 -- A plurality of discard votes is not a majority: put it against the leading question.
 if winner='__DISCARD__' and s.phase='questions' then
  select v.choice into selected_theme from public.debate_selection_votes v
  where v.room_id=p_room and v.stage=s.stage and v.choice<>'__DISCARD__'
  and exists(select 1 from public.players pl where pl.room_id=p_room and pl.user_id=v.user_id and pl.abandoned_at is null and pl.presence='present')
  group by v.choice order by count(*) desc,random() limit 1;
  update public.debate_selections set phase='runoff',stage=s.stage+1,options=jsonb_build_array('__DISCARD__',selected_theme),updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
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
end $function$
;
NOTIFY pgrst,'reload schema';
