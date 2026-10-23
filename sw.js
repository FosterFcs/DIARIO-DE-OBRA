// Foster Obras — service worker
// Guarda o app no aparelho para abrir sem internet no canteiro.
// Dados (Supabase) nunca passam pelo cache: o app tem a própria fila offline.
const VERSAO = 'foster-obras-2026-10-23a';
const APP = ['./', './index.html', './manifest.json', './qrcode.min.js', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './favicon.ico', './apple-touch-icon.png', './icon-32.png', './icon-16.png'];
const CDN = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/dist/umd/supabase.js'];

self.addEventListener('install', e => {
    e.waitUntil(caches.open(VERSAO).then(async c => {
        await c.addAll(APP);
        await Promise.all(CDN.map(u => fetch(u, { mode: 'cors' }).then(r => r.ok && c.put(u, r)).catch(() => {})));
    }).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
    e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSAO).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
    const req = e.request;
    if (req.method !== 'GET') return;
    const url = new URL(req.url);
    // API, autenticação e fotos do Supabase: sempre direto na rede
    if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('supabase.in')) return;

    // páginas: rede primeiro (pega atualização), cópia guardada se estiver sem internet
    if (req.mode === 'navigate') {
        e.respondWith(fetch(req).then(r => {
            const copia = r.clone(); caches.open(VERSAO).then(c => c.put('./index.html', copia));
            return r;
        }).catch(() => caches.match('./index.html')));
        return;
    }

    const estatico = url.origin === location.origin || url.hostname === 'cdn.jsdelivr.net' || url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
    if (!estatico) return;
    // arquivos do app, biblioteca e fontes: cópia guardada na hora, atualiza em segundo plano
    e.respondWith(caches.match(req).then(salvo => {
        const rede = fetch(req).then(r => {
            if (r && (r.ok || r.type === 'opaque')) { const copia = r.clone(); caches.open(VERSAO).then(c => c.put(req, copia)); }
            return r;
        }).catch(() => salvo);
        return salvo || rede;
    }));
});
