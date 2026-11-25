-- Oud Prestance : schéma + logique serveur. À exécuter dans Supabase > SQL Editor.
create table products(id text primary key, name text not null, brand text not null, size text not null,
  price int not null check(price>=0), old_price int, stock int not null check(stock>=0), image text);
create table promo_codes(code text primary key, percent int not null check(percent between 1 and 90), active bool default true);
create table settings(key text primary key, value int not null);
create table admins(user_id uuid primary key references auth.users);
create table orders(
  id uuid primary key default gen_random_uuid(),
  reference text unique not null,
  status text not null default 'En attente de confirmation'
    check(status in ('En attente de confirmation','Confirmée','Annulée')),
  full_name text not null, phone text not null, city text not null, commune text not null,
  district text not null, address text not null, instructions text,
  items jsonb not null, original_total int not null, discount int not null default 0,
  delivery_fee int not null, total int not null, promo_code text,
  payment_mode text not null default 'Paiement à la livraison',
  created_at timestamptz default now());

alter table products enable row level security;
alter table promo_codes enable row level security;
alter table settings enable row level security;
alter table admins enable row level security;
alter table orders enable row level security;
create policy "lecture produits" on products for select using (true);
create policy "admin lit commandes" on orders for select to authenticated
  using (exists(select 1 from admins a where a.user_id=auth.uid()));
-- Aucune autre policy : le public ne lit ni n'écrit les commandes, codes promo, réglages.

-- DONNÉES À ADAPTER (prix, stock, frais, code promo sont des valeurs d'exemple)
insert into products values('liquid-brun','Liquid Brun','French Avenue','100 ml',17500,25000,12,'img/produit.jpg');
insert into settings values('delivery_fee',0);
insert into promo_codes values('BIENVENUE10',10,true);

create function check_promo(p_code text) returns int language sql security definer set search_path=public as
$$ select coalesce((select percent from promo_codes where code=upper(trim(p_code)) and active),0) $$;

create function place_order(p_items jsonb, p_customer jsonb, p_promo text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare it jsonb; p products; q int; orig int:=0; lines jsonb:='[]'; pct int:=0; disc int; fee int; tot int; ref text;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Panier vide'; end if;
  if length(trim(coalesce(p_customer->>'full_name','')))<3 or length(regexp_replace(coalesce(p_customer->>'phone',''),'\D','','g'))<8
     or coalesce(p_customer->>'city','')='' or coalesce(p_customer->>'commune','')=''
     or coalesce(p_customer->>'district','')='' or length(coalesce(p_customer->>'address',''))<5
  then raise exception 'Informations de livraison incomplètes'; end if;
  for it in select * from jsonb_array_elements(p_items) order by 1 loop
    q:=(it->>'qty')::int;
    if q<1 or q>10 then raise exception 'Quantité invalide'; end if;
    select * into p from products where id=it->>'id' for update;          -- verrou de ligne
    if not found then raise exception 'Produit introuvable'; end if;
    if p.stock<q then raise exception 'Stock insuffisant pour % (reste %)',p.name,p.stock; end if;
    update products set stock=stock-q where id=p.id;                        -- réservation atomique
    orig:=orig+p.price*q;
    lines:=lines||jsonb_build_object('id',p.id,'name',p.name,'brand',p.brand,'size',p.size,'qty',q,'unit_price',p.price,'old_price',p.old_price);
  end loop;
  if p_promo is not null and trim(p_promo)<>'' then
    pct:=check_promo(p_promo); if pct=0 then raise exception 'Code promo invalide'; end if;
  end if;
  disc:=round(orig*pct/100.0); select value into fee from settings where key='delivery_fee'; tot:=orig-disc+fee;
  loop
    ref:='OP-'||to_char(now(),'YYMMDD')||'-'||upper(substr(md5(random()::text),1,5));
    exit when not exists(select 1 from orders where reference=ref);
  end loop;
  insert into orders(reference,full_name,phone,city,commune,district,address,instructions,items,original_total,discount,delivery_fee,total,promo_code)
  values(ref,trim(p_customer->>'full_name'),trim(p_customer->>'phone'),p_customer->>'city',p_customer->>'commune',
    p_customer->>'district',p_customer->>'address',nullif(p_customer->>'instructions',''),lines,orig,disc,fee,tot,
    case when pct>0 then upper(trim(p_promo)) end);
  return jsonb_build_object('reference',ref,'items',lines,'original_total',orig,'discount',disc,'delivery_fee',fee,
    'total',tot,'promo',case when pct>0 then upper(trim(p_promo)) end,'payment_mode','Paiement à la livraison');
end $$;

create function admin_set_status(p_ref text, p_status text) returns void
language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb;
begin
  if not exists(select 1 from admins where user_id=auth.uid()) then raise exception 'Accès refusé'; end if;
  select * into o from orders where reference=p_ref for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if o.status='Annulée' then raise exception 'Commande déjà annulée'; end if;
  if p_status='Annulée' then
    for l in select * from jsonb_array_elements(o.items) loop
      update products set stock=stock+(l->>'qty')::int where id=l->>'id';  -- stock restitué
    end loop;
  elsif p_status<>'Confirmée' then raise exception 'Statut invalide'; end if;
  update orders set status=p_status where id=o.id;
end $$;

revoke all on function place_order, check_promo, admin_set_status from public;
grant execute on function place_order, check_promo to anon, authenticated;
grant execute on function admin_set_status to authenticated;
-- Après création de ton compte admin (Auth > Users) :
-- insert into admins values ('<UUID_DU_COMPTE>');
