// EcoSafari Go — service worker
// - Deixa o app instalável na tela inicial
// - Recebe notificações push com o app fechado
// Não guarda páginas em cache: o app sempre busca a versão mais nova.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (event) => { event.respondWith(fetch(event.request)); });

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) { data = { body: event.data && event.data.text() }; }
  const title = data.title || 'EcoSafari Go';
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || 'Novo avistamento perto de você.',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    tag: data.tag || 'ecosafari-alert',
    data: { url: data.url || './index.html' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || './index.html';
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) { c.postMessage({ type: 'open-alerts' }); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
