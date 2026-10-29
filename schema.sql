-- Tobacco Vap: database schema for Supabase (Postgres)
-- Run this whole file once in Supabase > SQL Editor.

create schema if not exists private;

-- ---------- Tables ----------
create table public.products (
  id bigint generated always as identity primary key,
  name text not null,
  category text not null,
  price numeric(10,2) not null check (price >= 0),
  stock int not null default 0 check (stock >= 0),
  created_at timestamptz not null default now()
);

-- Cost is kept in its own table so customers can never read it.
create table public.product_costs (
  product_id bigint primary key references public.products(id) on delete cascade,
  cost numeric(10,2) not null default 0 check (cost >= 0)
);

create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table public.orders (
  id bigint generated always as identity primary key,
  customer_name text not null,
  phone text not null,
  address text not null,
  total numeric(10,2) not null default 0,
  cost numeric(10,2) not null default 0,
  status text not null default 'New' check (status in ('New','Confirmed','Delivered','Cancelled')),
  created_at timestamptz not null default now()
);

create table public.order_items (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  product_id bigint references public.products(id) on delete set null,
  product_name text not null,
  qty int not null check (qty > 0),
  unit_price numeric(10,2) not null
);

create table public.chat_messages (
  id bigint generated always as identity primary key,
  session_id text not null check (length(session_id) between 6 and 40),
  sender text not null check (sender in ('c','s')),  -- c = customer, s = staff
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index on public.order_items (order_id);
create index on public.orders (created_at desc);
create index on public.chat_messages (session_id, created_at);

-- ---------- Admin check ----------
create function private.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.admins where user_id = (select auth.uid())) $$;

revoke all on function private.is_admin() from public;
grant usage on schema private to authenticated;
grant execute on function private.is_admin() to authenticated;

-- ---------- Row level security ----------
alter table public.products      enable row level security;
alter table public.product_costs enable row level security;
alter table public.admins        enable row level security;
alter table public.orders        enable row level security;
alter table public.order_items   enable row level security;
alter table public.chat_messages enable row level security;

grant select on public.products to anon, authenticated;
grant select, insert, update, delete on
  public.products, public.product_costs, public.orders, public.order_items, public.chat_messages
  to authenticated;
grant select on public.admins to authenticated;

create policy "anyone reads products" on public.products for select to anon, authenticated using (true);
create policy "admin writes products" on public.products for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy "admin manages costs" on public.product_costs for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy "admin manages orders" on public.orders for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy "admin manages order items" on public.order_items for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy "admin manages chat" on public.chat_messages for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy "read own admin row" on public.admins for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------- Public functions for customers ----------
-- Customers get NO direct table access. These functions are the only way in.
-- SECURITY DEFINER is intentional here: prices and stock are read from the database,
-- never trusted from the browser.

create function public.place_order(p_name text, p_phone text, p_address text, p_items jsonb)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  v_id bigint; it jsonb; p public.products; v_qty int; v_c numeric;
  v_total numeric := 0; v_cost numeric := 0;
begin
  if length(trim(p_name)) < 2 or length(trim(p_phone)) < 6 or length(trim(p_address)) < 5 then
    raise exception 'Enter a valid name, phone and address';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Your cart is empty';
  end if;
  insert into public.orders (customer_name, phone, address)
  values (left(trim(p_name),100), left(trim(p_phone),30), left(trim(p_address),300))
  returning id into v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::int;
    select * into p from public.products where id = (it->>'id')::bigint for update;
    if not found or v_qty < 1 or p.stock < v_qty then
      raise exception 'Not enough stock for %', coalesce(p.name, 'this item');
    end if;
    update public.products set stock = stock - v_qty where id = p.id;
    select coalesce(max(cost), 0) into v_c from public.product_costs where product_id = p.id;
    insert into public.order_items (order_id, product_id, product_name, qty, unit_price)
    values (v_id, p.id, p.name, v_qty, p.price);
    v_total := v_total + p.price * v_qty;
    v_cost  := v_cost + v_c * v_qty;
  end loop;
  update public.orders set total = v_total, cost = v_cost where id = v_id;
  return v_id;
end $$;

create function public.send_chat(p_session text, p_body text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.chat_messages (session_id, sender, body)
  values (p_session, 'c', left(trim(p_body), 1000));
end $$;

create function public.get_chat(p_session text)
returns table (sender text, body text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select m.sender, m.body, m.created_at from public.chat_messages m
  where m.session_id = p_session order by m.created_at limit 200
$$;

revoke all on function public.place_order(text,text,text,jsonb) from public;
revoke all on function public.send_chat(text,text) from public;
revoke all on function public.get_chat(text) from public;
grant execute on function public.place_order(text,text,text,jsonb) to anon, authenticated;
grant execute on function public.send_chat(text,text) to anon, authenticated;
grant execute on function public.get_chat(text) to anon, authenticated;

-- ---------- Sample products (edit or delete) ----------
with p as (
  insert into public.products (name, category, price, stock) values
    ('Pod Kit Pro 30W','Pods',1450,12),
    ('Slim Pod Starter','Pods',850,20),
    ('Box Mod 100W','Devices',2300,6),
    ('Mango Ice 60ml Salt','E-liquid',200,40),
    ('Tobacco Gold 60ml','E-liquid',220,3),
    ('Replacement Coils x5','Accessories',180,0)
  returning id, name
)
insert into public.product_costs (product_id, cost)
select id, case name when 'Pod Kit Pro 30W' then 1100 when 'Slim Pod Starter' then 600
  when 'Box Mod 100W' then 1750 when 'Mango Ice 60ml Salt' then 120
  when 'Tobacco Gold 60ml' then 130 else 90 end from p;

-- ---------- Make yourself admin ----------
-- 1) Supabase > Authentication > Users > Add user (your email + a strong password)
-- 2) Then run this with your email:
-- insert into public.admins (user_id) select id from auth.users where email = 'you@example.com';
