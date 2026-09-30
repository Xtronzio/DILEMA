create or replace function private.publish_current_ai(p_room bigint,p_stage integer,p_ids jsonb) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 if jsonb_array_length(p_ids) not between 1 and 3 or exists(select 1 from jsonb_array_elements_text(p_ids) x where not exists(select 1 from public.dilemmas d where d.id=x::bigint and d.source_kind='current' and d.active)) then raise exception 'Invalid candidates';end if;
 update public.debate_selections s set phase='questions',options=p_ids,updated_at=now() where s.room_id=p_room and s.stage=p_stage and s.phase='news_loading' and exists(select 1 from public.rooms r where r.id=p_room and r.status='waiting');
 return found;
end $$;
create or replace function private.finish_current_ai(p_key text,p_lease uuid,p_rows jsonb,p_usage jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.current_ai_cache; d jsonb; new_id bigint; ids jsonb:='[]';
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 select * into c from public.current_ai_cache where cache_key=p_key for update;
 if c.lease is distinct from p_lease or c.status<>'building' then raise exception 'Obsolete generation';end if;
 if jsonb_array_length(p_rows) not between 1 and 3 then raise exception 'Invalid candidates';end if;
 for d in select * from jsonb_array_elements(p_rows) loop
  if d->>'source_kind'<>'current' or d->>'audience'<>'teen' or d->'news_meta' is null then raise exception 'Invalid candidate';end if;
  insert into public.dilemmas(audience,category,intensity,debate_theme,question,option_a,option_b,active,source_kind,news_meta)
  values('teen','ACTUALIDAD IA',(d->>'intensity')::int,d->>'debate_theme',d->>'question',d->>'option_a',d->>'option_b',true,'current',d->'news_meta') returning id into new_id;
  insert into public.dilemma_twists(dilemma_id,text,pressure,active) values(new_id,d->'news_meta'->>'twist','LATERAL',true);
  ids:=ids||jsonb_build_array(new_id);
 end loop;
 update public.current_ai_cache set status='ready',dilemma_ids=ids,usage=p_usage,expires_at=now()+interval '6 hours',lease_until=null,error_detail=null,updated_at=now() where cache_key=p_key;
 return ids;
end $$;
update public.current_ai_cache set lease_until=null where status='failed';
