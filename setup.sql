-- Run in Supabase SQL Editor as project administrator. Existing data is retained.
begin;
alter table public.profiles add column if not exists admission_year integer;
alter table public.profiles add column if not exists year_override integer;
alter table public.profiles add column if not exists member_status text not null default 'active';
alter table public.profiles add constraint profiles_admission_year_range check (admission_year between 1950 and 2100);
alter table public.profiles add constraint profiles_year_override_range check (year_override between 1 and 20);
alter table public.profiles add constraint profiles_member_status_check check (member_status in ('active','alumni'));
-- If these constraints already exist, remove the three 'add constraint' lines on rerun.

create table if not exists public.site_admins (
 user_id uuid primary key references auth.users(id) on delete cascade,
 assigned_at timestamptz not null default now()
);
create table if not exists public.circle_president (
 singleton boolean primary key default true check (singleton),
 user_id uuid not null references auth.users(id),
 assigned_at timestamptz not null default now()
);
create table if not exists public.president_transfers (
 id bigint generated always as identity primary key,
 from_user uuid references auth.users(id),
 to_user uuid not null references auth.users(id),
 status text not null default 'pending' check(status in ('pending','accepted','cancelled')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);
create table if not exists public.circle_roles (
 id bigint generated always as identity primary key,
 name text not null unique,
 exclude_from_staff_auto_assign boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.user_roles (
 user_id uuid not null references auth.users(id) on delete cascade,
 role_id bigint not null references public.circle_roles(id) on delete cascade,
 primary key(user_id,role_id)
);
create table if not exists public.admission_year_requests (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 requested_year integer not null check(requested_year between 1950 and 2100),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 reviewed_at timestamptz
);
create unique index if not exists one_pending_year_request on public.admission_year_requests(user_id) where status='pending';

create or replace function public.is_circle_president() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.circle_president where singleton=true and user_id=(select auth.uid()));
$$;
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.site_admins where user_id=(select auth.uid()));
$$;

-- Disable direct writes to privilege-bearing tables; all changes via checked RPCs.
revoke all on public.site_admins,public.circle_president,public.president_transfers,public.circle_roles,public.user_roles,public.admission_year_requests from anon,authenticated;
revoke insert,update,delete on public.profiles from anon,authenticated;
-- Existing profile SELECT policies are kept; do not expose privileged tables directly.
alter table public.site_admins enable row level security;
alter table public.circle_president enable row level security;
alter table public.president_transfers enable row level security;
alter table public.circle_roles enable row level security;
alter table public.user_roles enable row level security;
alter table public.admission_year_requests enable row level security;

create or replace function public.profile_context()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.profiles%rowtype;
begin
 if u is null then raise exception 'ログインしてください'; end if;
 select * into p from public.profiles where id=u;
 return jsonb_build_object('profile',to_jsonb(p),'is_president',public.is_circle_president(), 'is_site_admin',public.is_site_admin(),
  'pending_year', (select requested_year from public.admission_year_requests where user_id=u and status='pending' limit 1),
  'pending_transfer_to', (select to_user from public.president_transfers where from_user=u and status='pending' order by id desc limit 1),
  'incoming_transfer_id', (select id from public.president_transfers where to_user=u and status='pending' order by id desc limit 1));
end $$;

create or replace function public.update_my_profile(p_username text, p_admission_year integer default null)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); old_year integer;
begin
 if u is null then raise exception 'ログインしてください'; end if;
 if length(btrim(coalesce(p_username,''))) not between 1 and 60 then raise exception 'ユーザー名は1〜60文字にしてください'; end if;
 select admission_year into old_year from public.profiles where id=u for update;
 if not found then raise exception 'プロフィールが見つかりません'; end if;
 if p_admission_year is not null and (p_admission_year < 1950 or p_admission_year > 2100) then raise exception '入学年度が不正です'; end if;
 if old_year is not null and p_admission_year is distinct from old_year then raise exception '入学年度の変更には承認が必要です'; end if;
 update public.profiles set username=btrim(p_username),admission_year=coalesce(old_year,p_admission_year) where id=u;
end $$;

create or replace function public.request_admission_year(p_year integer)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); current_year integer;
begin