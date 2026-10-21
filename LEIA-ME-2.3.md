# EcoSafari Go 2.3 — Código e QR code da pousada

## Passo a passo (nesta ordem)
1. **SQL** — Supabase → SQL Editor → cole e rode **só este**: `sql/ecosafari-go-migration-lote3-codigo-pousada.sql`.
   (Se ainda não rodou os anteriores, rode antes, nesta ordem: `…social-profile.sql` → `…lote2.sql`.)
2. **App** — GitHub → repositório → **Add file → Upload files** → arraste **os arquivos de dentro da pasta `app/`** (não a pasta). Eles precisam ficar na **raiz** do repositório. Commit.
3. Espere 1–3 min, feche e reabra o app (no celular, remova o ícone e instale de novo).

## O que mudou
- **Cada pousada tem seu código, sorteado pelo sistema** (9 caracteres, sem 0/1/I/O para não confundir). O banco **impede** dois códigos iguais. Não existe mais código digitado à mão.
- **Correção de segurança importante:** o código antigo ficava numa tabela que qualquer usuário conseguia ler, ou seja, qualquer pessoa podia descobrir o código de qualquer pousada. Agora o código fica numa tabela privada; só o administrador da própria pousada vê. **Os códigos antigos foram apagados** e cada pousada ganhou um novo: reimprima os cartazes.
- **Painel do dono** (Perfil → Painel administrativo, no topo): QR code, código, **Imprimir cartaz com QR**, **Copiar link** e **Gerar novo código** (pede confirmação; o código e os QR antigos morrem na hora). Aparece para todos os planos.
- **Check-in do hóspede:** botão **Escanear QR code da pousada** abre a câmera dentro do app, lê o QR e valida sozinho. Também funciona escanear com a câmera do celular, ou digitar o código (aceita maiúsculas/minúsculas, hífen e espaço).
- Mantido o limite de 8 tentativas erradas em 15 minutos.

## Observações
- A câmera do app exige permissão do navegador; se o hóspede negar, aparece o aviso para digitar o código.
- O leitor foi testado com uma câmera simulada (leu o QR e validou). Teste uma vez num celular de verdade.
- Antes da 2.3, o código de check-in era um recurso só dos planos pagos; agora todas as pousadas têm. Se quiser voltar a restringir, me diga.
