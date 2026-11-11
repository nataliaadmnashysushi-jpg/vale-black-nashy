// Todo dia, às 05:00 de Brasília, guarda uma cópia completa do banco no Netlify (fora do Supabase).
import { getStore } from "@netlify/blobs";
import { TABLES, readTable, secret, toCSV, todayBR } from "../lib/copias-lib.mjs";

const KEEP_DAYS = 180;

export default async () => {
  const key = secret();
  const data = {};
  for (const t of TABLES) data[t] = await readTable(t, key);
  const day = todayBR();
  const store = getStore("copias");
  await store.set(`${day}/tudo.json`, JSON.stringify({ criado_em: new Date().toISOString(), ...data }));
  await store.set(`${day}/vales.csv`, toCSV(data.vouchers));
  await store.set(`${day}/usos.csv`, toCSV(data.redemptions));
  await store.set(`${day}/pedidos.csv`, toCSV(data.orders));
  // apaga cópias com mais de 180 dias
  const limit = new Date(Date.now() - KEEP_DAYS * 864e5).toISOString().slice(0, 10);
  const { blobs } = await store.list();
  for (const b of blobs) if (b.key.slice(0, 10) < limit) await store.delete(b.key);
  console.log("copia", day, Object.fromEntries(TABLES.map(t => [t, data[t].length])));
  return new Response("ok");
};

export const config = { schedule: "0 8 * * *" };
