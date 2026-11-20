/* テストプレイ部：どのページでも使う部品
 *  - 作る人のアイコン／プロフィールへのリンク
 *  - 作品の「⋮」メニュー（作品ページ・ショートで見る・作った人・共有・報告。作者本人には数字と直しの依頼も）
 *  - 報告する
 *  - 右上の「自分のアイコン」（マイページへ）
 * データは assets/data.js（build.py が作る）の window.TPB_DATA を使う。
 */
(function () {
  "use strict";
  var D = window.TPB_DATA || { games: [], creators: {} };
  var SB_URL = D.sbUrl || "https://jwrzqaxuvmdbroemenng.supabase.co";
  var SB_KEY = D.sbKey || "sb_publishable_eEHa90AqCPKyQuo7jjMasA_sGbpPh2u";
  var me = document.currentScript && document.currentScript.src || "";
  var BASE = me.replace(/assets\/tpb\.js.*$/, "");
  var T = window.TPB = { SB_URL: SB_URL, SB_KEY: SB_KEY, base: BASE, games: D.games, creators: D.creators };

  T.store = {
    get: function (k, d) { try { var v = JSON.parse(localStorage.getItem("tpb:" + k)); return v == null ? d : v } catch (e) { return d } },
    set: function (k, v) { try { localStorage.setItem("tpb:" + k, JSON.stringify(v)) } catch (e) {} }
  };
  T.cid = function () {
    var c = T.store.get("cid", "");
    if (!c) { c = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()); T.store.set("cid", c) }
    return c;
  };
  T.esc = function (s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] }) };
  T.game = function (slug) { for (var i = 0; i < T.games.length; i++) if (T.games[i].slug === slug) return T.games[i]; return null };
  T.el = function (tag, attrs) {
    var n = document.createElement(tag), k;
    for (k in (attrs || {})) {
      var v = attrs[k]; if (v == null || v === false) continue;
      if (k === "class") n.className = v; else if (k === "text") n.textContent = v;
      else if (k.slice(0, 2) === "on") n.addEventListener(k.slice(2), v); else n.setAttribute(k, v === true ? "" : v);
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i]; if (c == null || c === false) continue;
      if (Array.isArray(c)) c.forEach(function (x) { if (x != null && x !== false) n.append(x.nodeType ? x : document.createTextNode(String(x))) });
      else n.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return n;
  };
  var el = T.el;

  // ---- Supabase ----
  var _sb = null;
  T.sb = function () { if (!_sb && window.supabase) _sb = window.supabase.createClient(SB_URL, SB_KEY); return _sb };
  T.session = async function () { var sb = T.sb(); if (!sb) return null; try { var r = await sb.auth.getSession(); return r.data.session } catch (e) { return null } };
  T.maybeLoggedIn = function () { try { return !!localStorage.getItem("sb-jwrzqaxuvmdbroemenng-auth-token") } catch (e) { return false } };
  // ログインなしで呼べる関数
  T.pub = async function (name, args) {
    try {
      var ctl = new AbortController(), t = setTimeout(function () { ctl.abort() }, 6000);
      var r = await fetch(SB_URL + "/rest/v1/rpc/" + name, { method: "POST", signal: ctl.signal, headers: { apikey: SB_KEY, "Content-Type": "application/json" }, body: JSON.stringify(args || {}) });
      clearTimeout(t); if (!r.ok) return null; return await r.json();
    } catch (e) { return null }
  };
  var _live = null;
  // 作品ごとの作者（管理ページで決めた作者のプロフィール）
  T.liveCreators = function () {
    if (!_live) _live = T.pub("game_creators").then(function (rows) { var o = {}; (rows || []).forEach(function (r) { o[r.game_slug] = { handle: r.handle, name: r.name, avatar: r.avatar_url } }); return o });
    return _live;
  };
  var _mine = null;
  T.myGames = function () {
    if (!_mine) _mine = (async function () {
      if (!T.maybeLoggedIn()) return [];
      var s = await T.session(); if (!s) return [];
      try { var r = await T.sb().rpc("dev_games"); return (r.data || []).map(function (x) { return x.game_slug }) } catch (e) { return [] }
    })();
    return _mine;
  };

  // ---- 作る人 ----
  T.creatorOf = function (g, live) {
    if (live && live[g.slug]) return live[g.slug];
    var c = g.creator && T.creators[g.creator];
    if (c) return { handle: g.creator, name: c.name, avatar: c.avatar ? BASE + c.avatar : "", official: !!c.official };
    return { handle: "", name: g.author || "ななし", avatar: "" };
  };
  T.profileUrl = function (h) { return BASE + "profile.html?u=" + encodeURIComponent(h) };
  var COLORS = ["#C8401F", "#2F5D9B", "#7A5C1E", "#A8437D", "#3f7d3a", "#8E2C14", "#5B4B8A"];
  T.avatar = function (c, size) {
    size = size || 40;
    var st = "width:" + size + "px;height:" + size + "px;font-size:" + Math.round(size * .42) + "px";
    if (c && c.avatar) {
      var im = el("img", { class: "tpb-av", src: c.avatar, alt: "", width: size, height: size, style: st, loading: "lazy" });
      im.addEventListener("error", function () { im.replaceWith(initial()) });
      return im;
    }
    function initial() {
      var name = (c && c.name) || "?", h = 0; for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
      return el("span", { class: "tpb-av", style: st + ";background:" + COLORS[h % COLORS.length], "aria-hidden": "true" }, Array.from(name)[0] || "?");
    }
    return initial();
  };

  // ---- お知らせ（下に少しだけ出る） ----
  var toastT = 0;
  T.toast = function (text, ms) {
    var t = document.getElementById("tpbToast") || document.body.appendChild(el("div", { id: "tpbToast", class: "tpb-toast", role: "status" }));
    t.textContent = text; t.classList.add("show"); clearTimeout(toastT); toastT = setTimeout(function () { t.classList.remove("show") }, ms || 2600);
  };
  T.share = async function (title, url) {
    try {
      if (navigator.share && matchMedia("(pointer:coarse)").matches) { await navigator.share({ title: title, url: url }); return }
      await navigator.clipboard.writeText(url); T.toast("リンクをコピーしたよ");
    } catch (e) { if (e && e.name === "AbortError") return; prompt("このリンクをコピーしてね", url) }
  };

  // ---- 端末の「戻る」で箱を閉じる ----
  // 箱を開くとき layer.open(名前, 閉じる関数)、画面の中のボタンで閉じるとき layer.close(名前)。
  // 「戻る」を押すと、いちばん上の箱だけが閉じる（サイトから出てしまわない）。
  var stack = [], ignore = 0;
  function flush() { if (ignore > 0) return; stack.forEach(function (l) { if (!l.pushed) { l.pushed = true; try { history.pushState({ tpbLayer: l.name }, "") } catch (e) {} } }) }
  T.layer = {
    open: function (name, onBack) {
      for (var i = 0; i < stack.length; i++) if (stack[i].name === name) { stack[i].onBack = onBack; return }
      stack.push({ name: name, onBack: onBack, pushed: false }); flush();
    },
    close: function (name) {
      for (var i = 0; i < stack.length; i++) if (stack[i].name === name) {
        var l = stack.splice(i, 1)[0];
        if (l.pushed) { ignore++; history.back() }
        return;
      }
    },
    has: function (name) { return stack.some(function (l) { return l.name === name }) }
  };
  addEventListener("popstate", function () {
    if (ignore > 0) { ignore--; flush(); return }
    var l = stack.pop(); if (l) l.onBack();
  });

  // ---- 重ねて出す箱（メニュー・報告） ----
  var lastFocus = null;
  function overlay(kind, box, anchor) {
    closeOverlay();
    lastFocus = anchor || document.activeElement;
    var ov = el("div", { class: "tpb-ov " + kind, id: "tpbOv" }, box);
    ov.addEventListener("click", function (e) { if (e.target === ov) closeOverlay() });
    document.body.append(ov);
    T.layer.open("tpbOv", function () { closeOverlay() });
    if (kind === "menu" && anchor && innerWidth >= 600) {
      box.style.position = "fixed";
      ov.place = function () {
        var r = anchor.getBoundingClientRect(), w = box.offsetWidth, h = box.offsetHeight;
        box.style.left = Math.max(8, Math.min(r.right - w, innerWidth - w - 8)) + "px";
        box.style.top = (r.bottom + h + 8 > innerHeight ? Math.max(8, Math.min(r.top - h - 6, innerHeight - h - 8)) : r.bottom + 6) + "px";
      };
      ov.place();
    } else ov.classList.add("tpb-sheet");
    var f = box.querySelector("button,a,[tabindex]"); if (f) f.focus();
    return ov;
  }
  function closeOverlay() {
    var ov = document.getElementById("tpbOv"); if (!ov) return;
    T.layer.close("tpbOv");
    ov.remove(); if (lastFocus && lastFocus.focus) try { lastFocus.focus() } catch (e) {}
  }
  T.closeOverlay = closeOverlay;
  // 中央（スマホでは下から）に出す箱。スタンプカードなどが使う。Esc・「戻る」・Tab の回り方は、ほかの箱と同じ
  T.dialog = function (box, anchor) { return overlay("dialog", box, anchor) };
  document.addEventListener("keydown", function (e) {
    var ov = document.getElementById("tpbOv"); if (!ov) return;
    if (e.key === "Escape") { e.stopPropagation(); closeOverlay(); return }
    if (e.key === "Tab") {
      // 開いている箱の中だけでフォーカスが回るようにする
      var f = [].slice.call(ov.querySelectorAll("a[href],button:not([disabled]),textarea,input,select")).filter(function (x) { return x.offsetParent && !x.hidden });
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus() }
      else if (!ov.contains(document.activeElement)) { e.preventDefault(); first.focus() }
    }
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      var items = [].slice.call(ov.querySelectorAll(".tpb-mi")); if (!items.length) return;
      var i = items.indexOf(document.activeElement); e.preventDefault();
      items[(i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length].focus();
    }
  }, true);

  function mi(icon, label, o) {
    var kids = [el("span", { class: "tpb-ic", "aria-hidden": "true" }, icon), el("span", null, label)];
    if (o.href) return el("a", { class: "tpb-mi" + (o.cls ? " " + o.cls : ""), href: o.href, role: "menuitem" }, kids);
    return el("button", { class: "tpb-mi" + (o.cls ? " " + o.cls : ""), type: "button", role: "menuitem", onclick: o.onclick }, kids);
  }

  // 作品の「⋮」メニュー
  T.openMenu = function (btn, slug, opt) {
    opt = opt || {};
    var g = T.game(slug); if (!g) return;
    var url = (D.base || BASE.replace(/\/$/, "")) + "/games/" + slug + "/";
    var box = el("div", { class: "tpb-menu", role: "menu", "aria-label": g.title + " のメニュー" });
    box.append(el("div", { class: "tpb-mt" }, g.title));
    if (!opt.inFeed) box.append(mi("▶", "ショートで見る", { href: BASE + "?g=" + slug }));
    if (!opt.inPage) box.append(mi("📄", "作品ページを見る", { href: BASE + "games/" + slug + "/" }));
    box.append(mi("📅", "今日のスタンプカード" + (T.mission ? "（" + T.mission.counts().n + "/3）" : ""), { onclick: function () { if (T.mission) T.mission.openCard(btn); else location.href = BASE + "me.html#stamp" } }));
    var who = mi("👤", "作った人を見る", { href: "#" }); who.hidden = true; box.append(who);
    box.append(mi("🔗", "共有する（リンクをコピー）", { onclick: function () { closeOverlay(); T.share(g.title + "｜テストプレイ部", url) } }));
    var own = el("div", { hidden: true },
      el("div", { class: "tpb-ms" }, "あなたの作品"),
      mi("📊", "数字と感想を見る", { href: BASE + "dev.html?g=" + slug }),
      mi("✏️", "直したいところを運営に送る", { href: BASE + "submit.html?edit=" + slug }));
    box.append(own);
    box.append(mi("🚩", "報告する", { cls: "warn", onclick: function () { T.report("game", slug, g.title, btn) } }));
    box.append(el("button", { class: "tpb-mi tpb-mx", type: "button", onclick: closeOverlay }, "とじる"));
    var ov = overlay("menu", box, btn);
    function again() { if (ov.place && ov.isConnected) ov.place() }
    function setWho(c) { if (c.handle && !opt.inProfile) { who.href = T.profileUrl(c.handle); who.lastChild.textContent = "作った人を見る（" + c.name + "）"; who.hidden = false; again() } }
    setWho(T.creatorOf(g));
    T.liveCreators().then(function (live) { setWho(T.creatorOf(g, live)) });
    T.myGames().then(function (mine) { if (mine.indexOf(slug) >= 0) { own.hidden = false; again() } });
  };
  // data-menu="作品ID" が付いたボタンを押したらメニューを出す
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-menu]"); if (!b) return;
    e.preventDefault(); e.stopPropagation();
    T.openMenu(b, b.getAttribute("data-menu"), { inProfile: b.hasAttribute("data-in-profile"), inPage: b.hasAttribute("data-in-page") });
  });
  T.menuBtn = function (slug, title, extra) {
    var a = { class: "tpb-kebab", type: "button", "data-menu": slug, "aria-label": title + " のメニュー", "aria-haspopup": "menu" };
    if (extra) a[extra] = true;
    return el("button", a, "⋮");
  };

  // ---- 報告する ----
  var REASONS = [["broken", "動かない・遊べない"], ["bad_content", "いやな気持ちになる内容がある"], ["rating", "年齢制限が合っていない"],
    ["copy", "ほかの人の作品をまねている"], ["spam", "宣伝・いたずら"], ["other", "そのほか"]];
  // opt.reasons：選べる理由を絞る ／ opt.prefix：くわしくの前につける文字（感想の報告で、どの感想かを運営に伝える） ／ opt.sub：説明の文
  T.report = function (kind, target, label, anchor, opt) {
    opt = opt || {};
    var pick = "", msg = el("p", { class: "tpb-msg", "aria-live": "polite" });
    var opts = el("div", { class: "tpb-opts", role: "radiogroup", "aria-label": "理由" }, REASONS.filter(function (r) { return opt.reasons ? opt.reasons.indexOf(r[0]) >= 0 : (kind === "game" || (r[0] !== "broken" && r[0] !== "rating")) }).map(function (r) {
      return el("button", { type: "button", class: "tpb-opt", role: "radio", "aria-checked": "false", onclick: function (e) {
        pick = r[0]; opts.querySelectorAll(".tpb-opt").forEach(function (x) { x.setAttribute("aria-checked", String(x === e.currentTarget)) });
      } }, r[1]);
    }));
    var ta = el("textarea", { maxlength: 400 - (opt.prefix || "").length, placeholder: "くわしく（書かなくてもOK）", "aria-label": "くわしく" });
    var send = el("button", { class: "tpb-btn", type: "button" }, "報告を送る");
    send.addEventListener("click", async function () {
      if (!pick) { msg.className = "tpb-msg err"; msg.textContent = "理由をひとつ選んでね"; return }
      send.disabled = true; msg.className = "tpb-msg"; msg.textContent = "送信中…";
      var headers = { apikey: SB_KEY, "Content-Type": "application/json" };
      var s = T.maybeLoggedIn() ? await T.session() : null; if (s) headers.Authorization = "Bearer " + s.access_token;
      var ok = false, err = "";
      try {
        var r = await fetch(SB_URL + "/rest/v1/rpc/report_send", { method: "POST", headers: headers, body: JSON.stringify({ p_kind: kind, p_target: target, p_reason: pick, p_detail: ((opt.prefix || "") + ta.value).slice(0, 400), p_client: T.cid() }) });
        ok = r.ok; if (!ok) err = ((await r.json()) || {}).message || "";
      } catch (e) {}
      send.disabled = false;
      if (ok) { box.replaceChildren(el("h3", null, "報告を受けとりました"), el("p", { class: "tpb-sub" }, "ありがとう。運営が確かめます。"), el("button", { class: "tpb-btn ghost", type: "button", onclick: closeOverlay }, "とじる")); box.querySelector("button").focus() }
      else { msg.className = "tpb-msg err"; msg.textContent = err === "too_many" ? "今日はもう報告を送れません（1日5件まで）" : err === "banned" ? "この端末からは報告を送れません" : "送れなかった…時間をおいてもう一度試してね" }
    });
    var box = el("div", { class: "tpb-dialog", role: "dialog", "aria-modal": "true", "aria-label": "報告する" },
      el("h3", null, "報告する"), el("p", { class: "tpb-sub" }, opt.sub || ("「" + label + "」について、運営に知らせます。作った人に、だれが報告したかは伝わりません。")),
      opts, ta, msg, send, el("button", { class: "tpb-btn ghost", type: "button", onclick: closeOverlay }, "やめる"));
    overlay("dialog", box, anchor);
  };

  // ---- 右上の自分のアイコン ----
  T.mountMe = function (host) {
    if (!host) return;
    var a = el("a", { class: "tpb-me", href: BASE + "me.html", "aria-label": "マイページ" });
    function draw(p) {
      a.replaceChildren();
      if (p) { a.append(T.avatar({ name: p.name, avatar: p.avatar_url }, 32)); a.setAttribute("aria-label", "マイページ（" + p.name + "）"); a.classList.add("in") }
      else { a.append(el("span", { class: "tpb-av guest", "aria-hidden": "true", style: "width:32px;height:32px" }, "👤"), el("span", { class: "tpb-me-t" }, "ログイン")); a.classList.remove("in") }
    }
    var cached = T.maybeLoggedIn() ? T.store.get("me", null) : null;
    draw(cached); host.append(a);
    if (!T.maybeLoggedIn()) { T.store.set("me", null); return }
    T.session().then(async function (s) {
      if (!s) { T.store.set("me", null); draw(null); return }
      var m = s.user.user_metadata || {}, p = null;
      try { p = (await T.sb().rpc("my_profile")).data } catch (e) {}
      var v = { name: (p && p.name) || m.full_name || m.name || (s.user.email || "").split("@")[0] || "あなた", avatar_url: (p && p.avatar_url) || "", handle: (p && p.handle) || "" };
      T.store.set("me", v); draw(v);
    });
  };

  // ---- 作品の小さいカード（プロフィール・マイページ用。まとめのカードと同じ見た目） ----
  var PLAT = { pc: "PCのみ", sp: "スマホのみ", both: "PC・スマホ" };
  T.tile = function (g, stat, o) {
    o = o || {};
    var subParts = [PLAT[g.platform] || "", g.genre || ""].filter(Boolean), sub = [];
    subParts.forEach(function (x, i) { if (i) sub.push(" ・ "); sub.push(el("span", { style: "white-space:nowrap" }, x)) });  // ジャンルは途中で切らず、折り返す
    var st = []; if (stat && (stat.plays || 0) + (stat.feedbacks || 0) >= 10) { if (stat.plays) st.push("遊んだ人 " + stat.plays + "人"); if (stat.feedbacks) st.push("感想 " + stat.feedbacks + "件") }
    var r18 = g.rating === "r18";
    var thumb = el("a", { class: "thumb", href: BASE + "?g=" + g.slug, "aria-label": g.title + "をショートで見る", "data-clip": g.clip && !r18 ? BASE + g.clip : null },
      el("img", { class: "media" + (g.thumb && !r18 ? " shot" : ""), style: g.thumb && !r18 ? "--tb:" + (g.bg || "#0b0e13") : null, src: BASE + (g.thumb && !r18 ? g.thumb : g.cover && !r18 ? g.cover : "og/" + g.slug + ".png"), alt: "", loading: "lazy" }),
      g.rating ? el("span", { class: "rate rate-" + g.rating }, g.rating.toUpperCase()) : null,
      g.minutes ? el("span", { class: "dur" }, g.minutes) : null);
    return el("article", { class: "tile" }, thumb,
      el("div", { class: "meta2" },
        el("div", { class: "meta" },
          el("a", { class: "t", href: BASE + "games/" + g.slug + "/" }, g.title),
          el("div", { class: "by sub" }, sub), el("div", { class: "by" }, st.join(" ・ ")), o.extra || null),
        T.menuBtn(g.slug, g.title, o.inProfile ? "data-in-profile" : null)));
  };

  // ---- 見た目 ----
  var css = "" +
    ".tpb-av{display:inline-grid;place-items:center;border-radius:50%;object-fit:cover;color:#fff;font-weight:800;flex:none;line-height:1;background:#6B6158;overflow:hidden}" +
    ".tpb-av.guest{background:#8882;color:inherit;font-size:16px}" +
    ".tpb-me{display:inline-flex;align-items:center;gap:6px;text-decoration:none;color:inherit;font-size:13px;border-radius:999px;min-height:44px;padding:3px 10px 3px 3px;border:1px solid var(--line,#8884)}" +
    ".tpb-me.in{padding:3px;border-color:transparent}" +
    "@media (max-width:480px){.tpb-me{padding:3px;border-color:transparent}.tpb-me-t{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}.tpb-av.guest{border:1px solid var(--line,#8886)}}" +
    ".tpb-kebab{flex:none;width:44px;height:44px;border-radius:50%;border:0;background:none;color:inherit;font-size:20px;line-height:1;cursor:pointer;display:grid;place-items:center;font-weight:800}" +
    ".tpb-kebab:hover,.tpb-kebab:focus-visible{background:#8883}" +
    ".tpb-ov{position:fixed;left:0;right:0;top:0;bottom:0;height:100vh;height:100dvh;z-index:90;background:#0006}" +
    ".tpb-ov.menu:not(.tpb-sheet){background:transparent}" +
    ".tpb-ov.tpb-sheet{display:grid;align-items:end;align-content:end;justify-items:center;background:#0009}" +
    ".tpb-ov.dialog{display:grid;place-items:center;padding:16px;background:#0009}" +
    ".tpb-ov.dialog.tpb-sheet{align-items:center;align-content:center}" +
    "@media (max-width:599px){.tpb-ov.dialog{padding:0;align-items:end;align-content:end}.tpb-ov.dialog.tpb-sheet{align-items:end;align-content:end}" +
    ".tpb-ov.dialog .tpb-dialog{max-width:560px;max-height:90vh;max-height:90dvh;border-radius:18px 18px 0 0;border-bottom:0;padding-bottom:calc(18px + env(safe-area-inset-bottom));overscroll-behavior:contain}}" +
    ".tpb-menu,.tpb-dialog{background:var(--card,#FFFDF8);color:var(--ink,#2A241E);border:1px solid var(--line,#DCCFB8);border-radius:6px;box-shadow:0 1px 0 var(--line,#DCCFB8),0 10px 40px rgba(42,36,30,.35);font-size:15px;line-height:1.5}" +
    ".tpb-menu{min-width:260px;max-width:min(360px,calc(100vw - 16px));padding:6px;display:grid}" +
    ".tpb-ov.tpb-sheet .tpb-menu{width:100%;max-width:560px;max-height:90vh;max-height:90dvh;overflow-y:auto;border-radius:18px 18px 0 0;padding:10px 10px calc(10px + env(safe-area-inset-bottom));border-bottom:0}" +
    ".tpb-mt{font-size:12px;opacity:.7;padding:6px 12px 4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
    ".tpb-ms{font-size:12px;font-weight:700;color:var(--shu-ink,#A5311A);padding:8px 12px 2px;border-top:1px solid var(--line,#DCCFB8);margin-top:4px}" +
    ".tpb-mi{display:flex;align-items:center;gap:12px;width:100%;min-height:46px;padding:8px 12px;border:0;border-radius:10px;background:none;color:inherit;font:inherit;text-align:left;text-decoration:none;cursor:pointer}" +
    ".tpb-mi[hidden]{display:none}" +
    ".tpb-mi:hover,.tpb-mi:focus-visible{background:#8882;outline:none}" +
    ".tpb-mi.warn{color:#B0301B}" +
    ".tpb-mx{justify-content:center;opacity:.75;font-size:14px;border-top:1px solid var(--line,#DCCFB8);border-radius:0 0 6px 6px;margin-top:4px}" +
    ".tpb-ov.menu:not(.tpb-sheet) .tpb-mx{display:none}" +
    ".tpb-ic{width:24px;text-align:center;flex:none}" +
    ".tpb-dialog{width:100%;max-width:440px;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);overflow:auto;padding:18px;display:grid;gap:12px}" +
    ".tpb-dialog h3{margin:0;font-size:18px}.tpb-sub{margin:0;font-size:13px;opacity:.8}" +
    ".tpb-opts{display:grid;gap:8px}" +
    ".tpb-opt{font:inherit;font-size:14px;text-align:left;min-height:44px;padding:8px 12px;border-radius:10px;border:1px solid var(--line,#DCCFB8);border-radius:4px;background:none;color:inherit;cursor:pointer}" +
    ".tpb-opt[aria-checked=true]{border-color:var(--accent,#C8401F);background:var(--accent,#C8401F);color:var(--accent-ink,#fff);font-weight:700}" +
    ".tpb-dialog textarea{width:100%;min-height:70px;font:inherit;font-size:14px;border-radius:10px;border:0;border-bottom:2px solid var(--ink,#2A241E);background:var(--paper-2,#EFE6D3);color:inherit;padding:10px;resize:vertical}" +
    ".tpb-btn{font:inherit;font-weight:700;font-size:15px;min-height:46px;border:0;border-radius:6px;padding:10px 16px;background:var(--accent,#C8401F);color:var(--accent-ink,#fff);box-shadow:0 3px 0 #8E2C14;cursor:pointer;text-align:center;text-decoration:none}.tpb-btn:active{transform:translateY(3px);box-shadow:none}" +
    ".tpb-btn.ghost{background:transparent;color:var(--shu-ink,#A5311A);border:2px solid var(--accent,#C8401F);box-shadow:none;font-weight:700}.tpb-btn.ghost:active{transform:none}" +
    ".tpb-btn:disabled{opacity:.6}" +
    ".tpb-prov{display:grid;gap:8px}.tpb-prov:empty{display:none}" +
    ".tpb-msg{margin:0;min-height:1.2em;font-size:13px;text-align:center}.tpb-msg.err{color:#B0301B}" +
    ".tpb-toast{position:fixed;left:50%;bottom:calc(20px + env(safe-area-inset-bottom));transform:translateX(-50%);z-index:95;background:#2A241E;color:#fff;border-radius:6px;padding:10px 18px;font-size:14px;display:none;box-shadow:0 8px 30px #0008;max-width:calc(100% - 24px)}" +
    ".tpb-toast.show{display:block}" +
    ".thumb video.hov{position:absolute;inset:0;width:100%;height:100%;aspect-ratio:auto;max-height:none;object-fit:contain;background:#0b0e13;border-radius:2px}" +
    ".meta2{display:flex;gap:4px;align-items:flex-start;min-width:0}.meta2 .meta{flex:1}.meta2 .tpb-kebab{margin:-10px -12px 0 0}";
  document.head.append(el("style", null, css));
})();

// ---- PC・タブレットの共通の骨組み：左のサイドバー（assets/side.css が見た目）と、右上のログイン／アイコン ----
// スマホ（767px以下）では CSS で隠す。ここでは中身を描くだけ。dev・admin（<body data-noside>）は描かない。
(function () {
  "use strict";
  var T = window.TPB, el = T.el, BASE = T.base;
  var IC = {
    short: '<path d="M8 5.5v13l11-6.5z" fill="currentColor"/>',
    list: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.2" fill="currentColor"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.2" fill="currentColor"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.2" fill="currentColor"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.2" fill="currentColor"/>',
    me: '<circle cx="12" cy="8.5" r="4" fill="currentColor"/><path d="M4.5 20c.6-4 3.8-6 7.5-6s6.9 2 7.5 6z" fill="currentColor"/>',
    creators: '<path d="M4 20l1.2-4.6L15.6 5a1.8 1.8 0 0 1 2.6 0l.8.8a1.8 1.8 0 0 1 0 2.6L8.6 18.8z" fill="currentColor"/>',
    submit: '<path d="M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z" fill="currentColor"/>',
    stamp: '<rect x="4" y="5" width="16" height="15" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M4 9.5h16M8 3.5v3M16 3.5v3" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="14.6" r="2.6" fill="currentColor"/>',
    discord: '<path d="M5 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-6l-5 4v-4H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z" fill="currentColor"/>'
  };
  function icon(k) { var s = document.createElementNS("http://www.w3.org/2000/svg", "svg"); s.setAttribute("viewBox", "0 0 24 24"); s.setAttribute("class", "ic"); s.setAttribute("aria-hidden", "true"); s.innerHTML = IC[k]; return s }
  function current() {
    var p = location.pathname, base = ""; try { base = new URL(BASE, location.href).pathname } catch (e) {}
    var q = p.replace(/index\.html$/, "");
    if (q === base || (!base && q === "/")) return "short";
    if (/\/list(\.html)?$/.test(p) || /\/games\//.test(p)) return "list";
    if (/\/me(\.html)?$/.test(p)) return "me";
    if (/\/creators(\.html)?$/.test(p)) return "creators";
    if (/\/submit(\.html)?$/.test(p)) return "submit";
    return "";
  }
  T.chrome = function () {
    var b = document.body; if (!b || b.hasAttribute("data-noside") || document.getElementById("tpbSide")) return;
    var cur = current(), disc = (window.TPB_DATA && window.TPB_DATA.discord) || "";
    function item(k, href, label, ext, badge) {
      var a = el("a", { href: href, title: badge ? "今日のスタンプカード" : label, "aria-label": badge ? "今日のスタンプカード" : label, "aria-current": k === cur ? "page" : null, target: ext ? "_blank" : null, rel: ext ? "noopener" : null, "data-ms-open": badge ? "" : null }, icon(k), el("span", { class: "lb" }, label), badge ? el("span", { class: "ms-nb", "data-ms-count": "" }) : null);
      return a;
    }
    var main = document.querySelector("main"), target = "#feed";
    if (main) { if (!main.id) main.id = "tpbMain"; target = "#" + main.id }
    var skip = el("a", { class: "sd-skip", id: "skipIn", href: target }, "本文へ飛ぶ");
    skip.addEventListener("click", function (e) { var t = document.querySelector(target); if (!t || t.id === "feed") return; e.preventDefault(); t.setAttribute("tabindex", "-1"); t.focus() });
    var side = el("aside", { class: "tpb-side", id: "tpbSide" },
      skip,
      el("a", { class: "sd-brand", href: BASE, "aria-label": "テストプレイ部のトップ（ショート）", title: "テストプレイ部" }, el("img", { src: BASE + "assets/icon-192.png", alt: "", width: 40, height: 40 }), el("span", null, "テストプレイ部")),
      el("nav", { "aria-label": "メニュー" },
        item("short", BASE, "ショート"), item("list", BASE + "list.html", "作品一覧"), item("stamp", BASE + "me.html#stamp", "スタンプカード", false, true), item("me", BASE + "me.html", "マイページ"),
        el("hr"),
        item("creators", BASE + "creators.html", "作品を載せたい人へ"), item("submit", BASE + "submit.html", "作品を応募する"),
        disc ? item("discord", disc, "Discordに参加する", true) : null),
      el("div", { class: "sd-foot" }, el("p", null, "学生のゲームを、", el("br"), "学生が遊ぶ部室。"), el("a", { href: BASE + "privacy.html" }, "集める情報と使い道")));
    var first = b.firstElementChild; if (first && first.classList.contains("skip")) first.after(side); else b.prepend(side);
    // 右上の自分のアイコン：ページに置いていないときは、PCだけで出す（スマホの見た目は変えない）
    var hd = document.querySelector("header.bar");
    if (hd && !hd.querySelector("[data-me]")) {
      var br = hd.querySelector(".bar-r");
      if (!br) { br = el("span", { class: "bar-r pc-only" }); hd.append(br) }
      br.append(el("span", { "data-me": true, class: "pc-only" }));
    }
  };
  T.chrome();
})();

// 置いてあるだけで動く部品： data-me（右上の自分のアイコン）、data-by（作った人の名前とアイコンを、管理ページで決めた作者に差し替える）
(function () {
  "use strict";
  var T = window.TPB;
  function go() {
    document.querySelectorAll("[data-me]").forEach(function (h) { if (!h.firstChild) T.mountMe(h) });
    var marks = document.querySelectorAll("[data-by]"); if (!marks.length) return;
    T.liveCreators().then(function (live) {
      marks.forEach(function (m) {
        var c = live[m.getAttribute("data-by")]; if (!c) return;
        var size = +(m.getAttribute("data-size") || 0);
        var a = T.el("a", { class: m.className, href: T.profileUrl(c.handle) }, size ? T.avatar(c, size) : null, m.hasAttribute("data-noname") ? null : c.name);
        if (m.hasAttribute("data-noname")) a.setAttribute("aria-label", c.name + " のプロフィール");
        m.replaceWith(a);
      });
    });
  }
  // PC：カードの画像にマウスをのせると、プレイ動画（ミュート）が流れる。離すと止めてサムネに戻る。動きを減らす設定のときは流さない
  if (matchMedia("(hover:hover) and (pointer:fine)").matches) {
    var rm = matchMedia("(prefers-reduced-motion:reduce)");
    document.addEventListener("mouseover", function (e) {
      if (rm.matches) return;
      var t = e.target.closest && e.target.closest(".thumb[data-clip]"); if (!t || t.querySelector("video")) return;
      var v = T.el("video", { class: "media hov", src: t.getAttribute("data-clip"), muted: true, loop: true, playsinline: true, preload: "auto", "aria-hidden": "true" });
      var im = t.querySelector("img"), tb = im && im.style.getPropertyValue("--tb"); if (tb) v.style.background = tb;
      v.muted = true; v.style.opacity = "0"; v.addEventListener("playing", function () { v.style.opacity = "1" }); t.append(v); v.play().catch(function () {});
      t.addEventListener("mouseleave", function () { v.pause(); v.remove() }, { once: true });
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
})();

// メールの6けたの番号でログインする箱。Xなどのアプリ内ブラウザでは、メールのリンクを開くと別のブラウザになってログインできないことがあるため、番号でも入れるようにする。
// 使い方：var b = TPB.otpBlock({ onDone: fn }); 好きな場所に置く。メールを送ったあとに b.open(メールアドレス) を呼ぶ。
(function () {
  "use strict";
  var T = window.TPB, el = T.el;
  // メールの文面に番号（{{ .Token }}）を入れるには、Supabaseで自前のメール送信（SMTP）の設定が要る。
  // 設定が終わるまでは番号が届かないので、番号の欄は出さない。終わったら true にする。
  T.OTP_ENABLED = false;
  // ログインの説明の文は、ここ1か所で作る（OTP_ENABLED に合わせて切り替える）
  T.loginText = function () {
    return T.OTP_ENABLED ? "メールに、リンクと6けたの番号が届きます。どちらでもログインできます。"
      : "メールにログイン用のリンクが届きます。このページを開いたのと同じブラウザで開いてね。";
  };
  T.loginSentText = function () {
    return T.OTP_ENABLED ? "メールを送ったよ。メールのリンクを開くか、届いた6けたの番号を下に入れてね（迷惑メールも確認してね）"
      : "メールを送ったよ。メールのリンクを、このページを開いたのと同じブラウザで開いてね（迷惑メールも確認してね）";
  };
  // X・Instagram・LINE などのアプリの中のブラウザか
  T.inAppBrowser = function () { return /Twitter|Instagram|Line\/|FBAN|FBAV|FB_IAB|TikTok|musical_ly|Snapchat/i.test(navigator.userAgent || "") };
  T.inAppText = "アプリの中のブラウザだと、ログインできないことがあります。右上のメニューから「ブラウザで開く」を選んでね。";
  // ログインの説明（と、アプリ内ブラウザの注意）を入れた要素を返す。style は任意
  T.loginNote = function (cls, style) {
    var d = el("div", { class: "loginnote", style: "display:grid;gap:6px" }, el("p", { class: cls || "muted", style: style || "margin:0;font-size:12px;line-height:1.5" }, T.loginText()));
    if (T.inAppBrowser()) d.append(el("p", { class: cls || "muted", role: "note", style: "margin:0;font-size:12px;line-height:1.5;color:#e0a030;font-weight:700" }, T.inAppText));
    return d;
  };
  T.otpBlock = function (o) {
    o = o || {};
    var email = "";
    var input = el("input", { type: "text", inputmode: "numeric", autocomplete: "one-time-code", maxlength: "10", placeholder: "メールの6けたの番号", "aria-label": "メールに届いた6けたの番号" });
    var btn = el("button", { type: "button", class: o.btnClass || "btn" }, "番号でログイン");
    var msg = el("p", { class: "msg", "aria-live": "polite", style: "margin:0;font-size:13px" });
    var box = el("div", { class: "otp", hidden: true, style: "display:grid;gap:8px" },
      el("p", { class: "muted", style: "margin:0;font-size:12px;line-height:1.5" }, "リンクを開けないときは、メールに書いてある6けたの番号を入れてね。"), input, btn, msg);
    async function go() {
      var token = input.value.replace(/[\s\u3000]/g, "").replace(/[０-９]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) - 0xFEE0) });
      if (!/^\d{6,10}$/.test(token)) { msg.className = "msg err"; msg.textContent = "メールの番号（数字6けた）を入れてね"; return }
      var sb = T.sb(); if (!sb) { msg.className = "msg err"; msg.textContent = "いま読み込めませんでした。ページを開き直してね"; return }
      btn.disabled = true; msg.className = "msg"; msg.textContent = "確かめています…";
      var r = await sb.auth.verifyOtp({ email: email, token: token, type: "email" });
      btn.disabled = false;
      if (r.error) { msg.className = "msg err"; msg.textContent = "番号が合いませんでした。メールをもう一度見てね（時間がたつと使えなくなります）"; return }
      msg.textContent = "ログインしたよ"; if (o.onDone) o.onDone();
    }
    btn.addEventListener("click", go);
    input.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); go() } });
    box.open = function (addr) { if (!T.OTP_ENABLED) return; email = addr; box.hidden = false; box.style.display = "grid"; msg.textContent = ""; input.value = "" };
    box.hidden = true; box.style.display = "none";
    return box;
  };
})();

// 入力のまちがいを、その欄のすぐ下に出す。欄を赤い枠にして、そこまでスクロールして、フォーカスする
(function () {
  "use strict";
  var T = window.TPB, el = T.el;
  T.clearFieldErr = function (form) {
    form.querySelectorAll(".ferr").forEach(function (n) { n.remove() });
    form.querySelectorAll("[aria-invalid]").forEach(function (n) { n.removeAttribute("aria-invalid"); n.removeAttribute("aria-describedby") });
  };
  T.fieldErr = function (form, input, text) {
    T.clearFieldErr(form);
    var id = "ferr-" + Date.now();
    var p = el("p", { class: "ferr", id: id, role: "alert" }, text);
    var anchor = input.closest("label") || input;
    anchor.insertAdjacentElement("afterend", p);
    input.setAttribute("aria-invalid", "true"); input.setAttribute("aria-describedby", id);
    var clear = function () { p.remove(); input.removeAttribute("aria-invalid"); input.removeAttribute("aria-describedby"); input.removeEventListener("input", clear) };
    input.addEventListener("input", clear);
    var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
    input.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    try { input.focus({ preventScroll: true }) } catch (e) { input.focus() }
  };
})();

// ログインの箱（マイページ・応募フォーム用）。使えるログイン方法だけボタンを出す
(function () {
  "use strict";
  var T = window.TPB, el = T.el;
  T.loginBox = function (title, text) {
    var msg = el("p", { class: "msg", "aria-live": "polite" });
    var prov = el("div", { class: "tpb-prov" });
    var email = el("input", { type: "email", inputmode: "email", autocomplete: "email", placeholder: "メールアドレス", "aria-label": "メールアドレス" });
    var send = el("button", { class: "btn", type: "submit" }, "メールでログイン");
    var back = location.origin + location.pathname + location.search;
    var otp = T.otpBlock({ btnClass: "btn", onDone: function () { location.reload() } });
    var form = el("form", { class: "form", novalidate: true }, email, send, T.loginNote("muted", "margin:-6px 0 0;font-size:12px"));
    form.addEventListener("submit", async function (e) {
      e.preventDefault();
      var v = email.value.trim();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v)) { msg.className = "msg err"; msg.textContent = "メールアドレスを確かめてね"; return }
      send.disabled = true; msg.className = "msg"; msg.textContent = "送信中…";
      var r = await T.sb().auth.signInWithOtp({ email: v, options: { emailRedirectTo: back } });
      send.disabled = false;
      if (r.error) { msg.className = "msg err"; msg.textContent = "送れなかった…時間をおいてもう一度試してね" }
      else { msg.textContent = T.loginSentText(); otp.open(v) }
    });
    fetch(T.SB_URL + "/auth/v1/settings", { headers: { apikey: T.SB_KEY } }).then(function (r) { return r.json() }).then(function (st) {
      var ext = (st && st.external) || {};
      [["discord", "Discordでログイン", "#5865F2", "#fff"], ["google", "Googleでログイン", "#fff", "#222"]].forEach(function (x) {
        if (ext[x[0]]) prov.append(el("button", { class: "btn", type: "button", style: "background:" + x[2] + ";color:" + x[3] + ";border:1px solid #8884", onclick: function () { T.sb().auth.signInWithOAuth({ provider: x[0], options: { redirectTo: back } }) } }, x[1]));
      });
    }).catch(function () {});
    return el("section", { class: "card", style: "max-width:460px;margin:0 auto;width:100%" }, el("div", { class: "body" },
      el("h1", { style: "font-size:20px;margin:0" }, title), el("p", { class: "muted", style: "margin:0;font-size:14px" }, text),
      prov, form, msg, otp, el("a", { class: "by", href: T.base + "privacy.html" }, "集める情報と使い道")));
  };

  // ---- ポイント（計算はぜんぶデータベースの中。ここは見せるだけ） ----
  // 決まりの数字は points_rule（だれでも）から。取れなかったときは、初期値で見せる
  var PT_DEFAULT = { min_chars: 40, daily_cap: 50, tier1_max: 2, tier1_pt: 10, tier2_max: 9, tier2_pt: 5, tier3_pt: 2, submit_cost: 30 };
  var _rule = null;
  T.ptRule = function () {
    if (!_rule) _rule = T.pub("points_rule").then(function (r) { var o = {}; for (var k in PT_DEFAULT) o[k] = (r && typeof r[k] === "number") ? r[k] : PT_DEFAULT[k]; _ruleNow = o; _ptOk = !!(r && typeof r === "object"); return o });
    return _rule;
  };
  T.ptRuleNow = function () { return _ruleNow || PT_DEFAULT };
  var _ruleNow = null, _ptOk = null;
  T.ptOk = function () { return _ptOk === true };   // ポイントの仕組み（012）がデータベースにあるか。まだ無いときは、ポイントの表示を出さない
  // 感想が n 件ある作品でもらえるポイント（めやす）
  T.ptFor = function (n, r) { r = r || T.ptRuleNow(); return n <= r.tier1_max ? r.tier1_pt : n <= r.tier2_max ? r.tier2_pt : r.tier3_pt };
  // 0pt だったときの理由（データベースが note に入れた短い名前 → 一言）
  T.ptWhy = function (note) {
    return { short: "一言が" + T.ptRuleNow().min_chars + "字に届かなかった", lazy: "同じ言葉のくり返しに見えた", own: "自分の作品", not_played: "遊んでいない", cap: "今日の上限に届いている" }[note] || "";
  };
  // 記録1行の説明
  T.ptReasonText = function (x) {
    var g = x.label ? (T.game(x.label) ? T.game(x.label).title : x.label) : "";
    switch (x.reason) {
      case "feedback": return "「" + g + "」に感想を書いた";
      case "feedback_revoked": return "「" + g + "」の感想が非表示になったので取り消し";
      case "feedback_restored": return "「" + g + "」の感想が表示に戻ったので返った";
      case "submission": return "作品を応募した" + (x.label ? "（" + x.label + "）" : "");
      case "submission_refund": return "応募が見送りになったので返った" + (x.label ? "（" + x.label + "）" : "");
      case "admin_adjust": return "運営から" + (x.note ? "：" + x.note : "");
      case "mission_feedback": return "今日のミッション：40字以上の感想";
      case "mission_fresh": return "今日のミッション：感想が少ない作品に感想";
      case "mission_all": return "今日のミッション：3つそろえたボーナス";
      case "mission_revoked": return "感想が非表示になったので、ミッションの分を取り消し";
    }
    return "";
  };
  // 「ポイントのしくみ」の説明（マイページ・応募フォームなどで使う）
  T.ptHowTo = function () {
    var r = T.ptRuleNow();
    return el("div", { class: "tpb-pthow" },
      el("p", { style: "margin:0" }, "感想の少ない作品に、ていねいな感想を書くとポイントがたまります。ためたポイントで、作品を応募できます。"),
      el("ul", { style: "margin:8px 0 0;padding-left:1.2em;display:grid;gap:4px;font-size:14px" },
        el("li", null, el("b", null, "ためる："), "一言を" + r.min_chars + "字以上（空白は数えません）で書いた感想に、ポイントがつきます。感想が" + (r.tier1_max + 1) + "件より少ない作品は +" + r.tier1_pt + "pt、" + (r.tier2_max + 1) + "件より少ない作品は +" + r.tier2_pt + "pt、それより多い作品は +" + r.tier3_pt + "pt です。"),
        el("li", null, "遊んだ作品だけ・自分の作品はなし・同じ言葉のくり返しはなし。もらえるのは、1日 " + r.daily_cap + "pt までです。"),
        el("li", null, el("b", null, "つかう："), "作品を応募するとき " + r.submit_cost + "pt。直しの依頼はいりません。運営が見送りにしたら、返します。"),
        el("li", null, el("b", null, "最初の1本は無料："), "はじめての応募は、ポイントなしで送れます。2本目からは " + r.submit_cost + "pt です（見送りになったときは、無料がもう一度使えます）。"),
        el("li", null, "運営が感想を非表示にしたら、その感想でもらった分は取り消されます（表示に戻れば返ります）。")));
  };


  // ---- 訪問の記録（1つの端末につき1日1回） ----
  // サイトのどこかを開いたら、その日のうち最初の1回だけ site_visits に書く（端末のIDと日付だけ。日付はDBが日本時間で入れる）。
  // 同じ日にもう送ったかは localStorage（tpb:visitDay）に覚えて、2回目からは送らない。
  // 別のタブで同時に送って 409 が返っても、失敗しても、何も出さずに終わる。運営（admin）と開発者（dev）のページは数えない。
  T.visit = function () {
    try {
      if (/\/(admin|dev)(\.html)?\/?$/.test(location.pathname)) return;
      var day = new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);   // 日本時間の日付
      if (T.store.get("visitDay", "") === day) return;
      fetch(T.SB_URL + "/rest/v1/site_visits", { method: "POST", keepalive: true,
        headers: { apikey: T.SB_KEY, "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({ client_id: T.cid() }) })
        .then(function (r) { if (r.status < 500) T.store.set("visitDay", day) })   // 409（もう数えた）や BAN の断りも「送った」ことにする。通信できなかったときだけ次回また試す
        .catch(function () {});
    } catch (e) {}
  };
  T.visit();
})();
