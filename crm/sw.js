/* Экспресс Оптика CRM — работа без интернета.
   Страница и файлы CRM берутся из сети, а при её отсутствии — из сохранённой копии. */
const CACHE = 'eocrm-2.0.0';
const FILES = ['./', './index.html', './supabase.js', './app.webmanifest', './icon-192.png', './icon-512.png'];
const OFFLINE = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CRM</title><p style="font-family:system-ui,Arial,sans-serif;padding:24px;line-height:1.5">Нет интернета, а CRM ещё ни разу не открывалась на этом компьютере.<br>Откройте её один раз при подключённом интернете — после этого она будет работать и без него.</p>';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k.indexOf('eocrm-') === 0 && k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;               // запросы к базе идут мимо
  const scope = new URL(self.registration.scope).pathname;    // /crm/
  if (url.pathname.indexOf(scope) !== 0) return;
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put('./index.html', copy)); }
        return res;
      }).catch(() => caches.match('./index.html').then(r => r || new Response(OFFLINE, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })))
    );
    return;
  }
  // файлы CRM: сначала сеть (чтобы обновления приходили сразу), без сети — копия
  e.respondWith(
    fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req))
  );
});
