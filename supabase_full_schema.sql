-- =========================================================================
-- الدشاش استور — قاعدة البيانات الكاملة (الطلبات، الباقات، المحافظ، الإيداعات)
-- شغّل هذا الملف مرة واحدة في Supabase -> SQL Editor
-- =========================================================================

-- 1. جدول الباقات
create table if not exists public.packages (
  id bigserial primary key,
  app_slug text not null default 'superlive',
  coins numeric(12,2) not null check (coins > 0),
  price_egp numeric(12,2) not null check (price_egp > 0),
  offer_group text not null default 'offer1',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 2. جدول الطلبات
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  customer_name text not null,
  phone text not null,
  superlive_id text not null,
  package_id bigint references public.packages(id) on delete set null,
  package_price numeric(12,2) not null,
  coins numeric(12,2) not null,
  payment_method text not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'shipped', 'rejected')),
  payment_proof text,
  admin_note text,
  created_at timestamptz not null default now()
);

-- 3. جدول محافظ العملاء
create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  user_email text,
  balance numeric(12,2) not null default 0.00 check (balance >= 0),
  updated_at timestamptz not null default now()
);

-- 4. جدول طلبات الإيداع
create table if not exists public.wallet_deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  user_email text,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null,
  proof_path text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

-- 5. جدول حركات المحفظة
create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  tx_type text not null check (tx_type in ('deposit', 'admin_credit', 'order_debit')),
  amount numeric(12,2) not null,
  description text,
  created_at timestamptz not null default now()
);

-- إنشاء محفظة تلقائية عند تسجيل أي مستخدم جديد
create or replace function public.handle_new_user_wallet()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.wallets (user_id, user_email, balance)
  values (new.id, new.email, 0.00)
  on conflict (user_id) do update set user_email = excluded.user_email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_wallet on auth.users;
create trigger on_auth_user_created_wallet
after insert on auth.users
for each row execute function public.handle_new_user_wallet();

insert into public.wallets (user_id, user_email, balance)
select id, email, 0.00 from auth.users
on conflict (user_id) do nothing;

-- دالة إضافة رصيد لمستخدم من الإدارة
create or replace function public.admin_add_wallet_balance(
  target_user_id uuid,
  add_amount numeric,
  note_text text default 'إضافة رصيد من الإدارة',
  deposit_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  new_bal numeric;
begin
  if add_amount is null or add_amount <= 0 then
    raise exception 'المبلغ يجب أن يكون أكبر من صفر';
  end if;

  insert into public.wallets (user_id, balance, updated_at)
  values (target_user_id, add_amount, now())
  on conflict (user_id)
  do update set
    balance = public.wallets.balance + add_amount,
    updated_at = now()
  returning balance into new_bal;

  insert into public.wallet_transactions (user_id, tx_type, amount, description)
  values (target_user_id, 'admin_credit', add_amount, coalesce(note_text, 'إضافة رصيد من الإدارة'));

  if deposit_id is not null then
    update public.wallet_deposits
    set status = 'approved',
        admin_note = coalesce(note_text, admin_note),
        reviewed_at = now()
    where id = deposit_id;
  end if;

  return new_bal;
end;
$$;

-- دالة الدفع من رصيد المحفظة وإنشاء طلب الشحن
drop function if exists public.pay_order_from_wallet(text, text, text, bigint, numeric, numeric);

create or replace function public.pay_order_from_wallet(
  p_customer_name text,
  p_phone text,
  p_superlive_id text,
  p_package_id bigint,
  p_package_price numeric,
  p_coins numeric
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cur_bal numeric;
  new_order_id text;
begin
  if uid is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  select balance into cur_bal from public.wallets where user_id = uid for update;
  if cur_bal is null or cur_bal < p_package_price then
    raise exception 'رصيد المحفظة غير كافٍ لإتمام الطلب';
  end if;

  update public.wallets
  set balance = balance - p_package_price,
      updated_at = now()
  where user_id = uid;

  insert into public.orders (
    user_id, customer_name, phone, superlive_id,
    package_id, package_price, coins, payment_method, status, payment_proof
  )
  values (
    uid, p_customer_name, p_phone, p_superlive_id,
    p_package_id, p_package_price, p_coins, 'رصيد المحفظة', 'paid', 'wallet_balance'
  )
  returning id::text into new_order_id;

  insert into public.wallet_transactions (user_id, tx_type, amount, description)
  values (uid, 'order_debit', -p_package_price, 'شراء باقة ' || p_coins || ' كوين (SuperLive)');

  return new_order_id;
end;
$$;

grant execute on function public.pay_order_from_wallet(text, text, text, bigint, numeric, numeric) to authenticated;

-- صلاحيات الوصول الأساسية
grant usage on schema public to anon, authenticated;
grant select on public.packages to anon, authenticated;
grant insert, update, delete on public.packages to authenticated;
grant select, insert, update on public.orders to authenticated;
grant select, insert, update on public.wallets to authenticated;
grant select, insert, update on public.wallet_deposits to authenticated;
grant select, insert on public.wallet_transactions to authenticated;

alter table public.packages enable row level security;
alter table public.orders enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_deposits enable row level security;
alter table public.wallet_transactions enable row level security;

drop policy if exists "packages_read_all" on public.packages;
create policy "packages_read_all" on public.packages for select using (true);

drop policy if exists "packages_manage_auth" on public.packages;
create policy "packages_manage_auth" on public.packages for all to authenticated using (true) with check (true);

drop policy if exists "orders_select_auth" on public.orders;
create policy "orders_select_auth" on public.orders for select to authenticated using (true);

drop policy if exists "orders_insert_own" on public.orders;
create policy "orders_insert_own" on public.orders for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "orders_update_auth" on public.orders;
create policy "orders_update_auth" on public.orders for update to authenticated using (true) with check (true);

drop policy if exists "wallets_select_auth" on public.wallets;
create policy "wallets_select_auth" on public.wallets for select to authenticated using (true);

drop policy if exists "wallets_insert_auth" on public.wallets;
create policy "wallets_insert_auth" on public.wallets for insert to authenticated with check (true);

drop policy if exists "deposits_select_auth" on public.wallet_deposits;
create policy "deposits_select_auth" on public.wallet_deposits for select to authenticated using (true);

drop policy if exists "deposits_insert_auth" on public.wallet_deposits;
create policy "deposits_insert_auth" on public.wallet_deposits for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "deposits_update_auth" on public.wallet_deposits;
create policy "deposits_update_auth" on public.wallet_deposits for update to authenticated using (true) with check (true);

drop policy if exists "tx_select_auth" on public.wallet_transactions;
create policy "tx_select_auth" on public.wallet_transactions for select to authenticated using (true);


-- تأكيد صلاحيات قراءة وتحديث الطلبات للأدمن المسجل
grant usage on schema public to authenticated;
grant select, insert, update on public.orders to authenticated;
alter table public.orders enable row level security;

drop policy if exists "orders_select_auth" on public.orders;
create policy "orders_select_auth" on public.orders
  for select to authenticated using (true);

drop policy if exists "orders_update_auth" on public.orders;
create policy "orders_update_auth" on public.orders
  for update to authenticated using (true) with check (true);


-- =========================================================================
-- تقييد صلاحيات الأدمن الحقيقية في قاعدة البيانات (RLS + is_admin)
-- =========================================================================

create table if not exists public.admin_users (
  email text primary key,
  created_at timestamptz not null default now()
);

grant select on public.admin_users to authenticated;
alter table public.admin_users enable row level security;

drop policy if exists "admin_users_read_auth" on public.admin_users;
create policy "admin_users_read_auth" on public.admin_users
  for select to authenticated using (true);

-- أضف بريد الأدمن الخاص بك هنا (مثال):
-- insert into public.admin_users (email) values ('your-admin-email@gmail.com') on conflict do nothing;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
    or exists (
      select 1
      from public.admin_users au
      where lower(au.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;

grant execute on function public.is_admin() to authenticated;

-- تأمين جدول الطلبات: العميل يرى طلباته فقط، والأدمن يرى ويحدث الكل
drop policy if exists "orders_select_auth" on public.orders;
drop policy if exists "orders_select_owner_or_admin" on public.orders;
create policy "orders_select_owner_or_admin" on public.orders
  for select to authenticated
  using (auth.uid() = user_id or public.is_admin());

drop policy if exists "orders_update_auth" on public.orders;
drop policy if exists "orders_update_admin_only" on public.orders;
create policy "orders_update_admin_only" on public.orders
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- تأمين طلبات الإيداع: العميل يرى إيداعاته فقط، والأدمن يرى ويحدث الكل
drop policy if exists "deposits_select_auth" on public.wallet_deposits;
drop policy if exists "deposits_select_owner_or_admin" on public.wallet_deposits;
create policy "deposits_select_owner_or_admin" on public.wallet_deposits
  for select to authenticated
  using (auth.uid() = user_id or public.is_admin());

drop policy if exists "deposits_update_auth" on public.wallet_deposits;
drop policy if exists "deposits_update_admin_only" on public.wallet_deposits;
create policy "deposits_update_admin_only" on public.wallet_deposits
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- تأمين الباقات: القراءة للجميع، والتعديل للأدمن فقط
drop policy if exists "packages_manage_auth" on public.packages;
drop policy if exists "packages_manage_admin_only" on public.packages;
create policy "packages_manage_admin_only" on public.packages
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- تأمين دالة إضافة الرصيد من الإدارة بحيث لا يستدعيها إلا الأدمن
create or replace function public.admin_add_wallet_balance(
  target_user_id uuid,
  add_amount numeric,
  note_text text default 'إضافة رصيد من الإدارة',
  deposit_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  new_bal numeric;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية متاحة للأدمن فقط';
  end if;

  if add_amount is null or add_amount <= 0 then
    raise exception 'المبلغ يجب أن يكون أكبر من صفر';
  end if;

  insert into public.wallets (user_id, balance, updated_at)
  values (target_user_id, add_amount, now())
  on conflict (user_id)
  do update set
    balance = public.wallets.balance + add_amount,
    updated_at = now()
  returning balance into new_bal;

  insert into public.wallet_transactions (user_id, tx_type, amount, description)
  values (target_user_id, 'admin_credit', add_amount, coalesce(note_text, 'إضافة رصيد من الإدارة'));

  if deposit_id is not null then
    update public.wallet_deposits
    set status = 'approved',
        admin_note = coalesce(note_text, admin_note),
        reviewed_at = now()
    where id = deposit_id;
  end if;

  return new_bal;
end;
$$;


-- =========================================================================
-- دالة سحب/خصم رصيد من محفظة مستخدم بواسطة الأدمن (admin_withdraw_wallet_balance)
-- =========================================================================
create or replace function public.admin_withdraw_wallet_balance(
  target_user_id uuid,
  withdraw_amount numeric,
  note_text text default 'سحب رصيد بواسطة الإدارة'
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  cur_bal numeric;
  new_bal numeric;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية متاحة للأدمن فقط';
  end if;

  if withdraw_amount is null or withdraw_amount <= 0 then
    raise exception 'المبلغ يجب أن يكون أكبر من صفر';
  end if;

  select balance into cur_bal from public.wallets where user_id = target_user_id for update;
  if cur_bal is null or cur_bal < withdraw_amount then
    raise exception 'رصيد المستخدم غير كافٍ لسحب هذا المبلغ';
  end if;

  update public.wallets
  set balance = balance - withdraw_amount,
      updated_at = now()
  where user_id = target_user_id
  returning balance into new_bal;

  insert into public.wallet_transactions (user_id, tx_type, amount, description)
  values (target_user_id, 'order_debit', -withdraw_amount, coalesce(note_text, 'سحب رصيد بواسطة الإدارة'));

  return new_bal;
end;
$$;

grant execute on function public.admin_withdraw_wallet_balance(uuid, numeric, text) to authenticated;
