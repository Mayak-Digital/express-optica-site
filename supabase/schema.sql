-- Экспресс Оптика CRM — база данных (Supabase / PostgreSQL)
-- Таблицы: сотрудники с доступом, заказы-квитанции, настройки (прайс линз и списки).
-- Доступ: только вошедшие пользователи, которым выдан доступ в crm_staff. Посторонние не видят ничего.

create table if not exists public.crm_staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'staff' check (role in ('admin','staff')),
  name       text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.crm_orders (
  num        integer primary key check (num > 0),
  data       jsonb not null default '{}'::jsonb,
  phone      text not null default '',
  name       text not null default '',
  status     text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);
create index if not exists crm_orders_phone_idx on public.crm_orders (phone);

create table if not exists public.crm_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- Роль текущего пользователя: 'admin', 'staff' или null (нет доступа)
create or replace function public.crm_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.crm_staff where user_id = auth.uid()
$$;

alter table public.crm_staff    enable row level security;
alter table public.crm_orders   enable row level security;
alter table public.crm_settings enable row level security;

revoke all on public.crm_staff, public.crm_orders, public.crm_settings from anon;
grant usage on schema public to authenticated;
grant select on public.crm_staff, public.crm_orders, public.crm_settings to authenticated;

drop policy if exists crm_staff_read on public.crm_staff;
create policy crm_staff_read on public.crm_staff for select to authenticated
  using (user_id = auth.uid() or public.crm_role() = 'admin');

drop policy if exists crm_orders_read on public.crm_orders;
create policy crm_orders_read on public.crm_orders for select to authenticated
  using (public.crm_role() is not null);

drop policy if exists crm_settings_read on public.crm_settings;
create policy crm_settings_read on public.crm_settings for select to authenticated
  using (public.crm_role() is not null);
-- Запись идёт только через функции ниже (они сами проверяют права).

-- Сохранить заказ. p_prev — прежний номер, если заказ перенумеровали.
create or replace function public.crm_save_order(p_num integer, p_prev integer, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.crm_role();
  v_old  public.crm_orders%rowtype;
  v_has  boolean;
  v_who  text;
  v_data jsonb;
begin
  if v_role is null then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_num is null or p_num < 1 then raise exception 'bad_number'; end if;
  if p_order is null or jsonb_typeof(p_order) <> 'object' or length(p_order::text) > 60000 then raise exception 'bad_order'; end if;
  if (p_prev is null or p_prev <> p_num) and exists (select 1 from public.crm_orders where num = p_num) then
    raise exception 'exists' using errcode = '23505';
  end if;

  select * into v_old from public.crm_orders where num = coalesce(p_prev, p_num);
  v_has := found;
  select coalesce(nullif(s.name, ''), u.email) into v_who
    from public.crm_staff s join auth.users u on u.id = s.user_id where s.user_id = auth.uid();

  v_data := (p_order - '_pending') || jsonb_build_object(
    'num', p_num,
    'updatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'updatedBy', coalesce(v_who, ''));
  if v_has then
    v_data := v_data || jsonb_build_object(
      'createdAt', coalesce(v_old.data->>'createdAt', p_order->>'createdAt', ''),
      'createdBy', coalesce(v_old.data->>'createdBy', ''));
  else
    v_data := v_data || jsonb_build_object('createdBy', coalesce(v_who, ''));
  end if;

  if p_prev is not null and p_prev <> p_num then
    delete from public.crm_orders where num = p_prev;
  end if;

  insert into public.crm_orders (num, data, phone, name, status, created_at, updated_at, created_by, updated_by)
  values (p_num, v_data, coalesce(v_data->>'phone', ''), coalesce(v_data->>'name', ''), coalesce(v_data->>'status', ''),
          case when v_has then v_old.created_at else now() end, now(),
          case when v_has then v_old.created_by else auth.uid() end, auth.uid())
  on conflict (num) do update set
    data = excluded.data, phone = excluded.phone, name = excluded.name, status = excluded.status,
    updated_at = now(), updated_by = auth.uid();
  return v_data;
end $$;

create or replace function public.crm_delete_order(p_num integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.crm_role() is distinct from 'admin' then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from public.crm_orders where num = p_num;
end $$;

create or replace function public.crm_save_lists(p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.crm_role() is distinct from 'admin' then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' then raise exception 'bad_value'; end if;
  insert into public.crm_settings (key, value, updated_at) values ('lists', p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

create or replace function public.crm_list_staff()
returns table (user_id uuid, email text, name text, role text)
language plpgsql security definer set search_path = public as $$
begin
  if public.crm_role() is distinct from 'admin' then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select s.user_id, u.email::text, s.name, s.role
    from public.crm_staff s join auth.users u on u.id = s.user_id order by s.created_at;
end $$;

create or replace function public.crm_add_staff(p_email text, p_role text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if public.crm_role() is distinct from 'admin' then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_role not in ('admin', 'staff') then raise exception 'bad_role'; end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then raise exception 'not_found'; end if;
  insert into public.crm_staff (user_id, role, name) values (v_id, p_role, coalesce(p_name, ''))
  on conflict (user_id) do update set role = excluded.role, name = case when excluded.name <> '' then excluded.name else public.crm_staff.name end;
end $$;

create or replace function public.crm_remove_staff(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.crm_role() is distinct from 'admin' then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'cannot_remove_self'; end if;
  delete from public.crm_staff where user_id = p_user;
end $$;

revoke execute on function public.crm_role(), public.crm_save_order(integer, integer, jsonb), public.crm_delete_order(integer),
  public.crm_save_lists(jsonb), public.crm_list_staff(), public.crm_add_staff(text, text, text), public.crm_remove_staff(uuid) from public, anon;
grant execute on function public.crm_role(), public.crm_save_order(integer, integer, jsonb), public.crm_delete_order(integer),
  public.crm_save_lists(jsonb), public.crm_list_staff(), public.crm_add_staff(text, text, text), public.crm_remove_staff(uuid) to authenticated;

-- Начальные данные: прайс линз и списки (только если ещё нет)
insert into public.crm_settings (key, value) values ('lists', $json${"lenses": [{"name": "1.5 Линзы без покрытия CR-39", "prices": {"Италия": 2900, "Корея": 2300, "Франция": 3400}}, {"name": "1.5 С упрочняющим покрытием (HC)", "prices": {"Италия": 3900, "Корея": 2900, "Франция": 3900}}, {"name": "1.56 С мультипокрытием (Антиблик) (HMC)", "prices": {"Италия": 4900, "Корея": 3900, "Франция": 5900}}, {"name": "1.56 Компьютерные линзы (HMC/EMI)", "prices": {"Италия": 9900, "Корея": 5400, "Франция": 11900}}, {"name": "1.6 Компьютерные линзы (HMC/EMI) тонкая", "prices": {"Италия": 14900, "Корея": 8900, "Франция": 18900}}, {"name": "1.67 Компьютерные линзы (HMC/EMI) очень тонкая", "prices": {"Италия": 22900, "Корея": 15500, "Франция": 33400}}, {"name": "1.61 AS (HMC) Асферическая тонкая линза", "prices": {"Италия": 12900, "Корея": 7900, "Франция": 15400}}, {"name": "1.67 AS (HMC) Асферическая очень тонкая линза", "prices": {"Италия": 19900, "Корея": 13900, "Франция": 22600}}, {"name": "1.74 AS (HMC) Асферическая сверхтонкая линза", "prices": {"Италия": 28900, "Корея": 22900, "Франция": 32900}}, {"name": "1.56 Фотохромные линзы (серый и коричневый) HMC", "prices": {"Италия": 11900, "Корея": 8900, "Франция": 13900}}, {"name": "1.61 Фотохромные линзы (серый и коричневый) HMC", "prices": {"Италия": 22900, "Корея": 15400, "Франция": 35400}}, {"name": "1.67 Фотохромные линзы (серый и коричневый) HMC", "prices": {"Италия": 33000, "Корея": 24500, "Франция": 48900}}, {"name": "1.74 Фотохромные линзы (серый и коричневый) HMC", "prices": {"Италия": 45000, "Корея": 30000, "Франция": 59900}}, {"name": "1.61 Фотохромные Blue Blocker (серый и коричневый)", "prices": {"Италия": 29000, "Корея": 18000, "Франция": 39000}}, {"name": "1.56 Антифог (Antifog) антизапотевающие", "prices": {"Италия": 15000, "Корея": 9000, "Франция": 19000}}, {"name": "1.6 Антифог (Antifog) антизапотевающие - до 6", "prices": {"Италия": 22000, "Корея": 13000, "Франция": 29000}}, {"name": "1.5 Бифокальные линзы (HC)", "prices": {"Италия": 13900, "Корея": 7900, "Франция": 18400}}, {"name": "1.56 Бифокальные линзы (Антиблик) (HMC)", "prices": {"Италия": 14900, "Корея": 9900, "Франция": 19900}}, {"name": "1.56 Бифокальные фотохромные линзы HMC", "prices": {"Италия": 35000, "Корея": 21600, "Франция": 39900}}, {"name": "1.5 Поляризационные линзы (HC)", "prices": {"Италия": 12200, "Корея": 6900, "Франция": 16000}}, {"name": "1.5 Поляризационные линзы (Антиблик) (HMC)", "prices": {"Италия": 14200, "Корея": 8900, "Франция": 18900}}, {"name": "1.56 Поляризационные фотохромные линзы 0 до -4.0", "prices": {"Италия": 19800, "Корея": 15500, "Франция": 25000}}, {"name": "1.59 Поликарбонат (сверхпрочные линзы) (HMC)", "prices": {"Италия": 15900, "Корея": 9900, "Франция": 18900}}, {"name": "1.59 Прогрессивные линзы Поликарбонат", "prices": {"Италия": 80000, "Корея": 60000, "Франция": 98900}}, {"name": "1.5 Прогрессивные линзы (HC)", "prices": {"Италия": 40000, "Корея": 30000, "Франция": 50000}}, {"name": "1.5 Прогрессивные линзы с мультипокрытием", "prices": {"Италия": 45000, "Корея": 35000, "Франция": 55000}}, {"name": "1.6 Прогрессивные линзы с мультипокрытием", "prices": {"Италия": 60000, "Корея": 50000, "Франция": 70000}}, {"name": "1.5 Прогрессивные фотохромные линзы с HMC/EMI", "prices": {"Италия": 70000, "Корея": 55000, "Франция": 90000}}, {"name": "1.6 Прогрессивные фотохромные линзы с HMC/EMI", "prices": {"Италия": 85000, "Корея": 65000, "Франция": 110000}}, {"name": "1.67 Прогрессивные фотохромные линзы с HMC/EMI", "prices": {"Италия": 100000, "Корея": 80000, "Франция": 120000}}, {"name": "1.5 Офисные линзы с мультипокрытием (HMC)", "prices": {"Италия": 18900, "Корея": 12500, "Франция": 22900}}, {"name": "1.56 Линзы с мультипокрытием с тонировкой (15%)", "prices": {"Италия": 11900, "Корея": 7900, "Франция": 14900}}, {"name": "1.5 Окрашенные линзы (Тонировка)", "prices": {"Италия": 9900, "Корея": 6900, "Франция": 13400}}, {"name": "1.5 Стекло без покрытия", "prices": {"Италия": 8500, "Корея": 5500, "Франция": 9900}}, {"name": "1.5 Стекло с мультипокрытием (HMC)", "prices": {"Италия": 9900, "Корея": 6500, "Франция": 12900}}, {"name": "1.7 Стекло с мультипокрытием (HMC)", "prices": {"Италия": 14500, "Корея": 9500, "Франция": 16000}}], "makers": ["Корея", "Италия", "Франция"], "purposes": ["Для дали", "Для близи", "Для постоянного ношения", "Для работы за ПК"], "sources": ["Рецепт салона", "Рецепт заказчика", "По старым очкам", "Со слов заказчика"], "tints": ["Серый", "Коричневый"]}$json$::jsonb) on conflict (key) do nothing;
