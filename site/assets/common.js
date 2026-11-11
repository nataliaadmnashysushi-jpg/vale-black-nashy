const CFG = window.NASHY_CONFIG;
const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);
const $ = s => document.querySelector(s);
const fmt = v => "R$ " + Number(v).toFixed(2).replace(".", ",").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
const brDate = iso => iso ? iso.slice(0,10).split("-").reverse().join("/") : "";
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmtPhone = t => { const d=String(t||"").replace(/\D/g,"").replace(/^55(?=\d{10,11}$)/,""); return d.length===11?`(${d.slice(0,2)}) ${d.slice(2,7)}-${d.slice(7)}`:d.length===10?`(${d.slice(0,2)}) ${d.slice(2,6)}-${d.slice(6)}`:d; };
const waNumber = t => { const d=String(t||"").replace(/\D/g,""); return d.length<=11 ? "55"+d : d; };

const DRINKS = ["Saquerinha","Mojito","Mojito de maçã verde","Gin tônica","Cuba libre","Aperol Spritz","Sex on the Beach","Pôr do Sol"];
const DESSERTS = ["Petit gâteau","Creme de papaia","Banana flambada","Sorvete"];

const ERRORS = {
  ACEITE_OBRIGATORIO: "Para continuar, aceite as regras e o uso dos dados.",
  NOME_INVALIDO: "Escreva o seu nome completo.",
  TELEFONE_INVALIDO: "Confira o WhatsApp com DDD.",
  QUANTIDADE_INVALIDA: "Escolha de 1 a 4 vales.",
  UNIDADE_INVALIDA: "Escolha uma unidade.",
  FORA_DO_PERIODO: "As vendas do vale não estão abertas hoje.",
  PEDIDO_PENDENTE: "Já existe um pedido seu aguardando confirmação do Pix. Fale com a gente no WhatsApp.",
  ESGOTADO_HOJE: "Este lote esgotou. Acompanhe o Instagram do Nashy para o próximo.",
  SEM_PERMISSAO: "Você não tem permissão para isso. Entre de novo.",
  ATENDENTE_OBRIGATORIO: "Escreva o seu nome antes de confirmar.",
  COMANDA_OBRIGATORIA: "Digite o número da comanda.",
  VALE_NAO_ENCONTRADO: "Vale não encontrado. Confira o código.",
  VALE_CANCELADO: "Este vale foi cancelado.",
  VALE_VENCIDO: "Este vale está vencido.",
  BONUS_JUNTO_COM_VALE: "O bônus não pode entrar na mesma comanda do vale.",
  BONUS_USADO_HOJE: "Um bônus desta compra foi usado hoje. O vale fica para outra visita.",
  NADA_SELECIONADO: "Marque o que o cliente vai usar.",
  VALOR_ACIMA_DO_SALDO: "O valor passa do saldo do vale.",
  CORTESIA_JA_USADA: "A cortesia deste vale já foi usada.",
  CORTESIA_SO_COM_VALE: "A cortesia só pode ser usada junto com o crédito do vale.",
  CORTESIA_INVALIDA: "Escolha drink ou sobremesa.",
  PEDIDO_JA_DECIDIDO: "Este pedido já foi aprovado ou recusado.",
  USO_NAO_ENCONTRADO: "Este uso já foi desfeito.",
  COMANDA_COM_VALE: "Esta comanda já tem crédito de vale hoje. O bônus precisa ir em outra comanda, em outra visita.",
  COMANDA_COM_BONUS: "Esta comanda já tem um bônus hoje. O vale não pode entrar na mesma comanda do bônus.",
  COMPROVANTE_OBRIGATORIO: "Anexe o comprovante do Pix para aprovar.",
  DESFAZER_SO_ADMIN: "Já passou de 30 minutos. Para desfazer, fale com a Natália.",
  VALE_JA_USADO: "Um dos vales deste pedido já foi usado. Desfaça os usos na aba Usos antes de cancelar, se for o caso.",
};
function errMsg(e){
  const m = (e && (e.message || e.msg)) || String(e);
  const [key, extra] = m.split(":");
  if (key === "BONUS_BLOQUEADO") return m.slice(16);
  if (key === "ESGOTADO_HOJE" && Number(extra) > 0) return `Restam só ${extra} vale(s) neste lote. Diminua a quantidade.`;
  if (ERRORS[key]) return ERRORS[key];
  if (/Failed to fetch|NetworkError/i.test(m)) return "Sem conexão. Confira a internet e tente de novo.";
  if (/Invalid login/i.test(m)) return "Senha incorreta.";
  return "Algo deu errado. Tente de novo. (" + m + ")";
}
// Lê "137,50", "137.50", "1.137,50" ou "50" como número
function parseMoney(t){
  let x = String(t||"").trim().replace(/[^\d.,]/g,"");
  if (x.includes(",")) x = x.replace(/\./g,"").replace(",", ".");
  else if (/\.\d{3}$/.test(x)) x = x.replace(/\./g,"");
  const n = Math.round(parseFloat(x) * 100) / 100;
  return isFinite(n) ? n : 0;
}
// Busca todas as linhas, sem o limite de 1000 do Supabase
async function fetchAll(build){
  const out = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await build().range(from, from + 999);
    if (error) return { data: null, error };
    out.push(...data); if (data.length < 1000) return { data: out, error: null };
  }
}
async function rpc(name, args){ const { data, error } = await sb.rpc(name, args); if (error) throw error; return data; }

function toast(msg){ let t=$("#toast"); if(!t){ t=document.createElement("div"); t.id="toast"; t.className="toast"; t.setAttribute("role","status"); document.body.appendChild(t); }
  t.textContent=msg; t.hidden=false; clearTimeout(toast.h); toast.h=setTimeout(()=>t.hidden=true,3500); }

async function copyText(text){ try { await navigator.clipboard.writeText(text); toast("Copiado."); }
  catch { const ta=document.createElement("textarea"); ta.value=text; document.body.appendChild(ta); ta.select(); document.execCommand("copy"); ta.remove(); toast("Copiado."); } }

// ---------- Pix copia e cola (BR Code estático com o número do pedido) ----------
function pixPayload({ key, name, city, amount, txid }){
  const clean = s => s.normalize("NFD").replace(/[̀-ͯ]/g,"").toUpperCase().replace(/[^A-Z0-9 ]/g,"").trim();
  const f = (id, v) => id + String(v.length).padStart(2,"0") + v;
  const acc = f("00","br.gov.bcb.pix") + f("01", key);
  let p = f("00","01") + f("26",acc) + f("52","0000") + f("53","986") + f("54", Number(amount).toFixed(2)) +
          f("58","BR") + f("59", clean(name).slice(0,25)) + f("60", clean(city).slice(0,15)) +
          f("62", f("05", txid.replace(/[^A-Za-z0-9]/g,"").slice(0,25))) + "6304";
  let c = 0xFFFF;
  for (let i=0;i<p.length;i++){ c ^= p.charCodeAt(i) << 8; for (let j=0;j<8;j++) c = (c & 0x8000) ? ((c<<1)^0x1021) : (c<<1); c &= 0xFFFF; }
  return p + c.toString(16).toUpperCase().padStart(4,"0");
}

function downloadCSV(name, rows){
  const csv = "﻿" + rows.map(r => r.map(v => `"${String(v ?? "").replace(/"/g,'""')}"`).join(";")).join("\n");
  const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([csv],{type:"text/csv"})); a.download = name; a.click();
}
