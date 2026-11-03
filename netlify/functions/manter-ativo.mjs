// Roda todo dia e faz uma consulta leve ao Supabase.
// O plano grátis do Supabase pausa o projeto depois de 7 dias sem uso;
// esta chamada diária evita que o banco do vale "durma" durante os 3 meses de validade.
const URL = "https://vgrlegsabrgibnhbwyyw.supabase.co/rest/v1/rpc/sales_status";
const KEY = "sb_publishable_tLRb5jLD8B9CAf5h47SvBQ_54FIBGoo"; // chave pública (a mesma do site)

export default async () => {
  const r = await fetch(URL, { method: "POST", headers: { apikey: KEY, "Content-Type": "application/json" }, body: "{}" });
  console.log("supabase", r.status);
  return new Response("ok");
};

export const config = { schedule: "@daily" };
