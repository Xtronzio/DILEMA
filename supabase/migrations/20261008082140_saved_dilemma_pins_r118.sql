-- R118: account pins protect both private and archived group dilemmas.
alter table public.private_dilemma_sessions add column is_pinned boolean not null default false;
alter table public.saved_group_dilemmas add column is_pinned boolean not null default false;
create function private.protect_pinned_dilemma()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if old.is_pinned then raise exception using errcode = 'P0001', message = 'DILEMMA_PINNED'; end if;
  return old;
end;
$$;
revoke all on function private.protect_pinned_dilemma() from public;
grant execute on function private.protect_pinned_dilemma() to authenticated, service_role;
create trigger protect_pinned_dilemma before delete on public.private_dilemma_sessions for each row execute function private.protect_pinned_dilemma();
create trigger protect_pinned_dilemma before delete on public.saved_group_dilemmas for each row execute function private.protect_pinned_dilemma();
grant update (is_pinned) on public.saved_group_dilemmas to authenticated;
create policy saved_group_owner_pin on public.saved_group_dilemmas for update to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create view public.saved_dilemma_library with (security_invoker = true) as
select id,user_id,'PRIV'::text as origin,question,choice,created_at,is_pinned,
       null::text as session_state,null::bigint as session_id,null::bigint as room_id,lower(question) as sort_title
from public.private_dilemma_sessions
union all
select id,user_id,'GRUP'::text as origin,question,choice,created_at,is_pinned,session_state,session_id,room_id,lower(question) as sort_title
from public.saved_group_dilemmas;
revoke all on public.saved_dilemma_library from public,anon;
grant select on public.saved_dilemma_library to authenticated;
create index private_dilemma_pin_date_idx on public.private_dilemma_sessions (user_id,is_pinned desc,created_at desc,id);
create index saved_group_pin_date_idx on public.saved_group_dilemmas (user_id,is_pinned desc,created_at desc,id);
notify pgrst,'reload schema';

