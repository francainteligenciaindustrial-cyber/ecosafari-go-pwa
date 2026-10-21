# EcoSafari Go 2.5 — Pronto para as lojas

## Passo a passo
1. **SQL:** Supabase → SQL Editor → rode só `sql/ecosafari-go-migration-lote4-bloqueio.sql`.
2. **Função de exclusão de conta:** publique `supabase/functions/delete-account` (seção 20 do CONFIGURACAO.md).
3. **App:** arraste os arquivos de `app/` (soltos, incluindo `.nojekyll` e a pasta `.well-known`) para a **raiz** do repositório no GitHub → Commit. Feche e reabra o app.
4. Siga `docs/PUBLICAR-NAS-LOJAS.md` (domínio → Google Play → App Store). Textos e imagens das lojas estão em `lojas/`.

## O que mudou
- **Corrigido:** ao curtir ou comentar, a tela voltava ao topo. Agora fica no mesmo lugar.
- **Bloquear usuário** (⋯ no perfil de outra pessoa; lista em Ajustes). Quem bloqueia some do feed, dos comentários e da busca da outra pessoa, e vice-versa. A pessoa bloqueada não é avisada e não consegue abrir o perfil de quem bloqueou.
- **Excluir conta de verdade:** nova função no servidor apaga o login e as fotos; os avistamentos publicados ficam sem nome.
- **Para a loja:** ícones novos (adaptáveis do Android e de 1024 px), manifesto completo, ícone da tela inicial do iPhone, `vercel.json` com cabeçalhos de segurança, `assetlinks.json` modelo, capturas de tela, imagem de destaque do Google Play e textos da ficha.

## O que não consegui fazer por você
Criar as contas de desenvolvedor, pagar as taxas, registrar o domínio e enviar os apps às lojas exigem seus dados e seu pagamento. Também falta trocar as capturas de tela (que usam imagens de demonstração) por fotos reais, e a revisão jurídica dos termos.
