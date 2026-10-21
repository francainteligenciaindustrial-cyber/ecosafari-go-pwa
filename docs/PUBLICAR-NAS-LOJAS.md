# Do GitHub Pages à Google Play e à App Store — passo a passo

> Ordem recomendada: **1) domínio → 2) piloto → 3) Google Play → 4) App Store.**
> Valores e regras das lojas mudam; confira nas páginas oficiais antes de pagar.

## 1. Domínio próprio (30 min + até 24 h de propagação)
1. Registre um domínio no **Registro.br** (`ecosafarigo.com.br`, cerca de R$ 40/ano) ou em outro registrador.
2. GitHub → repositório do app → **Settings → Pages → Custom domain** → digite `app.ecosafarigo.com.br` → Save.
3. No painel do registrador, crie um registro **CNAME**: nome `app` → valor `SEU-USUARIO.github.io`.
4. Quando o GitHub mostrar o domínio verde, marque **Enforce HTTPS**.
5. Suba o arquivo vazio `.nojekyll` (já está na pasta `app/`). Sem ele o GitHub Pages esconde a pasta `.well-known`, necessária para o Android.
6. **Só imprima os QR codes depois disso**: o endereço muda e os cartazes antigos deixariam de funcionar. Confira também o aviso do Supabase: Authentication → URL Configuration → coloque o novo endereço em **Site URL** e **Redirect URLs**.

## 2. Vercel ou Cloudflare Pages (opcional)
Só vale se você quiser cabeçalhos de segurança (já prontos em `vercel.json`) e deploy automático com pré-visualização. Em vercel.com: **Add New → Project → importar o repositório** → *Framework: Other* → *Root Directory: app* → Deploy. Depois aponte o domínio para a Vercel (Settings → Domains) em vez do GitHub Pages. Não faz diferença para o hóspede.

## 3. Google Play (Android) — o caminho mais fácil
O app vira um "Trusted Web Activity": a loja abre o seu PWA em tela cheia, sem barra do navegador.

**Antes:** conta de desenvolvedor Google Play (taxa única; confira o valor). Contas pessoais novas costumam precisar de um **teste fechado** com um número mínimo de testadores por algumas semanas antes de publicar; contas de empresa (CNPJ) geralmente não.

**Gerar o pacote (sem programar):**
1. Abra **pwabuilder.com**, cole o endereço do app (com o domínio próprio) e clique **Start**. Ele lê o `manifest.json` e confere os ícones.
2. Escolha **Android → Google Play** → *Package ID* `br.com.ecosafarigo.app` (use o mesmo no `assetlinks.json`) → baixe o pacote `.aab` e o arquivo de assinatura (**guarde o `.keystore` e as senhas num lugar seguro: sem elas você não atualiza o app**).
3. No **Play Console**: *Criar app* → faça upload do `.aab` em **Teste interno** primeiro.
4. Em **Configurações → Integridade do app → Assinatura de app**, copie o **SHA-256** e cole em `app/.well-known/assetlinks.json` (troque o texto `COLE-AQUI…`). Suba o arquivo para o site. Sem isso o app abre com uma barra de endereço.
5. Preencha a ficha da loja com os textos de `lojas/LISTAGEM-LOJAS.md`; envie as imagens da pasta `lojas/capturas/`.
6. Responda **Segurança dos dados**, **Classificação de conteúdo** e **Público-alvo** (guia na listagem). Envie para análise (de horas a poucos dias).

## 4. App Store (iPhone) — mais trabalhoso
- Conta **Apple Developer** (anual; confira o valor). Para empresa é preciso um número D-U-N-S, que leva alguns dias.
- Exige um **Mac** (ou um serviço de build na nuvem) para gerar o app com **Capacitor** (envolve o PWA num app nativo): `npm i @capacitor/core @capacitor/cli @capacitor/ios` → `npx cap init` → apontar para os arquivos de `app/` → `npx cap add ios` → abrir no Xcode → *Archive* → enviar ao **TestFlight**.
- A Apple recusa apps que são "só um site". O seu tem câmera, leitor de QR, notificações e conteúdo da comunidade, o que ajuda, mas descreva isso nas notas para a análise e teste primeiro no TestFlight.
- Exige: política de privacidade pública, **excluir a conta dentro do app**, **denunciar e bloquear** usuários (tudo isso já está no app 2.5), e **um login de teste** nas notas da análise.

## 5. Conferência final antes de enviar às lojas
- [ ] Trocar as capturas de tela por **fotos reais** de avistamentos (as da pasta usam imagens de demonstração).
- [ ] Revisão jurídica dos Termos e da Política de Privacidade (menores de idade, compartilhamento científico).
- [ ] Domínio definitivo, HTTPS ativo, `assetlinks.json` preenchido.
- [ ] Função `delete-account` publicada no Supabase (ver CONFIGURACAO.md, seção 20).
- [ ] Conta de teste (e-mail e senha) para o revisor, já validada numa pousada de demonstração.
