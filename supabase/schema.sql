-- =====================================================================
-- Vale Black Nashy · banco de dados (Supabase / Postgres)
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em Run.
-- Pode rodar de novo sem problema: ele não apaga dados existentes.
-- =====================================================================

-- ---------- Configurações (uma linha só) ----------
create table if not exists settings (
  id            int primary key default 1 check (id = 1),
  sales_start   date    not null default '2026-11-07',
  sales_end     date    not null default '2026-11-27',
  daily_limit   int     not null default 30,
  vale_value    numeric(10,2) not null default 200,
  bonus_value   numeric(10,2) not null default 50,
  pix_key       text    not null default '',
  pix_name      text    not null default '',
  pix_city      text    not null default 'BELO HORIZONTE',
  whatsapp      text    not null default '5511915472199',
  site_url      text    not null default ''
);
insert into settings (id) values (1) on conflict do nothing;

-- ---------- Quem é admin e quem é unidade ----------
create table if not exists profiles (
  user_id   uuid primary key,
  role      text not null check (role in ('admin','unit')),
  unit_name text
);

-- ---------- Feriados (o bônus não vale nesses dias) ----------
create table if not exists holidays (day date primary key, name text);
insert into holidays values
  ('2026-11-15','Proclamação da República'),
  ('2026-11-20','Consciência Negra'),
  ('2026-12-08','Imaculada Conceição (BH)'),
  ('2026-12-25','Natal'),
  ('2027-01-01','Confraternização Universal'),
  ('2027-02-08','Carnaval'),
  ('2027-02-09','Carnaval'),
  ('2027-02-10','Quarta-feira de Cinzas')
on conflict do nothing;

-- ---------- Pedidos ----------
create table if not exists orders (
  id           bigserial primary key,
  created_at   timestamptz not null default now(),
  sale_day     date not null,
  nome         text not null,
  telefone     text not null,
  aniversario  text not null,
  unidade_pref text not null,
  qty          int  not null check (qty between 1 and 4),
  optin        boolean not null default false,
  status       text not null default 'pendente'
               check (status in ('pendente','aprovado','recusado','cancelado')),
  decided_at   timestamptz,
  note         text
);
create index if not exists orders_day_idx on orders(sale_day, status);
alter table orders add column if not exists receipt_path text;   -- comprovante do Pix (Storage)

-- ---------- Vales ----------
create table if not exists vouchers (
  id               uuid primary key default gen_random_uuid(),
  code             text unique not null,
  token            text unique not null,
  order_id         bigint references orders(id),
  nome             text not null,
  telefone         text not null,
  approved_at      timestamptz not null default now(),
  expires_on       date not null,
  bonus_expires_on date not null,
  saldo            numeric(10,2) not null,
  cortesia_tipo    text,
  cortesia_item    text,
  cortesia_day     date,
  bonus_day        date,
  last_vale_day    date,
  status           text not null default 'ativo' check (status in ('ativo','cancelado'))
);

-- ---------- Usos nas unidades ----------
create table if not exists redemptions (
  id            bigserial primary key,
  voucher_id    uuid not null references vouchers(id),
  created_at    timestamptz not null default now(),
  day           date not null,
  unit          text not null,
  atendente     text not null,
  comanda       text not null,
  valor         numeric(10,2) not null default 0,
  cortesia_tipo text,
  cortesia_item text,
  bonus         boolean not null default false,
  undone_at     timestamptz
);

-- ---------- Funções auxiliares ----------
create or replace function today_br() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from profiles where user_id = auth.uid() $$;

create or replace function my_unit() returns text
language sql stable security definer set search_path = public as
$$ select unit_name from profiles where user_id = auth.uid() $$;

create or replace function unit_name_now() returns text
language sql stable security definer set search_path = public as
$$ select coalesce(my_unit(), 'Admin') $$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(my_role() = 'admin', false) $$;

-- ---------- Segurança: ninguém lê as tabelas direto, só a admin ----------
alter table settings    enable row level security;
alter table profiles    enable row level security;
alter table holidays    enable row level security;
alter table orders      enable row level security;
alter table vouchers    enable row level security;
alter table redemptions enable row level security;

drop policy if exists admin_all on settings;    create policy admin_all on settings    for all using (is_admin()) with check (is_admin());
drop policy if exists admin_all on holidays;    create policy admin_all on holidays    for all using (is_admin()) with check (is_admin());
drop policy if exists admin_all on orders;      create policy admin_all on orders      for select using (is_admin());
drop policy if exists admin_all on vouchers;    create policy admin_all on vouchers    for select using (is_admin());
drop policy if exists admin_all on redemptions; create policy admin_all on redemptions for select using (is_admin());
drop policy if exists me on profiles;           create policy me on profiles           for select using (user_id = auth.uid());

-- =====================================================================
-- PÚBLICO (página de vendas e link do vale)
-- =====================================================================

-- Situação das vendas: aberta? quantos vales restam hoje?
create or replace function sales_status() returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; used int; d date := today_br();
begin
  select * into s from settings where id = 1;
  select coalesce(sum(qty),0) into used from orders
   where sale_day = d and (status = 'aprovado' or (status = 'pendente' and created_at > now() - interval '3 hours'));
  return json_build_object(
    'open', d between s.sales_start and s.sales_end and used < s.daily_limit,
    'before', d < s.sales_start, 'after', d > s.sales_end,
    'remaining', greatest(s.daily_limit - used, 0), 'limit', s.daily_limit,
    'start', s.sales_start, 'end', s.sales_end,
    'pix_key', s.pix_key, 'pix_name', s.pix_name, 'pix_city', s.pix_city,
    'whatsapp', s.whatsapp, 'vale_value', s.vale_value);
end $$;

-- Cliente faz o pedido
create or replace function create_order(p_nome text, p_tel text, p_aniv text, p_unid text,
                                        p_qty int, p_optin boolean, p_lgpd boolean)
returns json language plpgsql security definer set search_path = public as $$
declare s settings; used int; d date := today_br(); tel text; new_id bigint;
begin
  if not coalesce(p_lgpd,false) then raise exception 'ACEITE_OBRIGATORIO'; end if;
  if length(trim(coalesce(p_nome,''))) < 3 then raise exception 'NOME_INVALIDO'; end if;
  tel := regexp_replace(coalesce(p_tel,''), '\D', '', 'g');
  if length(tel) not between 10 and 13 then raise exception 'TELEFONE_INVALIDO'; end if;
  if p_qty is null or p_qty not between 1 and 4 then raise exception 'QUANTIDADE_INVALIDA'; end if;
  if p_unid not in ('Savassi','Lourdes','São Pedro','Contagem') then raise exception 'UNIDADE_INVALIDA'; end if;

  perform pg_advisory_xact_lock(4242);          -- uma venda por vez, para não passar do limite
  select * into s from settings where id = 1;
  if d < s.sales_start or d > s.sales_end then raise exception 'FORA_DO_PERIODO'; end if;
  if exists (select 1 from orders where telefone = tel and status = 'pendente' and sale_day = d) then
    raise exception 'PEDIDO_PENDENTE';           -- evita alguém segurar vários lotes
  end if;
  select coalesce(sum(qty),0) into used from orders
   where sale_day = d and (status = 'aprovado' or (status = 'pendente' and created_at > now() - interval '3 hours'));
  if used + p_qty > s.daily_limit then
    raise exception 'ESGOTADO_HOJE:%', greatest(s.daily_limit - used, 0);
  end if;

  insert into orders (sale_day, nome, telefone, aniversario, unidade_pref, qty, optin)
  values (d, trim(p_nome), tel, trim(coalesce(p_aniv,'')), p_unid, p_qty, coalesce(p_optin,false))
  returning id into new_id;
  return json_build_object('id', new_id, 'total', s.vale_value * p_qty);
end $$;

-- Link do vale do cliente (pelo token secreto, não pelo código)
create or replace function voucher_public(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare v vouchers;
begin
  select * into v from vouchers where token = p_token;
  if not found then return null; end if;
  return json_build_object(
    'code', v.code, 'nome', split_part(v.nome,' ',1), 'saldo', v.saldo, 'status', v.status,
    'expires_on', v.expires_on, 'bonus_expires_on', v.bonus_expires_on,
    'cortesia_usada', v.cortesia_day is not null, 'cortesia_item', v.cortesia_item,
    'bonus_usado', v.bonus_day is not null);
end $$;

-- =====================================================================
-- UNIDADES
-- =====================================================================

create or replace function bonus_block_reason(v vouchers, d date) returns text
language plpgsql stable set search_path = public as $$
begin
  if v.status <> 'ativo' then return 'Vale cancelado.'; end if;
  if v.bonus_day is not null then return 'Bônus já usado.'; end if;
  if d > v.bonus_expires_on then return 'Bônus vencido.'; end if;
  if v.last_vale_day = d or v.cortesia_day = d then return 'O vale foi usado hoje. O bônus fica para outra visita.'; end if;
  if exists (select 1 from redemptions r join vouchers w on w.id = r.voucher_id
             where w.order_id = v.order_id and r.day = d and r.valor > 0 and r.undone_at is null) then
    return 'Um vale desta mesma compra foi usado hoje. O bônus fica para outra visita.';
  end if;
  if extract(isodow from d) > 4 then return 'Bônus só de segunda a quinta.'; end if;
  if exists (select 1 from holidays where day = d) then return 'Bônus não vale em feriado.'; end if;
  return null;
end $$;

create or replace function find_voucher(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare v vouchers; d date := today_br();
begin
  if my_role() not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  select * into v from vouchers where code = upper(trim(p_code));
  if not found then return null; end if;
  return json_build_object(
    'code', v.code, 'nome', v.nome, 'saldo', v.saldo, 'status', v.status,
    'expires_on', v.expires_on, 'bonus_expires_on', v.bonus_expires_on,
    'vencido', d > v.expires_on,
    'cortesia_usada', v.cortesia_day is not null, 'cortesia_item', v.cortesia_item,
    'bonus_usado', v.bonus_day is not null,
    'bonus_bloqueio', bonus_block_reason(v, d),
    'vale_bloqueio', case when exists (select 1 from vouchers w where w.order_id = v.order_id and w.bonus_day = d)
                          then 'Um bônus desta compra foi usado hoje. O vale fica para outra visita.' end,
    'historico', (select coalesce(json_agg(json_build_object(
        'id', r.id, 'pode_desfazer', r.unit = unit_name_now() and r.created_at > now() - interval '30 minutes',
        'quando', to_char(r.created_at at time zone 'America/Sao_Paulo','DD/MM HH24:MI'),
        'unidade', r.unit, 'atendente', r.atendente, 'comanda', r.comanda, 'valor', r.valor,
        'cortesia', r.cortesia_item, 'bonus', r.bonus) order by r.created_at desc), '[]')
      from redemptions r where r.voucher_id = v.id and r.undone_at is null));
end $$;

create or replace function redeem(p_code text, p_valor numeric, p_cort_tipo text, p_cort_item text,
                                  p_bonus boolean, p_comanda text, p_atendente text)
returns json language plpgsql security definer set search_path = public as $$
declare v vouchers; d date := today_br(); unit text; why text; valor numeric := coalesce(p_valor,0);
begin
  if my_role() not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  unit := coalesce(my_unit(), 'Admin');
  if length(trim(coalesce(p_atendente,''))) < 2 then raise exception 'ATENDENTE_OBRIGATORIO'; end if;
  if length(trim(coalesce(p_comanda,''))) < 1 then raise exception 'COMANDA_OBRIGATORIA'; end if;

  select * into v from vouchers where code = upper(trim(p_code)) for update;  -- trava contra uso duplo
  if not found then raise exception 'VALE_NAO_ENCONTRADO'; end if;
  if v.status <> 'ativo' then raise exception 'VALE_CANCELADO'; end if;

  if coalesce(p_bonus,false) then
    if valor > 0 or p_cort_item is not null then raise exception 'BONUS_JUNTO_COM_VALE'; end if;
    if exists (select 1 from redemptions x where x.unit = unit_name_now() and x.day = d and x.comanda = trim(p_comanda)
               and x.undone_at is null and not x.bonus) then raise exception 'COMANDA_COM_VALE'; end if;
    why := bonus_block_reason(v, d);
    if why is not null then raise exception 'BONUS_BLOQUEADO:%', why; end if;
    update vouchers set bonus_day = d where id = v.id;
  else
    if valor <= 0 and p_cort_item is null then raise exception 'NADA_SELECIONADO'; end if;
    if exists (select 1 from redemptions x where x.unit = unit_name_now() and x.day = d and x.comanda = trim(p_comanda)
               and x.undone_at is null and x.bonus) then raise exception 'COMANDA_COM_BONUS'; end if;
    if d > v.expires_on then raise exception 'VALE_VENCIDO'; end if;
    if exists (select 1 from vouchers w where w.order_id = v.order_id and w.bonus_day = d) then raise exception 'BONUS_USADO_HOJE'; end if;
    if valor < 0 or valor > v.saldo then raise exception 'VALOR_ACIMA_DO_SALDO'; end if;
    if p_cort_item is not null then
      if v.cortesia_day is not null then raise exception 'CORTESIA_JA_USADA'; end if;
      if valor <= 0 then raise exception 'CORTESIA_SO_COM_VALE'; end if;
      if p_cort_tipo not in ('Drink','Sobremesa') then raise exception 'CORTESIA_INVALIDA'; end if;
    end if;
    update vouchers set
      saldo = saldo - valor,
      last_vale_day = case when valor > 0 then d else last_vale_day end,
      cortesia_tipo = coalesce(p_cort_tipo, cortesia_tipo) ,
      cortesia_item = coalesce(p_cort_item, cortesia_item),
      cortesia_day  = case when p_cort_item is not null then d else cortesia_day end
    where id = v.id;
  end if;

  insert into redemptions (voucher_id, day, unit, atendente, comanda, valor, cortesia_tipo, cortesia_item, bonus)
  values (v.id, d, unit, trim(p_atendente), trim(p_comanda), valor,
          case when p_cort_item is not null then p_cort_tipo end, p_cort_item, coalesce(p_bonus,false));
  return find_voucher(v.code);
end $$;

-- =====================================================================
-- ADMIN (Natália)
-- =====================================================================

create or replace function new_code() returns text language plpgsql as $$
declare chars text := 'ACDEFGHJKMNPQRTUVWXY34679'; c text;
begin
  loop
    c := 'NSH-' || (select string_agg(substr(chars, 1 + floor(random()*length(chars))::int, 1), '')
                    from generate_series(1,5));
    exit when not exists (select 1 from vouchers where code = c);
  end loop;
  return c;
end $$;

drop function if exists approve_order(bigint);
create or replace function approve_order(p_id bigint, p_receipt text) returns json
language plpgsql security definer set search_path = public as $$
declare o orders; s settings; out json := '[]'::json; i int; c text; t text; d date := today_br();
begin
  if not is_admin() then raise exception 'SEM_PERMISSAO'; end if;
  if length(trim(coalesce(p_receipt,''))) = 0 then raise exception 'COMPROVANTE_OBRIGATORIO'; end if;
  select * into o from orders where id = p_id for update;
  if not found then raise exception 'PEDIDO_NAO_ENCONTRADO'; end if;
  if o.status not in ('pendente','recusado') then raise exception 'PEDIDO_JA_DECIDIDO'; end if;
  select * into s from settings where id = 1;
  for i in 1..o.qty loop
    c := new_code();
    t := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
    insert into vouchers (code, token, order_id, nome, telefone, expires_on, bonus_expires_on, saldo)
    values (c, t, o.id, o.nome, o.telefone, (d + interval '3 months')::date, (d + interval '3 months')::date, s.vale_value);
  end loop;
  update orders set status = 'aprovado', decided_at = now(), receipt_path = p_receipt where id = p_id;
  select json_agg(json_build_object('code', code, 'token', token) order by code) into out
    from vouchers where order_id = p_id;
  return json_build_object('nome', o.nome, 'telefone', o.telefone, 'vales', out);
end $$;

create or replace function reject_order(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SEM_PERMISSAO'; end if;
  update orders set status = 'recusado', decided_at = now(), note = p_note
   where id = p_id and status = 'pendente';
  if not found then raise exception 'PEDIDO_JA_DECIDIDO'; end if;
end $$;

-- Cancelamento (desistência): bloqueia os vales do pedido
create or replace function cancel_order(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SEM_PERMISSAO'; end if;
  if exists (select 1 from redemptions r join vouchers v on v.id = r.voucher_id
             where v.order_id = p_id and r.undone_at is null) then raise exception 'VALE_JA_USADO'; end if;
  update orders set status = 'cancelado', decided_at = now(), note = p_note where id = p_id;
  update vouchers set status = 'cancelado' where order_id = p_id;
end $$;

create or replace function undo_redemption(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r redemptions;
begin
  if my_role() not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  select * into r from redemptions where id = p_id and undone_at is null for update;
  if not found then raise exception 'USO_NAO_ENCONTRADO'; end if;
  if not is_admin() and (r.unit <> my_unit() or r.created_at < now() - interval '30 minutes') then
    raise exception 'DESFAZER_SO_ADMIN';
  end if;
  update vouchers set
    saldo = saldo + r.valor,
    bonus_day = case when r.bonus then null else bonus_day end,
    cortesia_day  = case when r.cortesia_item is not null then null else cortesia_day end,
    cortesia_tipo = case when r.cortesia_item is not null then null else cortesia_tipo end,
    cortesia_item = case when r.cortesia_item is not null then null else cortesia_item end,
    last_vale_day = case when r.valor > 0 then
      (select max(day) from redemptions x where x.voucher_id = r.voucher_id and x.id <> r.id and x.valor > 0 and x.undone_at is null)
      else last_vale_day end
  where id = r.voucher_id;
  update redemptions set undone_at = now() where id = p_id;
end $$;

-- Anexar ou trocar o comprovante de um pedido já aprovado
create or replace function set_receipt(p_id bigint, p_receipt text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SEM_PERMISSAO'; end if;
  if length(trim(coalesce(p_receipt,''))) = 0 then raise exception 'COMPROVANTE_OBRIGATORIO'; end if;
  update orders set receipt_path = p_receipt where id = p_id;
end $$;

-- ---------- Comprovantes (Storage privado, só a admin vê) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;
drop policy if exists comprovantes_admin on storage.objects;
create policy comprovantes_admin on storage.objects for all to authenticated
  using (bucket_id = 'comprovantes' and public.is_admin())
  with check (bucket_id = 'comprovantes' and public.is_admin());

-- ---------- Permissões das funções ----------
revoke all on function create_order, sales_status, voucher_public, find_voucher, redeem,
  approve_order, reject_order, cancel_order, undo_redemption, set_receipt from public;
grant execute on function sales_status, create_order, voucher_public to anon, authenticated;
grant execute on function find_voucher, redeem, approve_order, reject_order, cancel_order,
  undo_redemption, set_receipt to authenticated;
grant select on settings, orders, vouchers, redemptions, holidays, profiles to authenticated;
grant update on settings to authenticated;
grant insert, delete on holidays to authenticated;
