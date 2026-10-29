-- Tobacco Vape: update 2 (discounts, promo codes, customer accounts)
-- Run AFTER schema.sql, once, in Supabase > SQL Editor.

-- Product discount shown on the shop as a red badge
alter table public.products
  add column if not exists discount_percent int not null default 0
  check (discount_percent between 0 and 90);

-- Orders remember the promo code and the customer account (if signed in)
alter table public.orders add column if not exists promo_code text;
alter table public.orders add column if not exists user_id uuid references auth.users(id) on delete set null;
create index if not exists orders_user_id_idx on public.orders (user_id);

create policy "customers read own orders" on public.orders
  for select to authenticated using (user_id = (select auth.uid()));

-- Promo codes (admin only; customers can only test a code through check_promo)
create table public.promo_codes (
  code text primary key check (code = upper(code) and length(code) between 3 and 30),
  percent int not null check (percent between 1 and 90),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.promo_codes enable row level security;
grant select, insert, update, delete on public.promo_codes to authenticated;
create policy "admin manages promos" on public.promo_codes for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create or replace function public.check_promo(p_code text)
returns int language sql stable security definer set search_path = ''
as $$ select coalesce((select percent from public.promo_codes
        where code = upper(trim(p_code)) and active), 0) $$;
revoke all on function public.check_promo(text) from public;
grant execute on function public.check_promo(text) to anon, authenticated;

-- New place_order: product discounts + promo code, all calculated on the server
drop function if exists public.place_order(text, text, text, jsonb);

create function public.place_order(
  p_name text, p_phone text, p_address text, p_items jsonb, p_promo text default null
) returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  v_id bigint; it jsonb; p public.products; v_qty int; v_c numeric; v_unit numeric;
  v_sub numeric := 0; v_cost numeric := 0; v_pct int := 0;
begin
  if length(trim(p_name)) < 2 or length(trim(p_phone)) < 6 or length(trim(p_address)) < 5 then
    raise exception 'Enter a valid name, phone and address';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Your cart is empty';
  end if;
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select percent into v_pct from public.promo_codes where code = upper(trim(p_promo)) and active;
    if not found then raise exception 'This promo code is not valid'; end if;
  end if;
  insert into public.orders (customer_name, phone, address, promo_code, user_id)
  values (left(trim(p_name),100), left(trim(p_phone),30), left(trim(p_address),300),
          case when v_pct > 0 then upper(trim(p_promo)) end, (select auth.uid()))
  returning id into v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::int;
    select * into p from public.products where id = (it->>'id')::bigint for update;
    if not found or v_qty < 1 or p.stock < v_qty then
      raise exception 'Not enough stock for %', coalesce(p.name, 'this item');
    end if;
    update public.products set stock = stock - v_qty where id = p.id;
    select coalesce(max(cost), 0) into v_c from public.product_costs where product_id = p.id;
    v_unit := round(p.price * (100 - p.discount_percent) / 100, 2);
    insert into public.order_items (order_id, product_id, product_name, qty, unit_price)
    values (v_id, p.id, p.name, v_qty, v_unit);
    v_sub  := v_sub + v_unit * v_qty;
    v_cost := v_cost + v_c * v_qty;
  end loop;
  update public.orders
  set total = v_sub - round(v_sub * v_pct / 100, 2), cost = v_cost
  where id = v_id;
  return v_id;
end $$;

revoke all on function public.place_order(text,text,text,jsonb,text) from public;
grant execute on function public.place_order(text,text,text,jsonb,text) to anon, authenticated;
