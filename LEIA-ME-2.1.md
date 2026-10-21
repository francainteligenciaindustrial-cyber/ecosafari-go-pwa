# EcoSafari Go 2.1 — Perfil estilo Instagram + correção de segurança

## 1. Rodar o SQL (obrigatório, 2 min) — **faça isto primeiro**

Supabase → **SQL Editor** → cole `sql/ecosafari-go-migration-social-profile.sql` → **Run**.
Confira que é o projeto `wahmsrsnastxtqrxuufp`. Pode rodar de novo sem problema.

> ⚠️ **Este SQL corrige duas falhas de segurança que encontrei na auditoria.** Antes dele, qualquer pessoa com conta conseguia, pelo próprio app, se transformar em administradora (e se auto-verificar), e publicar avistamentos já "aprovados" sem passar pela equipe. As duas brechas ficam fechadas assim que o SQL rodar. Não houve sinal de uso indevido que eu possa ver daqui; para conferir no seu banco:
> ```sql
> select email, role, lodge_id from profiles where role in ('admin','guide') order by created_at;
> ```
> Todos os e-mails dessa lista precisam ser de pessoas que você conhece. Se aparecer alguém estranho, me avise.

O mesmo SQL também:
- cria o perfil social (@usuário, bio, link, capa, seguidores) e dá um @usuário automático para quem já tem conta;
- cria o bucket `user-covers` para fotos de capa;
- **sobe a versão dos termos**: na próxima abertura todos verão a tela "Antes de continuar" de novo. É de propósito: o perfil público muda o que fica visível, e a LGPD pede novo aceite.

## 2. Subir o app no GitHub (5 min)

Repositório `ecosafari-go-pwa` → **Add file → Upload files** → arraste tudo da pasta `app/` → **Commit changes**.
(Substitui `index.html`, `termos.html`, `privacidade.html`; os outros ficam iguais.)

## O que mudou no app

**Perfil (aba Perfil)**
- Foto de capa (botão 📷 no canto da capa) e foto de perfil (✏️ no avatar).
- Contadores de publicações, seguidores e seguindo; toque nos números para ver as listas.
- @usuário, bio (até 200 caracteres), link (Instagram, site…), selo de verificado.
- **Destaques**: uma bolinha por espécie já registrada; toque para filtrar a grade. O **＋** abre um novo avistamento.
- Abas: grade de publicações, vídeos e conquistas (com o ranking).
- Toque numa foto para abrir com descrição, curtidas e data.
- 🔍 buscar pessoas · ⚙️ configurações · **Compartilhar perfil**.
- Botão "Perfil público": desligado, só nome e foto aparecem.

**Link do perfil para o Instagram**
Em **Editar perfil** aparece "Seu link do EcoSafari Go" com botão copiar, no formato
`https://francainteligenciaindustrial-cyber.github.io/ecosafari-go-pwa/?u=seuusuario`.
Quem abrir sem ter conta vê o perfil público e um convite para criar conta; quem já tem conta cai direto no perfil.

**Check-in**
- A aba "Check-In" saiu da barra. No primeiro acesso, quem não validou a estadia vê uma tela cheia "Valide sua estadia" (pode tocar em "Explorar sem validar", e fica um aviso no topo do feed).
- Depois: **Perfil → ⚙️ → Minha hospedagem**, onde dá para validar um novo código ao mudar de pousada.
- A barra agora é: Avistamentos · **Mapa** · Alertas · Perfil.

**Outros**
- Os nomes e fotos dos autores no feed e nos comentários agora aparecem para qualquer hóspede (antes só a equipe conseguia ler esses dados).
- Política de privacidade atualizada com o perfil público.
- Apagar a conta também apaga bio, link, capa e @usuário.

## Limites que você precisa saber
- **Foto de capa e de perfil não passam pela moderação automática** (só as fotos de avistamento passam). Se alguém subir imagem imprópria, o botão "Denunciar" existe nas publicações, mas não no perfil ainda. Quando você tiver mais usuários, recomendo ligar a mesma checagem do Google Vision nesses dois buckets.
- **Prévia do link no WhatsApp/Instagram** (foto e nome aparecendo no cartão do link) não funciona com o site hospedado no GitHub Pages: o link abre certo, mas a prévia é genérica. Resolver exige um domínio próprio com um pequeno servidor; deixei fora por ora.
- Textos do perfil estão em português, inglês e espanhol; alemão, francês e russo mostram inglês nessas telas.
- Testei o código no navegador (com o Supabase simulado) e o SQL num Postgres real. Não testei em celular de verdade nem enviando foto de capa de verdade para o seu Storage.
