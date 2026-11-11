-- Vale Black · atualização 5 (11/11/2026)
-- 1) A unidade pode desfazer o próprio registro em até 30 minutos.
-- 2) Pedido marcado como 'Pix não encontrado' pode ser aprovado depois.
-- 3) Pedido pendente há mais de 3 horas deixa de segurar o lote do dia.
-- 4) Vale e bônus da mesma compra não saem no mesmo dia, em qualquer ordem.
-- 5) O cartão do cliente mostra o histórico de uso.
-- 6) Lista de fechamento: vales usados hoje em cada unidade.
-- 7) Trava contra registro duplicado (toque duplo ou internet lenta).
-- 8) Segurança: só contas de unidade ou admin consultam e registram vales.
-- 9) Quem já tem pedido aguardando Pix recupera o mesmo Pix ao pedir de novo.
-- 10) Telefone com ou sem 55 conta como o mesmo número.
-- Cole tudo no SQL Editor do Supabase e clique em Run. Não apaga dados.


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

create or replace function create_order(p_nome text, p_tel text, p_aniv text, p_unid text,
                                        p_qty int, p_optin boolean, p_lgpd boolean)
returns json language plpgsql security definer set search_path = public as $$
declare s settings; used int; d date := today_br(); tel text; new_id bigint;
begin
  if not coalesce(p_lgpd,false) then raise exception 'ACEITE_OBRIGATORIO'; end if;
  if length(trim(coalesce(p_nome,''))) < 3 then raise exception 'NOME_INVALIDO'; end if;
  tel := regexp_replace(coalesce(p_tel,''), '\D', '', 'g');
  if length(tel) not between 10 and 13 then raise exception 'TELEFONE_INVALIDO'; end if;
  if length(tel) in (12,13) and left(tel,2) = '55' then tel := substr(tel,3); end if;   -- mesmo número com ou sem 55
  if p_qty is null or p_qty not between 1 and 4 then raise exception 'QUANTIDADE_INVALIDA'; end if;
  if p_unid not in ('Savassi','Lourdes','São Pedro','Contagem') then raise exception 'UNIDADE_INVALIDA'; end if;

  perform pg_advisory_xact_lock(4242);          -- uma venda por vez, para não passar do limite
  select * into s from settings where id = 1;
  if d < s.sales_start or d > s.sales_end then raise exception 'FORA_DO_PERIODO'; end if;
  -- já tem pedido aguardando Pix hoje: devolve o mesmo pedido (o cliente recupera o Pix)
  select id, qty into new_id, used from orders where telefone = tel and status = 'pendente' and sale_day = d order by id limit 1;
  if found then
    return json_build_object('id', new_id, 'total', s.vale_value * used, 'qty', used, 'existente', true);
  end if;
  select coalesce(sum(qty),0) into used from orders
   where sale_day = d and (status = 'aprovado' or (status = 'pendente' and created_at > now() - interval '3 hours'));
  if used + p_qty > s.daily_limit then
    raise exception 'ESGOTADO_HOJE:%', greatest(s.daily_limit - used, 0);
  end if;

  insert into orders (sale_day, nome, telefone, aniversario, unidade_pref, qty, optin)
  values (d, trim(p_nome), tel, trim(coalesce(p_aniv,'')), p_unid, p_qty, coalesce(p_optin,false))
  returning id into new_id;
  return json_build_object('id', new_id, 'total', s.vale_value * p_qty, 'qty', p_qty, 'existente', false);
end $$;

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
    'bonus_usado', v.bonus_day is not null,
    'usos', (select coalesce(json_agg(json_build_object(
        'quando', to_char(r.created_at at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
        'unidade', r.unit, 'comanda', r.comanda, 'valor', r.valor,
        'cortesia', r.cortesia_item, 'bonus', r.bonus) order by r.created_at desc), '[]')
      from redemptions r where r.voucher_id = v.id and r.undone_at is null));
end $$;

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
  if coalesce(my_role(),'') not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
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

create or replace function unit_today() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(my_role(),'') not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  return (select coalesce(json_agg(json_build_object(
      'hora', to_char(r.created_at at time zone 'America/Sao_Paulo','HH24:MI'),
      'code', v.code, 'comanda', r.comanda, 'atendente', r.atendente, 'valor', r.valor,
      'cortesia', r.cortesia_item, 'bonus', r.bonus) order by r.created_at), '[]')
    from redemptions r join vouchers v on v.id = r.voucher_id
    where r.unit = unit_name_now() and r.day = today_br() and r.undone_at is null);
end $$;

create or replace function redeem(p_code text, p_valor numeric, p_cort_tipo text, p_cort_item text,
                                  p_bonus boolean, p_comanda text, p_atendente text)
returns json language plpgsql security definer set search_path = public as $$
declare v vouchers; d date := today_br(); unit text; why text; valor numeric := round(coalesce(p_valor,0),2);
begin
  if coalesce(my_role(),'') not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  if length(trim(coalesce(p_cort_item,''))) < 2 then p_cort_item := null; end if;   -- cortesia sem nome não conta
  unit := coalesce(my_unit(), 'Admin');
  if length(trim(coalesce(p_atendente,''))) < 2 then raise exception 'ATENDENTE_OBRIGATORIO'; end if;
  if length(trim(coalesce(p_comanda,''))) < 1 then raise exception 'COMANDA_OBRIGATORIA'; end if;

  select * into v from vouchers where code = upper(trim(p_code)) for update;  -- trava contra uso duplo
  if not found then raise exception 'VALE_NAO_ENCONTRADO'; end if;
  if v.status <> 'ativo' then raise exception 'VALE_CANCELADO'; end if;
  if exists (select 1 from redemptions x where x.voucher_id = v.id and x.comanda = trim(p_comanda)
             and x.valor = round(coalesce(p_valor,0),2) and x.bonus = coalesce(p_bonus,false) and x.undone_at is null
             and x.created_at > now() - interval '3 minutes') then
    raise exception 'USO_DUPLICADO';                -- toque duplo ou internet lenta
  end if;

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

create or replace function undo_redemption(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r redemptions;
begin
  if coalesce(my_role(),'') not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
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

revoke all on function unit_today from public;
grant execute on function undo_redemption, unit_today to authenticated;
