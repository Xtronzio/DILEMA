CREATE OR REPLACE FUNCTION private.pick_inventory_recipient(p_round bigint, p_item text)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 WITH positioned AS MATERIALIZED (
  SELECT p.user_id,private.debate_inventory_load(p_round,p.user_id) AS load
  FROM public.players p JOIN public.rounds r ON r.room_id=p.room_id AND r.id=p_round
  JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
  WHERE p.abandoned_at IS NULL AND p.presence='present' AND p.user_id IS NOT NULL AND v.choice IN ('A','B','N')
 )
 SELECT p.user_id FROM positioned p
 WHERE p.load=(SELECT min(load) FROM positioned)
 AND CASE p_item
  WHEN 'proclamation' THEN NOT EXISTS(SELECT 1 FROM public.debate_proclamations i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  WHEN 'revote' THEN NOT EXISTS(SELECT 1 FROM public.debate_secret_revotes i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  WHEN 'assistant' THEN NOT EXISTS(SELECT 1 FROM public.debate_assistant_tokens i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  ELSE p_item IN ('limbo','robo','senuelo','cambio','espejo','antidoto') AND NOT EXISTS(SELECT 1 FROM private.debate_medicine_inventory i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.item=p_item AND i.quantity=1)
 END
 ORDER BY random() LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION private.defend_debate_medicine(p_round bigint, p_use uuid, p_defence text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 PERFORM private.resolve_medicine(p_round);
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use AND round_id=p_round FOR UPDATE;
 IF m.id IS NULL OR m.target<>u THEN RAISE EXCEPTION 'Not the recipient';END IF;
 IF m.status<>'pending' THEN RETURN private.medicine_state(p_round);END IF;
 IF p_defence IS NULL OR p_defence NOT IN('espejo','antidoto','none') THEN RAISE EXCEPTION 'Invalid defence';END IF;
 IF p_defence<>'none' THEN
  IF NOT EXISTS(SELECT 1 FROM public.debate_vote_cycles v JOIN public.players p ON p.user_id=v.user_id AND p.room_id=r.room_id WHERE v.round_id=p_round AND v.cycle_number=r.vote_cycle AND v.user_id=u AND v.choice IN('A','B') AND p.presence='present' AND p.abandoned_at IS NULL) THEN RAISE EXCEPTION 'Choose A or B to use tools';END IF;
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=p_round AND user_id=u AND item=p_defence AND quantity=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No defence available';END IF;
 END IF;
 IF p_defence='antidoto' THEN
  copy:=CASE WHEN m.item='senuelo' THEN 'Era un señuelo. Has gastado el Antídoto en una falsa pócima.' ELSE 'El Antídoto ha neutralizado la pócima.' END;
 ELSE copy:=private.apply_medicine(m.id,p_defence='espejo');END IF;
 UPDATE private.debate_medicine_uses SET status=CASE WHEN p_defence='espejo' THEN 'reflected' WHEN p_defence='antidoto' THEN 'blocked' WHEN m.item='senuelo' THEN 'decoy' ELSE 'applied' END,
 defence=nullif(p_defence,'none'),result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 RETURN private.medicine_state(p_round);
END $function$;

CREATE OR REPLACE FUNCTION private.world_key(p_id bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN d.news_meta->>'url' IS NOT NULL THEN
 CASE WHEN length(trim(coalesce(d.news_meta->>'title',''))) > 0 THEN 'story:'||md5(trim(regexp_replace(lower(translate(d.news_meta->>'title','áéíóúüñ','aeiouun')),'[^a-z0-9]+',' ','g')))
 ELSE 'news:'||split_part(split_part(d.news_meta->>'url','#',1),'?',1) END
 ELSE 'dilemma:'||md5(lower(regexp_replace(d.question,'\s+',' ','g'))) END FROM public.dilemmas d WHERE id=p_id
$$;

CREATE OR REPLACE FUNCTION private.world_seen(p_id bigint, p_user uuid, p_room bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from private.world_dilemma_history h where (h.conflict_key=private.world_key(p_id) OR EXISTS(SELECT 1 FROM public.dilemmas old WHERE private.world_key(old.id)=private.world_key(p_id) AND h.conflict_key='news:'||split_part(split_part(old.news_meta->>'url','#',1),'?',1))) and (h.scope='user:'||p_user::text or h.scope='room:'||p_room::text or (p_room is not null and exists(select 1 from public.players p where p.room_id=p_room and p.abandoned_at is null and h.scope='user:'||p.user_id::text))))
 or (p_room is not null and exists(select 1 from public.rounds r where r.room_id=p_room and private.world_key(r.dilemma_id)=private.world_key(p_id)))
$function$;

CREATE OR REPLACE FUNCTION private.fresh_world_candidates(p_ids jsonb,p_user uuid,p_room bigint,p_intensity integer,p_theme text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ids jsonb;kind text;
BEGIN
 IF coalesce(auth.jwt()->>'role','')<>'service_role' OR p_user IS NULL OR p_intensity NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'Forbidden';END IF;
 IF p_room IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=p_room AND user_id=p_user AND presence='present' AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 SELECT jsonb_agg(id ORDER BY priority,id) INTO ids FROM (
  SELECT id,priority FROM (
   SELECT d.id,array_position(ARRAY(SELECT value::bigint FROM jsonb_array_elements_text(coalesce(p_ids,'[]')) x(value)),d.id) priority,
    row_number() OVER(PARTITION BY private.world_key(d.id) ORDER BY abs(d.intensity-p_intensity),d.created_at DESC,d.id) rn
   FROM public.dilemmas d WHERE d.active AND d.audience='teen' AND d.id IN(SELECT value::bigint FROM jsonb_array_elements_text(coalesce(p_ids,'[]')) x(value))
    AND (d.source_kind='catalog' OR d.news_meta->>'date' BETWEEN to_char(current_date-3,'YYYY-MM-DD') AND to_char(current_date,'YYYY-MM-DD'))
    AND NOT private.world_seen(d.id,p_user,p_room)
  ) ranked WHERE rn=1 ORDER BY priority,id LIMIT 3
 ) selected;
 IF ids IS NOT NULL THEN RETURN jsonb_build_object('ids',ids);END IF;
 SELECT jsonb_agg(id ORDER BY news_date DESC,id) INTO ids FROM (
  SELECT id,news_date FROM (
   SELECT d.id,d.news_meta->>'date' news_date,
    row_number() OVER(PARTITION BY private.world_key(d.id) ORDER BY abs(d.intensity-p_intensity),(d.debate_theme=p_theme) DESC NULLS LAST,d.created_at DESC,d.id) rn
   FROM public.dilemmas d WHERE d.active AND d.audience='teen' AND d.source_kind='current'
    AND d.news_meta->>'date' BETWEEN to_char(current_date-3,'YYYY-MM-DD') AND to_char(current_date,'YYYY-MM-DD')
    AND NOT private.world_seen(d.id,p_user,p_room)
  ) ranked WHERE rn=1 ORDER BY news_date DESC,id LIMIT 3
 ) selected;kind:='previous_news';
 IF ids IS NULL THEN
  SELECT jsonb_agg(id) INTO ids FROM (SELECT d.id FROM public.dilemmas d WHERE d.active AND d.audience='teen' AND d.source_kind='catalog' AND NOT private.world_seen(d.id,p_user,p_room) ORDER BY abs(d.intensity-p_intensity),(d.debate_theme=p_theme) DESC NULLS LAST,random() LIMIT 3) selected;
  kind:='catalog';
 END IF;
 RETURN jsonb_build_object('ids',coalesce(ids,'[]'::jsonb),'fallback',kind);
END $$;

CREATE OR REPLACE FUNCTION private.publish_current_ai(p_room bigint, p_stage integer, p_ids jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare published boolean;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden'; end if;
 if jsonb_array_length(p_ids) not between 1 and 3 or exists(select 1 from jsonb_array_elements_text(p_ids) x where not exists(select 1 from public.dilemmas d where d.id=x::bigint and d.source_kind in ('current','catalog') and d.active and d.audience='teen')) then raise exception 'Invalid candidates'; end if;
 update public.debate_selections s set phase='questions',options=p_ids,updated_at=now() where s.room_id=p_room and s.stage=p_stage and s.phase='news_loading' and exists(select 1 from public.rooms r where r.id=p_room and r.status='waiting');
 published:=found;
 if published then
  insert into private.world_dilemma_history(scope,conflict_key)
   select 'room:'||p_room,private.world_key(value::bigint) from jsonb_array_elements_text(p_ids) on conflict do nothing;
  insert into private.world_dilemma_history(scope,conflict_key)
   select 'user:'||p.user_id,private.world_key(x.value::bigint) from public.players p cross join jsonb_array_elements_text(p_ids) x(value)
   where p.room_id=p_room and p.abandoned_at is null and p.user_id is not null on conflict do nothing;
 end if;
 return published;
end $function$;

-- Preserve previous URL histories when stories have multiple source URLs.
INSERT INTO private.world_dilemma_history(scope,conflict_key,created_at)
 SELECT h.scope,private.world_key(d.id),min(h.created_at)
 FROM private.world_dilemma_history h JOIN public.dilemmas d ON h.conflict_key='news:'||split_part(split_part(d.news_meta->>'url','#',1),'?',1)
 WHERE d.source_kind='current' GROUP BY h.scope,private.world_key(d.id) ON CONFLICT DO NOTHING;
-- Record news proposals already displayed, without altering their current vote.
INSERT INTO private.world_dilemma_history(scope,conflict_key)
 SELECT 'room:'||s.room_id,private.world_key(x.value::bigint)
 FROM public.debate_selections s CROSS JOIN LATERAL jsonb_array_elements_text(s.options) x(value)
 WHERE s.theme LIKE 'ACTUALIDAD IA:%' AND s.phase IN('questions','runoff') AND x.value ~ '^[0-9]+$' ON CONFLICT DO NOTHING;