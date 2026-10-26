-- Sajjel 3endak: online sync setup for Supabase
-- Paste this whole file into Supabase > SQL Editor > New query, then press "Run".
-- It is safe to run again later: it only creates what is missing and refreshes the functions.
--
-- How it works
-- * Each group of friends shares one group code (for example K7Q2XF).
-- * Players and games are stored as records that belong to a group.
-- * The tables are locked: the app can only reach them through the four functions below,
--   and every function needs the group code. Anyone with the code can read and change that group,
--   so share the code only with your card group.

create table if not exists public.sj_groups (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.sj_records (
  group_id    uuid not null references public.sj_groups(id) on delete cascade,
  kind        text not null check (kind in ('player', 'game')),
  id          text not null,
  data        jsonb,
  updated_at  bigint not null,             -- when the phone changed it (ms)
  deleted     boolean not null default false,
  server_ts   bigint not null,             -- when the server stored it (ms), used to fetch only new changes
  primary key (group_id, kind, id)
);
create index if not exists sj_records_group_ts on public.sj_records (group_id, server_ts);

-- Lock the tables: no direct reads or writes from the app.
alter table public.sj_groups  enable row level security;
alter table public.sj_records enable row level security;
revoke all on table public.sj_groups, public.sj_records from anon, authenticated;

-- Create a group and get its code.
create or replace function public.sj_create_group(p_name text)
returns table (code text, name text)
language plpgsql security definer set search_path = public
as $$
declare
  c text;
  n text := coalesce(nullif(trim(p_name), ''), 'Card group');
begin
  if length(n) > 40 then n := left(n, 40); end if;
  loop
    -- 6 characters without look-alikes (no 0/O, 1/I)
    c := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
          from generate_series(1, 6));
    exit when not exists (select 1 from sj_groups g where g.code = c);
  end loop;
  insert into sj_groups (code, name) values (c, n);
  return query select c, n;
end $$;

-- Check a code and get the group's name.
create or replace function public.sj_group_info(p_code text)
returns table (code text, name text)
language sql security definer set search_path = public stable
as $$
  select g.code, g.name from sj_groups g where g.code = upper(trim(p_code));
$$;

-- Fetch everything that changed in the group since a point in time.
create or replace function public.sj_pull(p_code text, p_since bigint)
returns table (kind text, id text, data jsonb, updated_at bigint, deleted boolean, server_ts bigint)
language sql security definer set search_path = public stable
as $$
  select r.kind, r.id, r.data, r.updated_at, r.deleted, r.server_ts
  from sj_records r
  join sj_groups g on g.id = r.group_id
  where g.code = upper(trim(p_code))
    and r.server_ts > coalesce(p_since, 0)
  order by r.server_ts;
$$;

-- Save changed records. When two phones changed the same game, the most recent change wins.
create or replace function public.sj_push(p_code text, p_rows jsonb)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  gid    uuid;
  now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  r      jsonb;
begin
  select g.id into gid from sj_groups g where g.code = upper(trim(p_code));
  if gid is null then
    raise exception 'Unknown group code';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 1000 then
    raise exception 'Expected a list of at most 1000 records';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    insert into sj_records as s (group_id, kind, id, data, updated_at, deleted, server_ts)
    values (gid, r->>'kind', r->>'id', r->'data', (r->>'updated_at')::bigint,
            coalesce((r->>'deleted')::boolean, false), now_ms)
    on conflict (group_id, kind, id) do update
      set data = excluded.data, updated_at = excluded.updated_at,
          deleted = excluded.deleted, server_ts = excluded.server_ts
      where s.updated_at <= excluded.updated_at;
  end loop;
  return now_ms;
end $$;

grant execute on function public.sj_create_group(text)      to anon, authenticated;
grant execute on function public.sj_group_info(text)        to anon, authenticated;
grant execute on function public.sj_pull(text, bigint)      to anon, authenticated;
grant execute on function public.sj_push(text, jsonb)       to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Viewers on a table (added in version 2.1). Each phone that has a table open
-- checks in every 15 seconds; the app shows how many are watching.
create table if not exists public.sj_watch (
  group_id  uuid not null references public.sj_groups(id) on delete cascade,
  game_id   text not null,
  device    text not null,
  seen      bigint not null,
  constraint sj_watch_pkey primary key (group_id, game_id, device)
);
alter table public.sj_watch enable row level security;
revoke all on table public.sj_watch from anon, authenticated;

create or replace function public.sj_watch(p_code text, p_game text, p_device text)
returns table (game_id text, device text)
language plpgsql security definer set search_path = public
as $$
declare
  gid    uuid;
  now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  select g.id into gid from sj_groups g where g.code = upper(trim(p_code));
  if gid is null then
    raise exception 'Unknown group code';
  end if;
  delete from sj_watch w where w.group_id = gid and w.seen < now_ms - 600000;   -- forget phones gone for 10 minutes
  if p_device is not null and length(p_device) <= 60 then
    -- a phone watches one table at a time
    delete from sj_watch w where w.group_id = gid and w.device = p_device and (p_game is null or w.game_id <> p_game);
    if p_game is not null and length(p_game) <= 40 then
      insert into sj_watch as w (group_id, game_id, device, seen) values (gid, p_game, p_device, now_ms)
        on conflict on constraint sj_watch_pkey do update set seen = excluded.seen;
    end if;
  end if;
  return query select w.game_id, w.device from sj_watch w where w.group_id = gid and w.seen >= now_ms - 45000;
end $$;

grant execute on function public.sj_watch(text, text, text) to anon, authenticated;
