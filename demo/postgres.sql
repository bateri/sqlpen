-- A small shop to look at: deterministic (setseed), a few hundred thousand rows, and a few
-- things a diagnostic tool should notice (an index nobody uses, a foreign key with no index,
-- dead rows that wait for a vacuum).
create extension if not exists pg_stat_statements;
select setseed(0.42);

create schema shop;
set search_path = shop, public;

create table customers (
  id         bigint generated always as identity primary key,
  email      text not null unique,
  name       text not null,
  country    text not null,
  created_at timestamptz not null
);

create table products (
  id         bigint generated always as identity primary key,
  sku        text not null unique,
  title      text not null,
  category   text not null,
  price      numeric(10, 2) not null,
  tags       text[] not null default '{}'
);

create type order_status as enum ('pending', 'paid', 'shipped', 'delivered', 'refunded');

create table orders (
  id          bigint generated always as identity primary key,
  customer_id bigint not null references customers,
  status      order_status not null,
  total       numeric(12, 2) not null default 0,
  placed_at   timestamptz not null
);

create table order_items (
  order_id   bigint not null references orders,
  product_id bigint not null references products, -- no index on purpose
  quantity   int not null,
  unit_price numeric(10, 2) not null,
  primary key (order_id, product_id)
);

create table events (
  id       bigint generated always as identity primary key,
  at       timestamptz not null,
  kind     text not null,
  payload  jsonb not null
);

insert into customers (email, name, country, created_at)
select 'user' || g || '@example.com',
       (array['Ada','Deniz','Ece','Mert','Selin','Kaan','Zeynep','Emre','Nil','Can'])[1 + g % 10]
         || ' ' || (array['Yılmaz','Kaya','Demir','Şahin','Çelik','Arslan','Doğan','Koç'])[1 + g % 8],
       (array['TR','DE','NL','US','GB','FR','JP','BR'])[1 + (random() * 7)::int],
       now() - (random() * interval '900 days')
from generate_series(1, 50000) g;

insert into products (sku, title, category, price, tags)
select 'SKU-' || lpad(g::text, 5, '0'),
       (array['Mug','Notebook','Lamp','Chair','Kettle','Backpack','Headphones','Desk'])[1 + g % 8] || ' #' || g,
       (array['home','office','audio','travel','kitchen'])[1 + g % 5],
       round((5 + random() * 495)::numeric, 2),
       array[(array['new','sale','eco','gift'])[1 + g % 4]]
from generate_series(1, 2000) g;

insert into orders (customer_id, status, placed_at)
select 1 + (random() * 49999)::int,
       (array['pending','paid','shipped','delivered','delivered','delivered','refunded'])[1 + (random() * 6)::int]::order_status,
       now() - (random() * interval '720 days')
from generate_series(1, 300000) g;

insert into order_items (order_id, product_id, quantity, unit_price)
select o.id, p.product_id, 1 + (random() * 3)::int, round((5 + random() * 495)::numeric, 2)
from orders o
cross join lateral (
  select distinct 1 + (random() * 1999 + o.id * 0)::int as product_id
  from generate_series(1, 1 + (o.id % 4)::int)
) p;

update orders o set total = s.sum
from (select order_id, sum(quantity * unit_price) as sum from order_items group by order_id) s
where s.order_id = o.id;

insert into events (at, kind, payload)
select now() - (random() * interval '30 days'),
       (array['view','cart','checkout','search','login'])[1 + g % 5],
       jsonb_build_object('session', md5(g::text), 'ms', (random() * 900)::int,
                          'path', '/p/' || (1 + g % 2000))
from generate_series(1, 200000) g;

-- An index nobody uses, and dead rows waiting for a vacuum.
create index orders_total_idx on orders (total);
alter table events set (autovacuum_enabled = false);
update events set kind = kind where id % 3 = 0;

create view revenue_by_month as
select date_trunc('month', placed_at) as month, count(*) as orders, sum(total) as revenue
from orders where status <> 'refunded'
group by 1 order by 1;

analyze;

-- The role a read-only tool connects as.
create role reader login password 'reader' in role pg_monitor;
grant usage on schema shop to reader;
grant select on all tables in schema shop to reader;
