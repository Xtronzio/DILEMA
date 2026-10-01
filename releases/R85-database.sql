alter table public.saved_group_dilemmas add column if not exists choice text check(choice in ('A','B'));

CREATE OR REPLACE FUNCTION private.archive_finished_dilemma()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare owner_id uuid; q public.dilemmas; own_guides jsonb; own_choice text;
begin
 if new.debate_phase is distinct from 'finished' or old.debate_phase='finished' then return new; end if;
 select p.user_id into owner_id from public.rooms r join public.players p on p.room_id=r.id and p.player_id=r.host_id
 where r.id=new.room_id and r.mode='debate' and p.abandoned_at is null limit 1;
 if owner_id is null then return new;end if;
 select * into q from public.dilemmas where id=new.dilemma_id;
 if q.id is null then return new;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'choice',g.choice,'guide',g.guide,'mode',g.mode,'created_at',g.created_at,'cycle_number',g.cycle_number) order by g.created_at desc),'[]'::jsonb)
 into own_guides from public.debate_assistant_guides g where g.round_id=new.id and g.user_id=owner_id and g.status='ready';
 select choice into own_choice from public.debate_vote_cycles where round_id=new.id and user_id=owner_id order by cycle_number desc limit 1;
 insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b,context,guides,choice)
 values(owner_id,new.id,q.question,q.option_a,q.option_b,new.context,own_guides,own_choice)
 on conflict(user_id,source_round_id) do nothing;
 return new;
end $function$
;

update public.saved_group_dilemmas s set choice=(select v.choice from public.debate_vote_cycles v where v.round_id=s.source_round_id and v.user_id=s.user_id order by v.cycle_number desc limit 1) where s.choice is null and s.source_round_id is not null;

CREATE OR REPLACE FUNCTION private.my_admission(p_id bigint, p_cancel boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q private.debate_admissions;r public.rounds; room public.rooms; dilemma public.dilemmas; payload jsonb;
begin
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if q.id is null then raise exception 'Not your request';end if;
 perform 1 from public.rounds where id=q.round_id for update;
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if p_cancel then
  if q.status='accepted' and exists(select 1 from public.players where room_id=(select room_id from public.rounds where id=q.round_id) and user_id=auth.uid() and abandoned_at is null) then perform public.abandon_debate((select room_id from public.rounds where id=q.round_id),null);end if;
  update private.debate_admissions set status='cancelled',decided_at=now() where id=p_id and status in('queued','open','accepted');
 end if;
 perform private.admission_pump(q.round_id);
 select * into q from private.debate_admissions where id=p_id;
 select * into r from public.rounds where id=q.round_id;
 if q.status='accepted' and not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and player_id=q.player_id and abandoned_at is null) then return jsonb_build_object('status','removed');end if;
 if q.status='accepted' and r.status='debate' and r.debate_phase='debate' and r.id=(select max(id) from public.rounds where room_id=r.room_id) then
  select * into room from public.rooms where id=r.room_id and status='playing' and mode='debate';
  select * into dilemma from public.dilemmas where id=r.dilemma_id;
  if room.id is not null and dilemma.id is not null then
   payload:=jsonb_build_object('room',jsonb_build_object('id',room.id,'code',room.code,'host_id',room.host_id,'expected_players',room.expected_players,'status',room.status,'mode',room.mode),
    'round',jsonb_build_object('id',r.id,'room_id',r.room_id,'status',r.status,'dilemma_id',r.dilemma_id,'context',r.context),
    'dilemma',to_jsonb(dilemma),'state',public.get_debate_state(r.id));
  end if;
 end if;
 return coalesce(payload,'{}'::jsonb)||jsonb_build_object('status',q.status,'room_id',r.room_id,'player_id',q.player_id,'round_id',q.round_id);
end $function$
;
