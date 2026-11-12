-- Vale Black · atualização 6 (12/11/2026)
-- 1) A unidade registra o NÚMERO DA MESA (mesmo campo de antes).
--    Como a mesma mesa recebe outros clientes no mesmo dia, a mesa NÃO bloqueia
--    mais bônus nem vale (o bloqueio barrava o cliente seguinte da mesa).
--    A regra da mesma compra (vale e bônus nunca no mesmo dia) continua igual,
--    presa ao código do vale.
-- 3) O bônus só libera depois que o crédito do próprio vale foi usado num dia
--    anterior (bônus = próxima visita). Assim ninguém usa bônus na primeira visita.
-- 2) O sistema guarda o valor total da conta, para o segundo vale da mesma mesa
--    não precisar digitar de novo.
-- Pode rodar mais de uma vez sem problema.

alter table redemptions add column if not exists conta numeric(10,2);
drop function if exists redeem(text, numeric, text, text, boolean, text, text);

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
  -- bônus = próxima visita: só libera depois que ESTE vale foi usado num dia anterior
  if not exists (select 1 from redemptions r where r.voucher_id = v.id and r.day < d
                 and r.valor > 0 and r.undone_at is null) then
    return 'O bônus libera na próxima visita, depois que o crédito deste vale for usado.';
  end if;
  if extract(isodow from d) > 4 then return 'Bônus só de segunda a quinta.'; end if;
  if exists (select 1 from holidays where day = d) then return 'Bônus não vale em feriado.'; end if;
  return null;
end $$;

create or replace function redeem(p_code text, p_valor numeric, p_cort_tipo text, p_cort_item text,
                                  p_bonus boolean, p_comanda text, p_atendente text, p_conta numeric default null)
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
    why := bonus_block_reason(v, d);
    if why is not null then raise exception 'BONUS_BLOQUEADO:%', why; end if;
    update vouchers set bonus_day = d where id = v.id;
  else
    if valor <= 0 and p_cort_item is null then raise exception 'NADA_SELECIONADO'; end if;
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

  insert into redemptions (voucher_id, day, unit, atendente, comanda, valor, cortesia_tipo, cortesia_item, bonus, conta)
  values (v.id, d, unit, trim(p_atendente), trim(p_comanda), valor,
          case when p_cort_item is not null then p_cort_tipo end, p_cort_item, coalesce(p_bonus,false),
          case when p_conta > 0 and p_conta < 100000 then round(p_conta,2) end);
  return find_voucher(v.code);
end $$;

create or replace function unit_today() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(my_role(),'') not in ('unit','admin') then raise exception 'SEM_PERMISSAO'; end if;
  return (select coalesce(json_agg(json_build_object(
      'hora', to_char(r.created_at at time zone 'America/Sao_Paulo','HH24:MI'),
      'code', v.code, 'comanda', r.comanda, 'atendente', r.atendente, 'valor', r.valor,
      'cortesia', r.cortesia_item, 'bonus', r.bonus, 'conta', r.conta) order by r.created_at), '[]')
    from redemptions r join vouchers v on v.id = r.voucher_id
    where r.unit = unit_name_now() and r.day = today_br() and r.undone_at is null);
end $$;

revoke all on function redeem, unit_today from public;
grant execute on function redeem, unit_today to authenticated;
