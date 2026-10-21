# EcoSafari Go 2.0 — Guia de configuração

Siga na ordem. As etapas 1 a 4 são as mais importantes; o resto pode ser feito aos poucos. Cada recurso que depende de uma conta sua fica **desligado sem quebrar nada** até você configurar.

---

## 1. Rodar o SQL (5 min) — obrigatório

1. Supabase → **SQL Editor** → cole o conteúdo de `ecosafari-go-migration-enterprise.sql` → **Run**.
2. Confira que rodou no projeto **certo**: o app usa o projeto `wahmsrsnastxtqrxuufp`. (Num print anterior seu, o bucket `app-web` estava em outro projeto, `yqgyjfcygulolwxcuwow` — não rode lá por engano.)
3. Pode rodar de novo sem problema se tiver dúvida.

O que muda na hora: as views que estavam **abertas para qualquer pessoa** (selo UNRESTRICTED no Supabase) passam a respeitar as regras de acesso. Pode conferir: o selo some.

## 2. Atualizar o app no GitHub (5 min) — obrigatório

No repositório `ecosafari-go-pwa` → **Add file → Upload files** → arraste todos os arquivos da pasta `app/`:
`index.html`, `sw.js`, `manifest.json`, `termos.html`, `privacidade.html`, `icon-192.png`, `icon-512.png` → **Commit changes**.

No primeiro acesso depois disso, cada pessoa verá a tela "Antes de continuar" para aceitar os termos — isso é esperado (é o registro de consentimento da LGPD).

## 3. Completar os textos legais (15 min) — obrigatório antes de clientes reais

Em `termos.html` e `privacidade.html`, troque os trechos entre colchetes: `[RAZÃO SOCIAL]`, `[CNPJ]`, `[ENDEREÇO]`, `[NOME]` do encarregado. O e-mail do encarregado (`privacidade@ecosafarigo.com`) também aparece no app; para trocar:
```sql
update platform_settings set value = 'seu-email@dominio.com' where key = 'dpo_email';
```
**Peça a um advogado para revisar** os dois textos — eles cobrem o que a LGPD exige, mas a responsabilidade legal é da empresa.

Sempre que mudar os termos de forma relevante, troque a versão para todos aceitarem de novo:
```sql
update platform_settings set value = '2027-01-15' where key in ('terms_version','privacy_version');
```

## 4. Verificação em duas etapas (2FA) para a equipe (10 min)

1. Supabase → **Authentication → Multi-Factor** → confirme que **TOTP** está habilitado (já vem ligado por padrão).
2. No app, entre com a sua conta → **Perfil → Segurança → Verificação em duas etapas → Ativar** → escaneie o QR Code com o Google Authenticator / Microsoft Authenticator.
3. Peça para cada pessoa da equipe fazer o mesmo.
4. Só depois disso, torne obrigatório:
```sql
update platform_settings set value = 'true' where key = 'staff_mfa_required';
```
A partir daí, guia, admin de pousada e admin da plataforma só conseguem aprovar, criar, editar ou ver dados de outros usuários depois de digitar o código. Hóspedes não são afetados.

> Se alguém perder o celular: `update platform_settings set value = 'false' where key = 'staff_mfa_required';`, a pessoa entra, desativa e ativa de novo o 2FA, e você liga de volta.

## 5. Backup (escolha uma das opções)

**Opção A — Supabase Pro (recomendado com clientes pagantes):** US$ 25/mês. Backup diário automático e restauração com um clique. Em **Settings → Billing**.

**Opção B — gratuita, pelo GitHub:**
1. Crie um repositório novo, **privado**, ex.: `ecosafari-backups`. Nunca use o repositório público do app.
2. Envie para ele a pasta `backup/.github/workflows/backup-diario.yml` (mantendo o caminho `.github/workflows/`).
3. Em **Settings → Secrets and variables → Actions**, crie:
   - `SUPABASE_DB_URL`: Supabase → botão **Connect** → **Session pooler** → copie a URI e coloque a senha do banco no lugar de `[YOUR-PASSWORD]`.
   - `BACKUP_PASSPHRASE`: uma senha longa só sua. **Sem ela o backup não abre.**
4. **Actions → Backup diario do banco → Run workflow** para testar. Depois roda sozinho todo dia.

Observação: o backup cobre o banco (contas, avistamentos, moedas). As fotos e vídeos ficam no Storage do Supabase; o plano Pro também protege esses arquivos.

**Para restaurar** (num projeto novo): baixe o arquivo em Actions → Artifacts, descriptografe com `gpg -d arquivo.tar.gz.gpg > backup.tar.gz`, descompacte e rode `roles.sql`, `schema.sql` e `data.sql` no SQL Editor, nessa ordem.

## 6. Limpeza automática de dados (LGPD) (2 min)

Supabase → **Database → Extensions → pg_cron → ativar**. Depois, no SQL Editor:
```sql
select cron.schedule('lgpd-retention-weekly', '0 4 * * 0', $$select apply_data_retention()$$);
```
Toda semana apaga alertas lidos com mais de 6 meses, estatísticas de visita ao site com mais de 13 meses e os dados pessoais de cadastros de pousada recusados há mais de 6 meses.

## 7. Ambiente de teste (20 min)

1. Crie um segundo projeto no Supabase, ex.: `ecosafari-teste`.
2. Nele, rode `ecosafari-go-schema-completo.sql` (cria tudo do zero, já com a parte enterprise).
3. No `index.html`, preencha `CONFIG.environments.teste` com a URL e a chave **anon** desse projeto (Settings → API).
4. Para usar o app no teste, abra o link com `?env=teste` no final. Aparece uma faixa amarela **AMBIENTE DE TESTE**. Para voltar: `?env=producao`.

Regra daqui pra frente: todo SQL novo roda primeiro no teste.

## 8. Monitoramento de erros — Sentry (10 min, grátis)

1. Crie conta em sentry.io → **Create Project → Browser JavaScript**.
2. Copie o **DSN** e cole em `CONFIG.sentryDsn` no `index.html`. Suba o arquivo no GitHub.

A partir daí, todo erro no celular de qualquer hóspede aparece no Sentry com o aparelho, a versão e a tela.

## 9. Analytics de produto — PostHog (10 min, grátis)

1. Crie conta em posthog.com (escolha a região US ou EU) → copie a **Project API Key**.
2. Cole em `CONFIG.posthogKey` (e, se escolheu EU, troque `posthogHost` para `https://eu.i.posthog.com`).

Só coleta de quem marcou o consentimento opcional. Eventos já enviados: login, termos aceitos, avistamento enviado, avistamento guardado offline, fila sincronizada, 2FA ativado, convite aceito, relatório gerado, diário aberto/compartilhado, push ativado.

## 10. Alertas no celular (push) (20 min)

1. Num computador com Node.js: `npx web-push generate-vapid-keys`. Guarde as duas chaves.
2. Cole a chave **pública** em `CONFIG.webPushPublicKey` no `index.html`.
3. Supabase → **Edge Functions → Secrets**: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` (`mailto:seu-email`).
4. Publique a função `supabase/functions/send-web-push` (`npx supabase functions deploy send-web-push`).
5. Supabase → **Database → Webhooks → Create**: tabela `alerts`, evento **Insert**, tipo **Supabase Edge Function**, função `send-web-push`.

No Android funciona no Chrome. No iPhone, só depois de "Adicionar à Tela de Início" (exigência da Apple, iOS 16.4+).

## 11. Verificação automática do vídeo (15 min)

1. Secrets: `OPENAI_API_KEY` (platform.openai.com) e `ANTHROPIC_API_KEY` (o mesmo da assistente do painel).
2. Publique `supabase/functions/verify-video`.
3. Webhook: tabela `sightings`, evento **Insert**, função `verify-video`.

O guia passa a ver, em cada vídeo, se a pessoa disse nome, município e data/hora, com a transcrição. A decisão de aprovar continua sendo dele. Custo aproximado: alguns centavos de dólar por vídeo de 30 segundos.

## 12. Domínio próprio (30 min + propagação)

1. Registre o domínio (ex.: `ecosafarigo.com.br` no registro.br).
2. GitHub → repositório do app → **Settings → Pages → Custom domain**: `app.ecosafarigo.com.br`. No registro.br, crie um registro **CNAME** `app` → `francainteligenciaindustrial-cyber.github.io`.
3. Supabase → **Authentication → URL Configuration**: troque o **Site URL** para o domínio novo e adicione-o em **Redirect URLs** (sem isso, login com Google e e-mail de confirmação apontam para o endereço antigo).
4. No Resend, adicione o domínio e troque o remetente do SMTP para `noreply@ecosafarigo.com.br`.

## 13. Página de status e monitoramento de disponibilidade (10 min, grátis)

Em uptimerobot.com ou betterstack.com, crie monitores para o endereço do app e para `https://wahmsrsnastxtqrxuufp.supabase.co/auth/v1/health`, e publique a página de status pública que eles oferecem (ex.: `status.ecosafarigo.com.br`). É o que redes de pousadas pedem antes de assinar contrato.

## 14. Proteções extras de senha (2 min)

Supabase → **Authentication → Providers → Email**: senha mínima de 8 caracteres e exigir letras e números. No plano Pro, ative **Leaked password protection** (bloqueia senhas que já vazaram na internet).

## 15. Grupos / redes de pousadas

Quando uma rede contratar, crie o grupo e ligue as unidades:
```sql
insert into lodge_groups (name, owner_user_id)
  values ('Grupo Pantanal', (select id from profiles where email = 'dono-da-rede@email.com'))
  returning id;
update lodges set group_id = 'ID-DO-GRUPO' where slug in ('pousada-a', 'pousada-b');
```
O dono da rede consulta os números consolidados com `select * from my_group_overview();` (próximo passo: uma tela própria para isso no app).

## 16. CAPTCHA no cadastro e no login — Cloudflare Turnstile (10 min, grátis)
1. dash.cloudflare.com → **Turnstile** → Add site → domínio do app (`ecosafari-go-pwa.github.io` ou o seu) → modo **Managed**. Guarde a **Site Key** e a **Secret Key**.
2. Supabase → Authentication → **Attack Protection** → **Enable CAPTCHA protection** → provedor Turnstile → cole a **Secret Key**.
3. No `index.html` do app, em `CONFIG`, preencha `turnstileSiteKey: 'SUA_SITE_KEY'` e suba para o GitHub.
> Faça os passos na ordem 1 → 2 → 3. Se ligar o passo 2 sem o passo 3, ninguém consegue entrar.

## 17. Moderação automática de imagens (15 min)
1. Google Cloud Console → habilite **Cloud Vision API** → crie uma **chave de API** (restrinja à Vision API). Os primeiros 1.000 pedidos por mês são grátis.
2. Supabase → Edge Functions → Secrets: `GOOGLE_VISION_API_KEY`.
3. Publique a função: `supabase functions deploy moderate-image --no-verify-jwt`.
4. Supabase → Database → **Webhooks** → Create: tabela `storage.objects`, evento **Insert**, tipo Supabase Edge Function → `moderate-image`.
Sem a chave a função não faz nada (as imagens ficam, e a denúncia é a defesa).

## 18. Testes automáticos do banco (10 min)
Copie as pastas `sql/` e `tests/` e o arquivo `ci/.github/workflows/testes-banco.yml` (mantendo o caminho `.github/workflows/`) para um repositório do GitHub — pode ser o do app. Em **Actions** os testes rodam a cada alteração. Quando um SQL novo for criado, adicione o teste correspondente em `tests/`.

## 19. QR code da pousada
Painel do dono → **Código de check-in compartilhado** → **QR code da pousada** → Imprimir. O link tem o formato `…/?j=CODIGO`; ao gerar um novo código, o QR antigo deixa de funcionar — reimprima.
