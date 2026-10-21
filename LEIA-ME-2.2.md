# EcoSafari Go 2.2 — Segurança, proteção de menores e novas funções

## Ordem (importante: SQL primeiro, app depois)

1. **SQL.** Supabase → SQL Editor. Se ainda **não** rodou a 2.1, rode primeiro `sql/ecosafari-go-migration-social-profile.sql`. Depois rode `sql/ecosafari-go-migration-lote2.sql`. Ambos podem ser repetidos sem problema. Conferir que é o projeto `wahmsrsnastxtqrxuufp`.
2. **App.** GitHub → repositório `ecosafari-go-pwa` → Add file → Upload files → arraste o conteúdo de `app/` → Commit.
3. **Painel da plataforma.** Substitua o `index.html` do painel por `dashboard/index.html` (nova aba **Piloto e moderação**).
4. Feche e reabra o app (ou reinstale o PWA). Todos verão de novo a tela de aceite: a política de privacidade mudou.

Como saber que deu certo: ao abrir **Perfil → Editar perfil** aparece a chave "Compartilhar meus avistamentos com a ciência"; no feed aparece o cartão **Bingo de espécies**; no painel do dono aparece **O que o app rendeu**.

## O que entrou

**Segurança e privacidade**
- **Espécies ameaçadas** (onça, ariranha, harpia, arara-azul, tartarugas, muriqui…): o mapa e o público veem só uma área de ~11 km; a posição exata fica guardada e só o autor, a equipe da pousada e a plataforma enxergam. A lista editável está na tabela `sensitive_species_patterns`.
- **Menores de idade:** data de nascimento obrigatória no cadastro; abaixo de 13 anos não cadastra; de 13 a 17 exige a declaração do responsável. Perfil de menor é sempre privado, sem link externo e fora do compartilhamento científico (o banco impõe, não só a tela).
- **Limite de tentativas** nos códigos de reserva/pousada: 8 erros em 15 minutos bloqueiam por um tempo. Isso impede adivinhar o código da recepção.
- **CAPTCHA** (Cloudflare Turnstile) no cadastro e no login — liga quando você colar a chave (ver CONFIGURACAO.md, seção 16). Sem chave, fica desligado e nada quebra.
- **Moderação de capa e foto:** botão ⚑ **Denunciar** nos perfis (as denúncias chegam na aba Piloto e moderação) + função automática `moderate-image` que apaga imagens impróprias (ver seção 17).
- **Testes automáticos** (GitHub Actions) para as regras de permissão: se alguém quebrar uma regra de segurança, o GitHub avisa antes de ir ao ar (seção 18).

**Para o hóspede**
- **Bingo de espécies da pousada:** progresso "X de N" e uma grade com o que já viu (aprovado ou aguardando).
- **Doar moedas** para o parceiro de conservação da pousada (5, 10 ou 25).
- **Compartilhar com a ciência** (desligado por padrão).
- **QR code:** quem escaneia entra já com o código da pousada preenchido.

**Para o dono da pousada**
- **QR code para imprimir** (Painel → Código de check-in compartilhado → "QR code da pousada"). Coloque na recepção e nos quartos.
- **O que o app rendeu (30 dias):** hóspedes validados, % que publicou, avistamentos, fotos/vídeos, espécies, moedas emitidas/resgatadas/doadas.
- **Orçamento mensal de moedas:** medidor que fica amarelo a 80% e vermelho a 100%. É um aviso, não bloqueia aprovações.
- **Lista de espécies do bingo** (marque o que dá para ver aí).
- **Exportar para a ciência:** CSV no padrão Darwin Core (o que o GBIF usa), só com hóspedes que aceitaram compartilhar.

**Para você (plataforma)**
- Aba **Piloto e moderação**: por pousada, hóspedes, % que publica, ativos em 30 dias, moedas, e uma etiqueta de saúde; abaixo, as denúncias abertas (Resolvida / Descartar).
- `docs/ROTEIRO-PILOTO.md`: como rodar o piloto de 30 dias com 3 pousadas.

## O que eu testei e o que não consegui testar

Testado: todo o SQL num PostgreSQL 16 com PostGIS real (51 verificações de permissão e regra de negócio, mais reaplicação sem erro); toda a interface em navegador automatizado (cadastro de menor/maior, bloqueio sem responsável, CAPTCHA, link `?j=`, bingo, doação, denúncia, painel do dono, QR, perfil de menor).

**Não testado de verdade** (depende de contas suas): o widget Turnstile com chave real, a função `moderate-image` com o Google Vision, a escaneada do QR em celular físico, e o workflow do GitHub Actions rodando no GitHub. Vale um teste rápido de cada na primeira semana.

## Limites que continuam valendo
- Moderação automática só pega imagem explícita; o resto depende das denúncias. Combine quem vai olhar a aba de denúncias (sugestão: toda segunda).
- A lista de espécies sensíveis é por nome. Se uma pousada cadastrar a espécie com grafia diferente, ela não é reconhecida — revise a tabela de tempos em tempos.
- Antes de clientes reais, os termos de uso e a política de privacidade ainda precisam de revisão por advogado(a), principalmente a parte de menores e de compartilhamento científico.
