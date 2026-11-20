/* テストプレイ部の service worker（build.py が VERSION の値（中身のハッシュ）を入れて、サイトの直下に sw.js として置く）
 *  - HTML：ネット優先。失敗したら前に見たページ、それも無ければ offline.html
 *  - CSS／JS／フォント／アイコン／イラスト：stale-while-revalidate（先にキャッシュを返し、裏で新しくする）
 *  - clips/*.mp4：キャッシュしない（容量。動画は Range で細かく取るので、そのままネットへ）
 *  - Supabase・functions・外のゲームの URL・POST には触らない（respondWith しない）
 *  - バージョンが変わると、古いキャッシュを全部消す
 */
const VERSION = "d0d597a2f7";
const STATIC = "tpb-static-" + VERSION, PAGES = "tpb-pages-" + VERSION;
const ROOT = new URL("./", self.location).href;
const OFFLINE = ROOT + "offline.html";
const MAX_PAGES = 30;
// 外でも、読み込むだけの部品（CSS・JS・フォント）は stale-while-revalidate してよい
const SHARED_HOSTS = ["fonts.googleapis.com", "fonts.gstatic.com", "cdn.jsdelivr.net"];

self.addEventListener("install", (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(STATIC);
    await Promise.all([OFFLINE, ROOT + "assets/icon-192.png"].map((u) => c.add(u).catch(() => {})));
    await self.skipWaiting();
  })());
});
self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith("tpb-") && k !== STATIC && k !== PAGES) await caches.delete(k);
    await self.clients.claim();
  })());
});

async function trim(cache, max) {
  const keys = await cache.keys();
  for (let i = 0; i < keys.length - max; i++) await cache.delete(keys[i]);
}
async function networkFirstPage(req) {
  const cache = await caches.open(PAGES);
  try {
    const res = await fetch(req);
    if (res && res.ok && res.type !== "opaqueredirect") { cache.put(req, res.clone()).then(() => trim(cache, MAX_PAGES)).catch(() => {}) }
    return res;
  } catch (err) {
    const hit = (await cache.match(req)) || (await cache.match(req, { ignoreSearch: true }));
    if (hit) return hit;
    const off = await (await caches.open(STATIC)).match(OFFLINE);
    return off || new Response("offline", { status: 503, headers: { "Content-Type": "text/plain" } });
  }
}
async function staleWhileRevalidate(req) {
  const cache = await caches.open(STATIC);
  const hit = await cache.match(req);
  const net = fetch(req).then((res) => { if (res && (res.ok || res.type === "opaque")) cache.put(req, res.clone()).catch(() => {}); return res }).catch(() => null);
  if (hit) { net.catch(() => {}); return hit }
  const res = await net;
  return res || new Response("", { status: 504 });
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const same = url.origin === self.location.origin;
  if (!same && !SHARED_HOSTS.includes(url.hostname)) return;           // Supabase・functions・外のゲームなどは、そのまま通す
  if (same && !url.href.startsWith(ROOT)) return;                       // このサイトの外のパスは触らない
  if (same && /\/clips\/.+\.mp4$/i.test(url.pathname)) return;           // 動画はキャッシュしない
  if (req.headers.has("range")) return;
  if (same && (req.mode === "navigate" || req.destination === "document" || req.destination === "iframe")) { e.respondWith(networkFirstPage(req)); return }
  if (same && /\.(json|webmanifest)$/i.test(url.pathname)) { e.respondWith(networkFirstPage(req)); return }
  const d = req.destination;
  if (["style", "script", "font", "image", "worker"].includes(d) || /\.(css|js|woff2?|png|jpe?g|webp|svg|ico)$/i.test(url.pathname) || url.hostname === "fonts.googleapis.com") {
    e.respondWith(staleWhileRevalidate(req)); return;
  }
});
