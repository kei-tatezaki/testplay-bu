/* ウェブアプリ化（PWA）：service worker の登録・ホーム画面への追加の案内・「アプリとして使う」
 *  - sw.js は build.py がバージョンを付けて作る（ビルドごとに古いキャッシュを消す）
 *  - 案内は自動で出る：Android／PCのChromeは beforeinstallprompt を取っておいて「追加する」で prompt()、iOS の Safari は共有ボタンの手順を図つきで。
 *    出すのは、2回目の訪問／作品を2本以上遊んだ／感想を送ったあと、のどれか。最初の訪問の直後は出さない。
 *    「あとで」を押す・一度出したら14日は出さない。追加済み（standalone／appinstalled）なら出さない。
 *  - メニューとマイページの「アプリとして使う」は、押すと案内を出す
 */
(function () {
  "use strict";
  var T = window.TPB; if (!T) return;
  var el = T.el, S = T.store, P = T.pwa = {};
  var DAY = 86400000, QUIET = 14 * DAY;
  var mq = matchMedia("(display-mode: standalone)");
  var ua = navigator.userAgent || "";
  var isIOS = /iP(hone|ad|od)/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  var isIOSSafari = isIOS && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|Line\/|Instagram|FBAN|FBAV|Twitter|TikTok/.test(ua);
  var deferred = null;

  P.standalone = function () { return mq.matches || navigator.standalone === true };
  document.documentElement.classList.toggle("tpb-standalone", P.standalone());
  var st = function () { var o = S.get("pwa", {}); return o && typeof o === "object" ? o : {} };
  var save = function (o) { S.set("pwa", o) };

  // ---- service worker ----
  if ("serviceWorker" in navigator && (location.protocol === "https:" || /^(localhost|127\.0\.0\.1)$/.test(location.hostname))) {
    var go = function () {
      var u = new URL(T.base + "sw.js", location.href), scope = new URL(T.base, location.href).href;
      navigator.serviceWorker.register(u.href, { scope: scope }).then(function (r) { try { r.update() } catch (e) {} }).catch(function () {});
    };
    if (document.readyState === "complete") go(); else addEventListener("load", go);
  }

  // ---- 訪問の数（ブラウザを開いてから1回だけ数える） ----
  try {
    if (!sessionStorage.getItem("tpb:pwaV")) { sessionStorage.setItem("tpb:pwaV", "1"); var o0 = st(); o0.visits = (o0.visits || 0) + 1; save(o0) }
  } catch (e) {}
  if (P.standalone()) { var o1 = st(); if (!o1.installed) { o1.installed = true; save(o1) } }
  addEventListener("appinstalled", function () { var o = st(); o.installed = true; save(o); hide(); deferred = null });
  addEventListener("beforeinstallprompt", function (e) { e.preventDefault(); deferred = e; setTimeout(P.check, 1500) });

  // ---- 見た目 ----
  var css = ".pwa-bn{position:fixed;left:50%;bottom:calc(12px + env(safe-area-inset-bottom));transform:translateX(-50%);width:min(440px,calc(100% - 20px));z-index:92;background:var(--card,#FFFDF8);color:var(--ink,#2A241E);border:1px solid var(--ink,#2A241E);border-radius:6px;box-shadow:0 8px 30px rgba(0,0,0,.3);padding:12px 14px;display:grid;gap:10px;font-size:14px;line-height:1.6;font-family:var(--f-body,'Noto Sans JP',system-ui,sans-serif)}" +
    "@media (prefers-reduced-motion:no-preference){.pwa-bn{animation:pwaUp .25s ease-out}@keyframes pwaUp{from{opacity:0;transform:translate(-50%,24px)}}}" +
    ".pwa-bn h2{margin:0;font-size:15px;line-height:1.5}.pwa-bn p{margin:0}.pwa-bn ol{margin:0;padding-left:1.3em;display:grid;gap:2px}" +
    ".pwa-bn .pwa-row{display:flex;gap:8px;flex-wrap:wrap}" +
    ".pwa-bn button{font:inherit;font-size:14px;font-weight:700;min-height:44px;padding:6px 16px;border-radius:6px;cursor:pointer;border:1px solid var(--ink,#2A241E);background:transparent;color:var(--ink,#2A241E);font-family:var(--f-rd,inherit)}" +
    ".pwa-bn button.pwa-go{background:var(--shu,#C8401F);border-color:var(--shu,#C8401F);color:#fff;box-shadow:0 3px 0 #8E2C14}.pwa-bn button.pwa-go:active{transform:translateY(3px);box-shadow:none}" +
    ".pwa-bn svg.pwa-fig{width:100%;max-width:240px;height:auto;justify-self:center;display:block}" +
    ".tpb-standalone .top{padding-top:calc(16px + env(safe-area-inset-top))!important}.tpb-standalone .ftabs{top:calc(16px + env(safe-area-inset-top))!important}.tpb-standalone header.bar{padding-top:calc(6px + env(safe-area-inset-top))}";
  document.head.append(el("style", null, css));

  // iOS Safari：共有ボタン（画面下の中央）を指す図
  function fig() {
    var ns = "http://www.w3.org/2000/svg", s = document.createElementNS(ns, "svg");
    s.setAttribute("viewBox", "0 0 240 150"); s.setAttribute("class", "pwa-fig"); s.setAttribute("role", "img"); s.setAttribute("aria-label", "Safari の画面の下の中央にある共有ボタンを押す、という図");
    s.innerHTML = '<rect x="70" y="4" width="100" height="142" rx="14" fill="#fff" stroke="#2A241E" stroke-width="2"/>' +
      '<rect x="78" y="14" width="84" height="84" rx="4" fill="#EFE6D3"/>' +
      '<rect x="71" y="108" width="98" height="37" rx="0" fill="#EFE6D3" stroke="none"/><path d="M71 108h98" stroke="#DCCFB8" stroke-width="1.5"/>' +
      '<circle cx="120" cy="127" r="14" fill="#E2A93B"/>' +
      '<g fill="none" stroke="#2A241E" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M120 134v-14M115.5 124.5l4.5-4.5 4.5 4.5M112 126v8a2 2 0 002 2h12a2 2 0 002-2v-8" /></g>' +
      '<path d="M190 100l-52 22" stroke="#C8401F" stroke-width="2.5" stroke-linecap="round"/><path d="M142 114l-9 9 12 3" fill="none" stroke="#C8401F" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>' +
      '<text x="192" y="96" font-size="11" fill="#2A241E" font-weight="700" text-anchor="start" font-family="sans-serif">ここ</text>';
    return s;
  }

  function hide() { var b = document.getElementById("pwaBn"); if (b) b.remove() }
  function blocked() {
    return !!(document.getElementById("tpbOv") || document.querySelector(".sheet-bg.open") || document.querySelector("#player.open") || document.getElementById("ageGate"));
  }
  P.kind = function () { return deferred ? "prompt" : isIOSSafari ? "ios" : isIOS ? "ios-other" : "manual" };
  // force：メニューから押したとき（条件を見ず、いつでも出す）
  P.openGuide = function (force) {
    hide();
    var k = P.kind(), ttl = "ホーム画面に追加すると、アプリのようにすぐ開けます", box = el("div", { class: "pwa-bn", id: "pwaBn", role: "dialog", "aria-label": "アプリとして使う" }), later;
    box.append(el("h2", null, ttl));
    var go = null;
    if (k === "prompt") {
      go = el("button", { type: "button", class: "pwa-go", onclick: function () {
        var d = deferred; deferred = null; if (!d) return;
        try { d.prompt(); d.userChoice.then(function (r) { var o = st(); o.at = Date.now(); if (r && r.outcome === "accepted") o.installed = true; save(o) }).catch(function () {}) } catch (e) {}
        hide();
      } }, "追加する");
    } else if (k === "ios") {
      box.append(fig(), el("ol", null, el("li", null, "画面の下の中央にある、共有ボタン（四角から上向きの矢印）を押す"), el("li", null, "「ホーム画面に追加」を選ぶ"), el("li", null, "右上の「追加」を押す")));
    } else if (k === "ios-other") {
      box.append(el("p", null, "このブラウザでは追加できないことがあります。Safari でこのページを開いて、共有ボタン（画面の下の中央）から「ホーム画面に追加」を選んでください。"));
    } else {
      box.append(el("p", null, "ブラウザのメニュー（⋮ や共有）から「ホーム画面に追加」または「アプリをインストール」を選んでください。このブラウザでは、ボタンからの追加はできません。"));
    }
    later = el("button", { type: "button", onclick: function () { var o = st(); o.at = Date.now(); save(o); hide() } }, force ? "とじる" : "あとで");
    box.append(el("div", { class: "pwa-row" }, go, later));
    document.body.append(box);
    if (go) go.focus({ preventScroll: true }); else later.focus({ preventScroll: true });
    var o = st(); o.at = Date.now(); save(o);   // 一度出したら14日は自動では出さない
  };
  // 自動の案内を出してよいか見て、よければ出す（読み込み後・作品を遊んだあと・感想を送ったあとに呼ぶ）
  var tries = 0;
  P.check = function () {
    if (P.standalone() || document.getElementById("pwaBn")) return;
    if (/\/(admin|dev)(\.html)?\/?$/.test(location.pathname)) return;
    var o = st(); if (o.installed) return;
    if (o.at && Date.now() - o.at < QUIET) return;
    var played = (S.get("played", []) || []).length, sent = (S.get("sent", []) || []).length;
    if (!((o.visits || 0) >= 2 || played >= 2 || sent >= 1)) return;
    if (!(deferred || isIOSSafari)) return;
    if (blocked()) { if (tries++ < 8) setTimeout(P.check, 4000); return }
    P.openGuide(false);
  };
  setTimeout(P.check, 4000);

  // ---- 「アプリとして使う」の常設の入口（マイページ・PCのサイドバー）。追加済みなら出さない ----
  P.link = function (cls, text) {
    if (P.standalone() || st().installed) return null;
    return el("button", { type: "button", class: cls || "pwa-link", "data-pwa-open": "", onclick: function () { P.openGuide(true) } }, text || "アプリとして使う");
  };
  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("[data-pwa-slot]").forEach(function (h) { var b = P.link(h.getAttribute("data-pwa-slot") || "btn ghost"); if (b) h.append(b); else h.hidden = true });
    var f = document.querySelector(".tpb-side .sd-foot");
    if (f && !P.standalone() && !st().installed) { var a = el("a", { href: "#", "data-pwa-open": "", onclick: function (e) { e.preventDefault(); P.openGuide(true) } }, "アプリとして使う"); f.append(a) }
  });
})();
