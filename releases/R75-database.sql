create table private.access_links (
 user_id uuid primary key references auth.users(id) on delete cascade,
 key_hash text not null unique check(key_hash ~ '^[0-9a-f]{64}$'),
 profiles jsonb not null default '[]'::jsonb check(jsonb_typeof(profiles)='array' and jsonb_array_length(profiles)<=50 and length(profiles::text)<=30000),
 created_at timestamptz not null default now(), last_used_at timestamptz
);
alter table private.access_links enable row level security;
revoke all on private.access_links from public,anon,authenticated,service_role;
create function private.access_link_write(p_user uuid,p_hash text,p_profiles jsonb,p_replace boolean) returns void
language plpgsql security definer set search_path='' as $$
declare old_hash text;begin
 if (auth.jwt()->>'role') is distinct from 'service_role' then raise exception 'Not authorized';end if;
 perform 1 from auth.users where id=p_user for update;if not found then raise exception 'Unknown user';end if;
 select key_hash into old_hash from private.access_links where user_id=p_user;
 if old_hash is not null and old_hash<>p_hash and not p_replace then raise exception 'LINK_EXISTS';end if;
 insert into private.access_links(user_id,key_hash,profiles) values(p_user,p_hash,p_profiles)
 on conflict(user_id) do update set key_hash=excluded.key_hash,profiles=excluded.profiles,
 last_used_at=case when private.access_links.key_hash=excluded.key_hash then private.access_links.last_used_at else null end;
end $$;
create function private.access_link_read(p_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r private.access_links;begin
 if (auth.jwt()->>'role') is distinct from 'service_role' then raise exception 'Not authorized';end if;
 select * into r from private.access_links where key_hash=p_hash for update;
 if r.user_id is null then return null;end if;
 if r.last_used_at>now()-interval '3 seconds' then raise exception 'TRY_LATER';end if;
 update private.access_links set last_used_at=now() where user_id=r.user_id;
 return jsonb_build_object('user_id',r.user_id,'profiles',r.profiles);
end $$;
create function private.access_link_profiles(p_user uuid,p_profiles jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 if (auth.jwt()->>'role') is distinct from 'service_role' then raise exception 'Not authorized';end if;
 update private.access_links set profiles=p_profiles where user_id=p_user;
end $$;
create function public.access_link_write(p_user uuid,p_hash text,p_profiles jsonb,p_replace boolean default false) returns void
language sql security invoker set search_path='' as $$select private.access_link_write(p_user,p_hash,p_profiles,p_replace)$$;
create function public.access_link_read(p_hash text) returns jsonb
language sql security invoker set search_path='' as $$select private.access_link_read(p_hash)$$;
create function public.access_link_profiles(p_user uuid,p_profiles jsonb) returns void
language sql security invoker set search_path='' as $$select private.access_link_profiles(p_user,p_profiles)$$;
revoke all on function public.access_link_write(uuid,text,jsonb,boolean),public.access_link_read(text),public.access_link_profiles(uuid,jsonb),private.access_link_write(uuid,text,jsonb,boolean),private.access_link_read(text),private.access_link_profiles(uuid,jsonb) from public,anon,authenticated;
grant usage on schema private to service_role;
grant execute on function public.access_link_write(uuid,text,jsonb,boolean),public.access_link_read(text),public.access_link_profiles(uuid,jsonb),private.access_link_write(uuid,text,jsonb,boolean),private.access_link_read(text),private.access_link_profiles(uuid,jsonb) to service_role;
