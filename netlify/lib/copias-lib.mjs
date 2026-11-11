// Funções comuns da cópia automática
export const SB_URL = "https://vgrlegsabrgibnhbwyyw.supabase.co";
export const SB_PUB = "sb_publishable_tLRb5jLD8B9CAf5h47SvBQ_54FIBGoo";
export const TABLES = ["orders", "vouchers", "redemptions", "settings", "holidays", "profiles"];

export function secret() {
  const k = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!k) throw new Error("Falta a variável SUPABASE_SECRET_KEY no Netlify.");
  return k;
}

// Chave nova (sb_secret_...) vai só no apikey; chave antiga (JWT) também no Authorization
export const adminHeaders = key => (key.startsWith("eyJ") ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key });

// Lê a tabela inteira, de 1000 em 1000
export async function readTable(name, key, f = fetch) {
  const out = [];
  for (let from = 0; ; from += 1000) {
    const r = await f(`${SB_URL}/rest/v1/${name}?select=*`, {
      headers: { ...adminHeaders(key), Range: `${from}-${from + 999}`, "Range-Unit": "items" },
    });
    if (!r.ok) throw new Error(`${name}: ${r.status} ${await r.text()}`);
    const rows = await r.json();
    out.push(...rows);
    if (rows.length < 1000) return out;
  }
}

export function toCSV(rows) {
  if (!rows.length) return "﻿";
  const cols = [...new Set(rows.flatMap(r => Object.keys(r)))];
  const cell = v => `"${String(v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : v).replace(/"/g, '""')}"`;
  return "﻿" + [cols.map(cell).join(";"), ...rows.map(r => cols.map(c => cell(r[c])).join(";"))].join("\n");
}

export const todayBR = () => new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10);
