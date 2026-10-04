DO $test$
DECLARE u uuid:=gen_random_uuid();rm bigint;one bigint;two bigint;old bigint;v jsonb;
BEGIN
 BEGIN
  INSERT INTO auth.users(id,is_anonymous) VALUES(u,true);
  INSERT INTO public.rooms(code,mode,host_id) VALUES('R103-news-'||gen_random_uuid(),'debate',u::text) RETURNING id INTO rm;
  INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,u::text,u,'R103 news test');
  INSERT INTO public.dilemmas(audience,category,intensity,question,option_a,option_b,active,source_kind,news_meta)
   VALUES('teen','ACTUALIDAD IA',3,'R103 test one','A','B',true,'current',jsonb_build_object('title','R103 noticia única '||u,'date',current_date,'url','https://efe.com/espana/test-'||u)) RETURNING id INTO one;
  INSERT INTO public.dilemmas(audience,category,intensity,question,option_a,option_b,active,source_kind,news_meta)
   VALUES('teen','ACTUALIDAD IA',2,'R103 test two','A','B',true,'current',jsonb_build_object('title','R103 noticia única '||u,'date',current_date,'url','https://www.rtve.es/noticias/test-'||u)) RETURNING id INTO two;
  INSERT INTO public.dilemmas(audience,category,intensity,question,option_a,option_b,active,source_kind,news_meta)
   VALUES('teen','ACTUALIDAD IA',3,'R103 stale test','A','B',true,'current',jsonb_build_object('title','R103 vieja '||u,'date',current_date-5,'url','https://efe.com/espana/old-'||u)) RETURNING id INTO old;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('role','service_role','sub',u)::text,true);
  PERFORM set_config('request.jwt.claim.sub',u::text,true);
  IF private.world_key(one)<>private.world_key(two) THEN RAISE EXCEPTION 'Same title across outlets not deduplicated';END IF;
  v:=private.fresh_world_candidates(jsonb_build_array(one,two),u,rm,3,'ALEATORIO');
  IF jsonb_array_length(v->'ids')<>1 THEN RAISE EXCEPTION 'Duplicate proposals returned';END IF;
  INSERT INTO public.debate_selections(room_id,phase,stage,theme) VALUES(rm,'news_loading',1,'ACTUALIDAD IA:ALEATORIO');
  IF NOT private.publish_current_ai(rm,1,v->'ids') THEN RAISE EXCEPTION 'Publish failed';END IF;
  IF NOT private.world_seen(two,u,rm) THEN RAISE EXCEPTION 'Displayed source not remembered';END IF;
  v:=private.fresh_world_candidates(jsonb_build_array(one,two,old),u,rm,3,'ALEATORIO');
  IF v->'ids' @> jsonb_build_array(one) OR v->'ids' @> jsonb_build_array(two) OR v->'ids' @> jsonb_build_array(old) THEN RAISE EXCEPTION 'Seen or stale proposal recycled';END IF;
  -- New rooms still honor the user's history, and late publication does not mark new proposals.
  IF NOT private.world_seen(two,u,NULL) THEN RAISE EXCEPTION 'User history missing';END IF;
  IF private.publish_current_ai(rm,99,jsonb_build_array(old)) THEN RAISE EXCEPTION 'Obsolete stage published';END IF;
  IF private.world_seen(old,u,rm) THEN RAISE EXCEPTION 'Obsolete publication modified history';END IF;
  RAISE SQLSTATE 'ZX103' USING MESSAGE='PASS R103 news: source deduplication, display history, stale rejection, obsolete publication';
 EXCEPTION WHEN SQLSTATE 'ZX103' THEN RAISE NOTICE '%',SQLERRM;
 END;
END $test$;
