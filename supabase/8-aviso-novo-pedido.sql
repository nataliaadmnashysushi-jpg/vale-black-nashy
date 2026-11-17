-- 8: aviso no celular a cada pedido novo (app ntfy, tópico nashy-vale-5217d3592b0a)
-- O aviso não leva nome nem telefone do cliente: só quantidade, valor e unidade.
-- Se o aviso falhar por qualquer motivo, o pedido é criado normalmente.
-- Pode rodar mais de uma vez sem problema.

create extension if not exists pg_net with schema extensions;

create or replace function avisar_novo_pedido() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v numeric;
begin
  begin
    select vale_value into v from settings where id = 1;
    perform net.http_post(
      url := 'https://ntfy.sh/nashy-vale-5217d3592b0a',
      body := jsonb_build_object(
        'topic', 'nashy-vale-5217d3592b0a',
        'title', 'Novo pedido Vale Black',
        'message', new.qty || ' vale(s) · R$ ' || to_char(new.qty * coalesce(v, 200), 'FM999G990') ||
                   ' · ' || new.unidade_pref || ' · aguardando Pix',
        'tags', jsonb_build_array('moneybag')),
      headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then
    null; -- nunca atrapalhar o pedido
  end;
  return new;
end $$;

drop trigger if exists aviso_novo_pedido on orders;
create trigger aviso_novo_pedido after insert on orders
  for each row execute function avisar_novo_pedido();
