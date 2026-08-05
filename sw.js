// Service worker mínimo — só o suficiente para o app ser considerado
// "instalável" (exigência técnica de qualquer PWA/APK gerado a partir
// dele). Não faz cache agressivo de propósito, já que o app sempre
// precisa buscar dados atualizados do Supabase.
self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  // Deixa passar direto para a rede — não intercepta nada.
  event.respondWith(fetch(event.request));
});
