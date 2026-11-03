# Vale Black Nashy · como colocar no ar

O site tem 4 páginas:

| Página | Quem usa | Endereço |
|---|---|---|
| Vendas e cadastro | Clientes | `seusite/` |
| Vale do cliente | Clientes (link enviado no WhatsApp) | `seusite/vale.html?t=...` |
| Painel | Só a Natália | `seusite/painel.html` |
| Validação | Unidades | `seusite/unidade.html` |

Nunca mande senhas nem a chave `service_role` por chat.

---

## 1. Supabase (banco de dados), uns 15 minutos

1. Entre no projeto **vale-black**.
2. Menu da esquerda, **SQL Editor** > **New query**. Cole todo o arquivo `supabase/schema.sql` e clique em **Run**. Deve aparecer "Success".
3. **Authentication** > **Sign In / Providers**: desligue **Allow new users to sign up**. Assim ninguém cria conta sozinho.
4. **Authentication** > **Users** > **Add user** > **Create new user**. Crie 5 usuários e marque **Auto Confirm User** em cada um:
   - o seu e-mail, com uma senha forte (é o acesso ao painel);
   - `savassi@valeblack.nashy`
   - `lourdes@valeblack.nashy`
   - `saopedro@valeblack.nashy`
   - `contagem@valeblack.nashy`

   Cada unidade tem a sua senha. Anote as senhas num lugar seguro.
5. **SQL Editor** > **New query**. Cole o arquivo `supabase/usuarios.sql`, troque `EMAIL-DA-NATALIA@AQUI` pelo seu e-mail e clique em **Run**. No fim aparece a lista com 5 linhas: 1 admin e 4 unidades.
6. **Project Settings** > **API**. Copie o **Project URL** e a chave **anon public** e mande para o Claude. Essas duas podem ser compartilhadas, porque são públicas por natureza. A chave **service_role** nunca.

## 2. GitHub, uns 5 minutos

1. Repositório privado `vale-black-nashy` criado e vazio.
2. Libere o acesso do Claude em https://claude.ai/connect-github.
3. Avise o Claude. Ele coloca o código no repositório, já com o Project URL e a chave anon.

## 3. Netlify (coloca o site no ar), uns 5 minutos

1. **Add new site** > **Import an existing project** > **GitHub** > escolha `vale-black-nashy`.
2. Não precisa mudar nada. Clique em **Deploy**.
3. Em **Site configuration** > **Change site name**, troque para `vale-black-nashy`. O site fica em `https://vale-black-nashy.netlify.app`.
4. Toda vez que o Claude atualizar o código no GitHub, a Netlify publica sozinha.

## 4. Configurar no painel

Entre em `.../painel.html` com o seu e-mail e vá em **Configurações**:

- Chave Pix separada e nome do titular, exatamente como aparece no banco.
- WhatsApp dos comprovantes: `5511915472199`.
- Endereço do site: `https://vale-black-nashy.netlify.app/`.
- Vales por dia: 30. Início 07/11 e fim 27/11.

Para testar antes do dia 07, mude o **Início das vendas** para hoje e volte para 07/11 depois do teste.

## 5. Roteiro de teste (05/11)

1. No celular, faça um pedido de 1 vale na página de vendas.
2. Toque em **Copiar Pix copia e cola** e cole no app do banco. Confira se aparecem o titular certo e R$ 200,00. **Não precisa pagar.**
3. No painel, aprove o pedido e envie o vale para o seu WhatsApp. Abra o link do vale.
4. Em cada unidade: entre em `.../unidade.html`, leia o QR code do vale e teste:
   - usar R$ 150 + cortesia: o saldo vai para R$ 50;
   - tentar o bônus no mesmo dia: deve aparecer bloqueado;
   - tentar a cortesia de novo: deve aparecer como usada.
5. No painel, em **Usos nas unidades**, desfaça os usos do teste.
6. Em **Todos os pedidos**, cancele o pedido de teste.
7. Volte o **Início das vendas** para 07/11.

## Se o site cair

A unidade anota numa folha: código do vale, nome do cliente, valor, cortesia ou bônus, comanda, atendente e horário. Quando o site voltar, a Natália registra pelo painel.

## Regras que o sistema bloqueia sozinho

- Valor maior que o saldo.
- Cortesia sem crédito do vale, ou cortesia usada duas vezes.
- Bônus na mesma comanda ou no mesmo dia do vale, nas sextas, sábados, domingos e feriados, depois de usado ou depois de vencido.
- Vale vencido ou cancelado.
- Dois atendentes usando o mesmo vale ao mesmo tempo.
- Mais vendas do que o lote do dia.
- Mais de um pedido pendente no mesmo telefone.

Os feriados cadastrados vão até o Carnaval de 2027. Feriados municipais de Contagem não estão na lista.
