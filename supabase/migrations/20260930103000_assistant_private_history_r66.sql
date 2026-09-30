grant select on public.debate_assistant_guides to authenticated;
create policy assistant_read_own_history on public.debate_assistant_guides for select to authenticated
 using ((select auth.uid())=user_id);
create table public.private_dilemma_guides (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references public.private_dilemma_sessions(id) on delete cascade,
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 choice text not null check(choice in ('A','B')),
 signature text not null,
 guide jsonb not null check(jsonb_typeof(guide)='object' and length(guide::text)<=8500),
 mode text not null check(mode in ('IA','BASICA')),
 created_at timestamptz not null default now()
);
create index private_dilemma_guides_owner_session on public.private_dilemma_guides(user_id,session_id,created_at desc);
alter table public.private_dilemma_guides enable row level security;
revoke all on public.private_dilemma_guides from anon;
grant select,insert,delete on public.private_dilemma_guides to authenticated;
create policy private_guide_read on public.private_dilemma_guides for select to authenticated using((select auth.uid())=user_id);
create policy private_guide_insert on public.private_dilemma_guides for insert to authenticated
 with check((select auth.uid())=user_id and exists(select 1 from public.private_dilemma_sessions s where s.id=session_id and s.user_id=(select auth.uid())));
create policy private_guide_delete on public.private_dilemma_guides for delete to authenticated using((select auth.uid())=user_id);
insert into public.private_dilemma_guides(session_id,user_id,choice,signature,guide,mode,created_at)
select s.id,s.user_id,x.key,x.value->>'signature',x.value->'guide',x.value->>'mode',s.created_at
from public.private_dilemma_sessions s cross join lateral jsonb_each(s.guides) x
where x.key in ('A','B') and x.value->'guide' is not null and x.value->>'mode' in ('IA','BASICA') and x.value->>'signature' is not null;