create table public.private_dilemma_sessions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 question text not null check(length(trim(question)) between 1 and 240),
 option_a text not null check(length(trim(option_a)) between 1 and 240),
 option_b text not null check(length(trim(option_b)) between 1 and 240),
 choice text check(choice in ('A','B')),
 guides jsonb not null default '{}'::jsonb check(jsonb_typeof(guides)='object' and length(guides::text)<20000),
 created_at timestamptz not null default now()
);
create index private_dilemma_sessions_owner on public.private_dilemma_sessions(user_id);
alter table public.private_dilemma_sessions enable row level security;
revoke all on public.private_dilemma_sessions from anon;
grant select,insert,update,delete on public.private_dilemma_sessions to authenticated;
create policy private_dilemma_owner on public.private_dilemma_sessions for all to authenticated
 using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);