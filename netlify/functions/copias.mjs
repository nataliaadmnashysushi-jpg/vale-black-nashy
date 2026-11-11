// Lista e entrega as cópias automáticas. Só para a administradora logada no painel.
import { getStore } from "@netlify/blobs";
import { SB_URL, SB_PUB, secret, adminHeaders } from "../lib/copias-lib.mjs";

async function isAdmin(req) {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return false;
  const u = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_PUB, Authorization: `Bearer ${token}` } });
  if (!u.ok) return false;
  const { id } = await u.json();
  const key = secret();
  const p = await fetch(`${SB_URL}/rest/v1/profiles?user_id=eq.${encodeURIComponent(id)}&select=role`, {
    headers: adminHeaders(key),
  });
  if (!p.ok) return false;
  const rows = await p.json();
  return rows[0]?.role === "admin";
}

export default async (req) => {
  try {
    if (!(await isAdmin(req))) return new Response("Sem permissão", { status: 403 });
  } catch (e) {
    return new Response(String(e.message || e), { status: 500 });
  }
  const store = getStore("copias");
  const file = new URL(req.url).searchParams.get("arquivo");
  if (!file) {
    const { blobs } = await store.list();
    const days = [...new Set(blobs.map(b => b.key.slice(0, 10)))].sort().reverse();
    return Response.json({ dias: days });
  }
  if (!/^\d{4}-\d{2}-\d{2}\/(tudo\.json|vales\.csv|usos\.csv|pedidos\.csv)$/.test(file)) return new Response("Arquivo inválido", { status: 400 });
  const body = await store.get(file);
  if (body === null) return new Response("Não encontrado", { status: 404 });
  const type = file.endsWith(".json") ? "application/json" : "text/csv; charset=utf-8";
  return new Response(body, { headers: { "Content-Type": type, "Cache-Control": "no-store" } });
};
