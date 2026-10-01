create or replace function private.fallback_current_ai(p_intensity integer,p_theme text,p_seed text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ids jsonb; kind text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden'; end if;
 if p_intensity not between 1 and 3 then raise exception 'Invalid intensity'; end if;
 select jsonb_agg(id) into ids from (
  select d.id from public.dilemmas d where d.active and d.source_kind='current'
   and d.news_meta->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
   and d.news_meta->>'date'>=to_char(current_date-14,'YYYY-MM-DD')
   and d.news_meta->>'date'<=to_char(current_date+1,'YYYY-MM-DD')
  order by (d.news_meta->>'selection_policy'='spain-first-v1') desc nulls last,
   abs(d.intensity-p_intensity), (d.debate_theme=p_theme) desc nulls last,
   d.news_meta->>'date' desc,md5(d.id::text||p_seed) limit 3
 ) q;
 kind:='previous_news';
 if ids is null then
  select jsonb_agg(id) into ids from (
   select d.id from public.dilemmas d where d.active and d.source_kind='catalog' and d.audience='teen'
   order by abs(d.intensity-p_intensity),(d.debate_theme=p_theme) desc nulls last,md5(d.id::text||p_seed) limit 3
  ) q;
  kind:='catalog';
 end if;
 return jsonb_build_object('ids',coalesce(ids,'[]'::jsonb),'fallback',kind);
end $$;
revoke all on function private.fallback_current_ai(integer,text,text) from public,anon,authenticated;
grant execute on function private.fallback_current_ai(integer,text,text) to service_role;
create or replace function public.fallback_current_ai(p_intensity integer,p_theme text,p_seed text)
returns jsonb language sql set search_path='' as $$ select private.fallback_current_ai(p_intensity,p_theme,p_seed) $$;
revoke all on function public.fallback_current_ai(integer,text,text) from public,anon,authenticated;
grant execute on function public.fallback_current_ai(integer,text,text) to service_role;
create or replace function private.publish_current_ai(p_room bigint,p_stage integer,p_ids jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden'; end if;
 if jsonb_array_length(p_ids) not between 1 and 3 or exists(select 1 from jsonb_array_elements_text(p_ids) x where not exists(select 1 from public.dilemmas d where d.id=x::bigint and d.source_kind in ('current','catalog') and d.active and d.audience='teen')) then raise exception 'Invalid candidates'; end if;
 update public.debate_selections s set phase='questions',options=p_ids,updated_at=now() where s.room_id=p_room and s.stage=p_stage and s.phase='news_loading' and exists(select 1 from public.rooms r where r.id=p_room and r.status='waiting');
 return found;
end $$;
-- Accept the versioned Spain-first cache key introduced in R78.
do $fix$ declare definition text; begin
 definition:=pg_get_functiondef('private.claim_current_ai(text,uuid)'::regprocedure);
 definition:=replace(definition,'''^v1:[123]:''','''^v(1|2-spain-first):[123]:''');
 execute definition;
end $fix$;
