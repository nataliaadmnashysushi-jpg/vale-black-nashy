-- 7: validade de 12 meses (decisão do Vitor, 16/11/2026)
-- Novos vales: vencem 12 meses depois da aprovação do Pix.
-- Vales já aprovados e ativos: passam a vencer 12 meses depois da aprovação.
-- Pode rodar mais de uma vez sem problema.

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
    values (c, t, o.id, o.nome, o.telefone, (d + interval '12 months')::date, (d + interval '12 months')::date, s.vale_value);
  end loop;
  update orders set status = 'aprovado', decided_at = now(), receipt_path = p_receipt where id = p_id;
  select json_agg(json_build_object('code', code, 'token', token) order by code) into out
    from vouchers where order_id = p_id;
  return json_build_object('nome', o.nome, 'telefone', o.telefone, 'vales', out);
end $$;

update vouchers
   set expires_on = (approved_at at time zone 'America/Sao_Paulo')::date + interval '12 months',
       bonus_expires_on = (approved_at at time zone 'America/Sao_Paulo')::date + interval '12 months'
 where status = 'ativo';
