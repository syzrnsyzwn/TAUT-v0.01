// TAUT service worker. Caches the app shell so it opens offline.
// Family data and logins (supabase.co) are NEVER cached here.
const V = "taut-v1";   // bump this number when you want every device to drop its old cache
const SHELL = ["./", "index.html", "manifest.webmanifest", "icons/icon-192.png", "icons/icon-512.png"];
self.addEventListener("install", e => e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())));
self.addEventListener("activate", e => e.waitUntil(
  caches.keys().then(k => Promise.all(k.filter(x => x !== V).map(x => caches.delete(x)))).then(() => clients.claim())));
self.addEventListener("fetch", e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== "GET" || u.hostname.endsWith("supabase.co")) return;
  if (r.mode === "navigate") {                       // pages: network first, cached copy when offline
    e.respondWith(fetch(r).then(x => { const c = x.clone(); caches.open(V).then(h => h.put("index.html", c)); return x; })
      .catch(() => caches.match("index.html")));
    return;
  }
  e.respondWith(caches.match(r).then(hit => {         // files: cached first, refreshed in the background
    const net = fetch(r).then(x => {
      if (x.ok && (u.origin === location.origin || u.hostname === "cdn.jsdelivr.net")) { const c = x.clone(); caches.open(V).then(h => h.put(r, c)); }
      return x; }).catch(() => hit);
    return hit || net; }));
});
