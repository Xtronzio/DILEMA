-- R74: saved private sessions remain in their existing owner-protected table.
create table public.saved_group_dilemmas (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 source_round_id bigint not null,
 question text not null, option_a text not null, option_b text not null,
 context text not null default '',
 guides jsonb not null default '[]'::jsonb check(jsonb_typeof(guides)='array'),
 created_at timestamptz not null default now(),
 unique(user_id,source_round_id)
);
alter table public.saved_group_dilemmas enable row level security;
revoke all on public.saved_group_dilemmas from public,anon,authenticated;
grant select,delete on public.saved_group_dilemmas to authenticated;
grant all on public.saved_group_dilemmas to service_role;
create policy saved_group_owner_read on public.saved_group_dilemmas for select to authenticated using((select auth.uid())=user_id);
create policy saved_group_owner_delete on public.saved_group_dilemmas for delete to authenticated using((select auth.uid())=user_id);
create index saved_group_owner_date on public.saved_group_dilemmas(user_id,created_at desc);
create index if not exists private_dilemma_owner_date on public.private_dilemma_sessions(user_id,created_at desc);
CREATE OR REPLACE FUNCTION private.archive_finished_dilemma()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare owner_id uuid; q public.dilemmas; own_guides jsonb;
begin
 if new.debate_phase is distinct from 'finished' or old.debate_phase='finished' then return new; end if;
 select p.user_id into owner_id from public.rooms r join public.players p on p.room_id=r.id and p.player_id=r.host_id
 where r.id=new.room_id and r.mode='debate' and p.abandoned_at is null limit 1;
 if owner_id is null then return new;end if;
 select * into q from public.dilemmas where id=new.dilemma_id;
 if q.id is null then return new;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'choice',g.choice,'guide',g.guide,'mode',g.mode,'created_at',g.created_at,'cycle_number',g.cycle_number) order by g.created_at desc),'[]'::jsonb)
 into own_guides from public.debate_assistant_guides g where g.round_id=new.id and g.user_id=owner_id and g.status='ready';
 insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b,context,guides)
 values(owner_id,new.id,q.question,q.option_a,q.option_b,new.context,own_guides)
 on conflict(user_id,source_round_id) do nothing;
 return new;
end $function$

revoke all on function private.archive_finished_dilemma() from public,anon,authenticated;
create trigger archive_finished_dilemma after update of debate_phase on public.rounds
 for each row when(new.debate_phase='finished' and old.debate_phase is distinct from new.debate_phase)
 execute function private.archive_finished_dilemma();
