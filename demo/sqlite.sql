-- The database of `sqlpen --demo`: a small shop, made where it is opened (in memory), the same each
-- time. The numbers are drawn from the rows' own numbers, not from random(), so that a screenshot
-- shows the same rows tomorrow.
create table customers (
  id         integer primary key,
  email      text not null unique,
  name       text not null,
  country    text not null,
  created_at text not null
);

create table products (
  id       integer primary key,
  sku      text not null unique,
  title    text not null,
  category text not null,
  price    real not null,
  tags     text not null default '[]'
);

create table orders (
  id          integer primary key,
  customer_id integer not null references customers(id),
  status      text not null check (status in ('pending', 'paid', 'shipped', 'delivered', 'refunded')),
  total       real not null default 0,
  placed_at   text not null
);

create table order_items (
  order_id   integer not null references orders(id),
  product_id integer not null references products(id),
  quantity   integer not null,
  unit_price real not null,
  primary key (order_id, product_id)
);

create table events (
  id      integer primary key,
  at      text not null,
  kind    text not null,
  payload text not null
);

with recursive n(g) as (select 1 union all select g + 1 from n where g < 2000)
insert into customers (email, name, country, created_at)
select 'user' || g || '@example.com',
       (case g % 10 when 0 then 'Ada' when 1 then 'Deniz' when 2 then 'Ece' when 3 then 'Mert'
         when 4 then 'Selin' when 5 then 'Kaan' when 6 then 'Zeynep' when 7 then 'Emre'
         when 8 then 'Nil' else 'Can' end)
       || ' ' ||
       (case g % 8 when 0 then 'Yılmaz' when 1 then 'Kaya' when 2 then 'Demir' when 3 then 'Şahin'
         when 4 then 'Çelik' when 5 then 'Arslan' when 6 then 'Doğan' else 'Koç' end),
       (case (g * 7) % 8 when 0 then 'TR' when 1 then 'DE' when 2 then 'NL' when 3 then 'US'
         when 4 then 'GB' when 5 then 'FR' when 6 then 'JP' else 'BR' end),
       date('2024-01-01', '+' || ((g * 37) % 900) || ' days')
from n;

with recursive n(g) as (select 1 union all select g + 1 from n where g < 200)
insert into products (sku, title, category, price, tags)
select printf('SKU-%05d', g),
       (case g % 8 when 0 then 'Mug' when 1 then 'Notebook' when 2 then 'Lamp' when 3 then 'Chair'
         when 4 then 'Kettle' when 5 then 'Backpack' when 6 then 'Headphones' else 'Desk' end) || ' #' || g,
       (case g % 5 when 0 then 'home' when 1 then 'office' when 2 then 'audio' when 3 then 'travel'
         else 'kitchen' end),
       round(5 + ((g * 7919) % 49500) / 100.0, 2),
       '["' || (case g % 4 when 0 then 'new' when 1 then 'sale' when 2 then 'eco' else 'gift' end) || '"]'
from n;

with recursive n(g) as (select 1 union all select g + 1 from n where g < 20000)
insert into orders (customer_id, status, placed_at)
select 1 + (g * 7919) % 2000,
       (case (g * 13) % 7 when 0 then 'pending' when 1 then 'paid' when 2 then 'shipped'
         when 6 then 'refunded' else 'delivered' end),
       datetime('2024-06-01', '+' || ((g * 104729) % 720) || ' days', '+' || (g % 86400) || ' seconds')
from n;

with recursive n(k) as (select 0 union all select k + 1 from n where k < 3)
insert or ignore into order_items (order_id, product_id, quantity, unit_price)
select o.id, 1 + (o.id * 31 + n.k * 97) % 200, 1 + (o.id + n.k) % 3,
       round(5 + ((o.id * 131 + n.k * 17) % 49500) / 100.0, 2)
from orders o join n on n.k <= o.id % 4;

update orders set total = (
  select round(sum(quantity * unit_price), 2) from order_items where order_id = orders.id
);

with recursive n(g) as (select 1 union all select g + 1 from n where g < 5000)
insert into events (at, kind, payload)
select datetime('2026-09-26', '+' || (g * 523 % 2592000) || ' seconds'),
       (case g % 5 when 0 then 'view' when 1 then 'cart' when 2 then 'checkout' when 3 then 'search'
         else 'login' end),
       json_object('session', lower(hex(g * 2654435761)), 'ms', (g * 37) % 900, 'path', '/p/' || (1 + g % 200))
from n;

create index orders_customer on orders (customer_id);

create view revenue_by_month as
select strftime('%Y-%m', placed_at) as month, count(*) as orders, round(sum(total), 2) as revenue
from orders where status <> 'refunded'
group by 1 order by 1;

analyze;
