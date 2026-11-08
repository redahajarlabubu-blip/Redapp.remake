-- RedApp backend schema. Run once in Supabase: SQL Editor > New query > paste > Run.
create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 40),
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  title text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create table public.members (
  conversation_id uuid references public.conversations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index on public.members(user_id);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null default auth.uid() references public.profiles(id),
  kind text not null check (kind in ('text','image','video','file','voice','sticker')),
  body text check (char_length(body) <= 8000),
  media_path text,
  media_name text,
  created_at timestamptz not null default now()
);
create index on public.messages(conversation_id, created_at);
create table public.receipts (
  message_id uuid references public.messages(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  delivered_at timestamptz,
  read_at timestamptz,
  primary key (message_id, user_id)
);
create table public.calls (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  caller_id uuid not null default auth.uid() references public.profiles(id),
  video boolean not null default false,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create table public.devices (
  token text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  updated_at timestamptz not null default now(),
  primary key (token, user_id)
);

-- Helpers ---------------------------------------------------------------
create function public.is_member(c uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from members where conversation_id = c and user_id = auth.uid())
$$;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username, display_name)
  values (new.id, lower(new.raw_user_meta_data->>'username'),
          coalesce(nullif(new.raw_user_meta_data->>'display_name',''), new.raw_user_meta_data->>'username'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Row level security ------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.conversations enable row level security;
alter table public.members       enable row level security;
alter table public.messages      enable row level security;
alter table public.receipts      enable row level security;
alter table public.calls         enable row level security;
alter table public.devices       enable row level security;

create policy profiles_read  on public.profiles for select to authenticated using (true);
create policy profiles_write on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy conv_read   on public.conversations for select to authenticated using (public.is_member(id));
create policy members_read on public.members for select to authenticated using (public.is_member(conversation_id));
create policy msg_read    on public.messages for select to authenticated using (public.is_member(conversation_id));
create policy msg_insert  on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id));
create policy rcpt_read   on public.receipts for select to authenticated
  using (public.is_member((select m.conversation_id from public.messages m where m.id = message_id)));
create policy calls_read   on public.calls for select to authenticated using (public.is_member(conversation_id));
create policy calls_insert on public.calls for insert to authenticated
  with check (caller_id = auth.uid() and public.is_member(conversation_id));
create policy calls_end    on public.calls for update to authenticated using (caller_id = auth.uid());
create policy devices_own  on public.devices for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- RPCs --------------------------------------------------------------------
create function public.start_direct(other uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null or other = auth.uid() or not exists (select 1 from profiles where id = other) then
    raise exception 'invalid user';
  end if;
  select c.id into cid from conversations c
   where not c.is_group
     and exists (select 1 from members where conversation_id = c.id and user_id = auth.uid())
     and exists (select 1 from members where conversation_id = c.id and user_id = other)
   limit 1;
  if cid is null then
    insert into conversations (is_group, created_by) values (false, auth.uid()) returning id into cid;
    insert into members (conversation_id, user_id) values (cid, auth.uid()), (cid, other);
  end if;
  return cid;
end $$;

create function public.create_group(title text, member_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null or coalesce(array_length(member_ids,1),0) < 1 or array_length(member_ids,1) > 49 then
    raise exception 'invalid group';
  end if;
  insert into conversations (is_group, title, created_by) values (true, left(title, 60), auth.uid()) returning id into cid;
  insert into members (conversation_id, user_id, role) values (cid, auth.uid(), 'admin');
  insert into members (conversation_id, user_id)
    select p.id from profiles p where p.id = any(member_ids) and p.id <> auth.uid();
  return cid;
end $$;

create function public.my_conversations()
returns table (id uuid, is_group boolean, title text, last_body text, last_kind text, last_at timestamptz,
               unread bigint, peer_id uuid, peer_last_seen timestamptz, member_count bigint)
language sql security definer stable set search_path = public as $$
  select c.id, c.is_group,
         case when c.is_group then c.title else p.display_name end,
         lm.body, lm.kind, coalesce(lm.created_at, c.created_at),
         (select count(*) from messages m
           where m.conversation_id = c.id and m.sender_id <> auth.uid()
             and not exists (select 1 from receipts r where r.message_id = m.id and r.user_id = auth.uid() and r.read_at is not null)),
         p.id, p.last_seen,
         (select count(*) from members x where x.conversation_id = c.id)
  from conversations c
  join members me on me.conversation_id = c.id and me.user_id = auth.uid()
  left join lateral (select x.user_id from members x
                      where x.conversation_id = c.id and x.user_id <> auth.uid() and not c.is_group limit 1) pm on true
  left join profiles p on p.id = pm.user_id
  left join lateral (select m.body, m.kind, m.created_at from messages m
                      where m.conversation_id = c.id order by m.created_at desc limit 1) lm on true
  order by 6 desc
$$;

create function public.mark_delivered(conv uuid) returns void
language sql security definer set search_path = public as $$
  insert into receipts (message_id, user_id, delivered_at)
  select m.id, auth.uid(), now() from messages m
   where m.conversation_id = conv and m.sender_id <> auth.uid() and public.is_member(conv)
  on conflict do nothing
$$;

create function public.mark_read(conv uuid) returns void
language sql security definer set search_path = public as $$
  insert into receipts (message_id, user_id, delivered_at, read_at)
  select m.id, auth.uid(), now(), now() from messages m
   where m.conversation_id = conv and m.sender_id <> auth.uid() and public.is_member(conv)
  on conflict (message_id, user_id) do update
    set read_at = coalesce(receipts.read_at, now()), delivered_at = coalesce(receipts.delivered_at, now())
$$;

create function public.chat_receipts(conv uuid) returns setof public.receipts
language sql security definer stable set search_path = public as $$
  select r.* from receipts r join messages m on m.id = r.message_id
   where m.conversation_id = conv and m.sender_id = auth.uid() and public.is_member(conv)
$$;

create function public.heartbeat() returns void
language sql security definer set search_path = public as $$
  update profiles set last_seen = now() where id = auth.uid()
$$;

create function public.register_device(tok text) returns void
language sql security definer set search_path = public as $$
  insert into devices (token, user_id) values (tok, auth.uid())
  on conflict (token, user_id) do update set updated_at = now()
$$;
create function public.unregister_device(tok text) returns void
language sql security definer set search_path = public as $$
  delete from devices where token = tok and user_id = auth.uid()
$$;

revoke all on function public.start_direct, public.create_group, public.my_conversations, public.mark_delivered,
  public.mark_read, public.chat_receipts, public.heartbeat, public.register_device, public.unregister_device from public, anon;
grant execute on function public.start_direct, public.create_group, public.my_conversations, public.mark_delivered,
  public.mark_read, public.chat_receipts, public.heartbeat, public.register_device, public.unregister_device to authenticated;

-- Realtime ----------------------------------------------------------------
alter publication supabase_realtime add table public.messages, public.calls, public.receipts;

-- Storage (private bucket; files are served through short-lived signed URLs)
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 52428800) on conflict (id) do nothing;
create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy media_read on storage.objects for select to authenticated using (bucket_id = 'media');
