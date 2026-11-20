/* 今日のミッション＋スタンプカード（tpb.js の次に読む）
 *  - 「今日」は日本時間の朝5時に切りかわる
 *  - (a) 作品を遊ぶ：ハンコだけ。この端末に記録する（20秒以上。ダウンロード型は公開ページを開いたら）。日によって中身が変わる
 *  - (b) 40字以上の感想 ／ (c) 感想が少ない作品に感想 ／ 3つぜんぶ：ポイントはデータベース（daily_missions_status）が決める。ここは見せるだけ
 *  - 連続日数は、この端末の記録
 * 画面：スタンプカード（M.openCard・M.draw）、作品一覧の帯（[data-ms-band]）、数字の印（[data-ms-count]）、開くボタン（[data-ms-open]）
 */
(function () {
  "use strict";
  var T = window.TPB; if (!T || !T.el) return;
  var el = T.el, S = T.store, BASE = T.base;
  var M = T.mission = {};
  var KINDS = {
    play1: ["作品を1本遊ぶ", "サイトの中で20秒以上。別のタブで開いた作品も、戻ってきたときに20秒以上ならOK。ダウンロード型は公開ページを開けばOK。"],
    fresh: ["まだ遊んでいない作品を1本", "遊んだことのない作品を20秒以上。ダウンロード型は公開ページを開けばOK。"],
    "new": ["新作（14日以内）を1本", "公開から14日以内の作品を20秒以上。ダウンロード型は公開ページを開けばOK。"]
  };

  // ---- 日付（日本時間の朝5時はじまり） ----
  function iso(ms) { return new Date(ms).toISOString().slice(0, 10) }
  M.dayKey = function (ts) { return iso((ts == null ? Date.now() : ts) + 4 * 3600 * 1000) };
  function prevKey(d) { return iso(Date.parse(d + "T00:00:00Z") - 864e5) }
  function isNew(g) { var t = Date.parse((g.added || "") + "T00:00:00+09:00"); return !isNaN(t) && Date.now() - t <= 14 * 864e5 }
  // 今日の (a) の中身：日付から決まる（play1 → fresh → new の順にまわる）。条件に合う作品がなければ play1。1日のあいだは変えない
  M.kind = function () {
    var d = M.dayKey(), k = S.get("msKind", null); if (k && k.day === d && KINDS[k.kind]) return k.kind;
    var kind = ["play1", "fresh", "new"][Math.floor(Date.parse(d + "T00:00:00Z") / 864e5) % 3], played = S.get("played", []);
    if (kind === "new" && !T.games.some(isNew)) kind = "play1";
    if (kind === "fresh" && !T.games.some(function (g) { return played.indexOf(g.slug) < 0 })) kind = "play1";
    S.set("msKind", { day: d, kind: kind }); return kind;
  };

  // ---- (a) この端末のハンコ ----
  M.hasA = function () { var a = S.get("msA", null); return !!(a && a.day === M.dayKey()) };
  // 20秒以上遊んだ・ダウンロードの公開ページを開いた。wasFresh：その作品を、いままで遊んでいなかったか
  M.markA = function (slug, wasFresh) {
    if (M.hasA()) return false;
    var g = T.game(slug); if (!g) return false;
    var k = M.kind(), ok = k === "play1" || (k === "fresh" && !!wasFresh) || (k === "new" && isNew(g));
    if (!ok) return false;
    S.set("msA", { day: M.dayKey(), slug: slug }); stampDay(); emit(); return true;
  };
  // ダウンロード型の公開ページを開いたとき（フィードと作品ページから）。次にサイトを開いたときの「遊べた？」の元になる
  M.dlOpened = function (slug, wasFresh) {
    var m = S.get("dlOpen", {}), now = Date.now(); for (var k in m) if (now - m[k] > 30 * 864e5) delete m[k];
    m[slug] = now; S.set("dlOpen", m); M.markA(slug, wasFresh);
  };
  // 別のタブで開いて、このページに戻ってきたら20秒以上たっていた、を見る（フィード以外のページ用）
  M.externalStart = function (slug, fresh) { S.set("msExt", { slug: slug, t: Date.now(), fresh: !!fresh }) };

  // ---- 連続日数（この端末の記録） ----
  function stampDay() {
    var d = M.dayKey(), s = S.get("msStreak", { last: "", n: 0 }); if (s.last === d) return;
    S.set("msStreak", { last: d, n: s.last === prevKey(d) ? (s.n || 0) + 1 : 1 });
  }
  M.streak = function () { var s = S.get("msStreak", { last: "", n: 0 }), d = M.dayKey(); return (s.last === d || s.last === prevKey(d)) ? (s.n || 0) : 0 };
  M.streakToday = function () { return S.get("msStreak", { last: "" }).last === M.dayKey() };

  // ---- (b)(c) データベースの答え ----
  M.srv = function () { var c = S.get("msSrv", null); return c && c.day === M.dayKey() && T.maybeLoggedIn() ? c.st : null };
  M.err = false;
  M.refresh = async function () {
    if (!T.maybeLoggedIn()) return null;
    var s = await T.session(); if (!s) return null;
    try {
      var r = await T.sb().rpc("daily_missions_status");
      if (r.error || !r.data) { M.err = true; emit(); return null }
      M.err = false; S.set("msSrv", { day: r.data.day, st: r.data });
      if ((r.data.b && r.data.b.done) || (r.data.c && r.data.c.done)) stampDay();
      emit(); return r.data;
    } catch (e) { M.err = true; return null }
  };
  M.counts = function () {
    var st = M.srv(), a = M.hasA(), b = !!(st && st.b && st.b.done), c = !!(st && st.c && st.c.done);
    return { a: a, b: b, c: c, n: (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0), st: st };
  };
  // 感想を送った直後：新しく達成したミッションを知らせる文を返す（なければ null）。値はデータベースの返り値だけ
  M.afterFeedback = async function () {
    var st = await M.refresh(); if (!st) return null;
    var seen = S.get("msSeen", { day: "", k: [] }); if (seen.day !== st.day) seen = { day: st.day, k: [] };
    var parts = [], total = 0;
    [["b", "40字の感想"], ["c", "感想が少ない作品"], ["all", "3つそろった"]].forEach(function (x) {
      var m = st[x[0]]; if (m && m.done && m.granted > 0 && seen.k.indexOf(x[0]) < 0) { seen.k.push(x[0]); parts.push(x[1] + " +" + m.granted); total += m.granted }
    });
    S.set("msSeen", seen);
    return parts.length ? { total: total, parts: parts, text: "ミッション達成！＋" + total + "pt（" + parts.join("・") + "）" } : null;
  };

  // ---- 印・帯の更新 ----
  var listeners = [];
  M.onChange = function (fn) { listeners.push(fn) };
  function emit() {
    var c = M.counts();
    document.querySelectorAll("[data-ms-count]").forEach(function (n) { n.textContent = c.n + "/3" });
    document.querySelectorAll("[data-ms-band]").forEach(function (b) { b.classList.toggle("full", c.n === 3); b.querySelectorAll(".ms-dots i").forEach(function (d, i) { d.classList.toggle("on", [c.a, c.b, c.c][i]) }) });
    var sk = M.streak(); document.querySelectorAll("[data-ms-streak]").forEach(function (n) { n.textContent = sk >= 2 ? sk + "日連続" : ""; n.hidden = sk < 2 });
    listeners.forEach(function (f) { try { f(c) } catch (e) {} });
  }

  // ---- スタンプカード ----
  function dateText() { var p = M.dayKey().split("-"); return +p[1] + "月" + +p[2] + "日" }
  function slot(shown, key, done, title, sub, right) {
    var anim = done && shown.k.indexOf(key) < 0; if (done && anim) shown.k.push(key);
    return el("li", { class: "ms-slot" + (done ? " done" : "") + (anim ? " pop" : "") },
      el("span", { class: "ms-ring", "aria-hidden": "true" }, done ? el("span", { class: "ms-stamp" }, "済") : null),
      el("div", { class: "ms-tx" }, el("b", null, title, el("span", { class: "ms-sr" }, done ? "（達成）" : "（まだ）")), el("small", null, sub)),
      el("span", { class: "ms-pt" }, right));
  }
  // box の中に、カードの中身を描く（開いたまま描きなおせる）。o.onGo：「遊びにいく」を押したときにやること（なければショートへのリンク）
  M.draw = function (box, o) {
    o = o || {};
    var c = M.counts(), st = c.st, logged = T.maybeLoggedIn(), K = KINDS[M.kind()], r = T.ptRuleNow ? T.ptRuleNow() : { min_chars: 40, tier1_max: 2 };
    var shown = S.get("msShown", { day: "", k: [] }); if (shown.day !== M.dayKey()) shown = { day: M.dayKey(), k: [] };
    // 見せるものが変わっていないときは描きなおさない（ハンコが押されるアニメーションを途中で消さないため）
    var sig = JSON.stringify([c, st, M.err, logged, M.kind(), M.streak()]); if (box._sig === sig && box.firstChild) return; box._sig = sig;
    var sk = M.streak(), unknown = logged && !st;
    function pt(m, d) { return m ? (m.done ? (m.granted > 0 ? "+" + m.granted + "pt" : "pt なし") : "+" + m.pt + "pt") : "+" + d + "pt" }
    var needLogin = "ログインして感想を書くと、ポイントがもらえます";
    var allDone = !!(st && st.all && st.all.done);
    if (allDone && shown.k.indexOf("all") < 0) shown.k.push("all"), allDone = "pop";
    var kids = [
      el("div", { class: "ms-head" }, el("h3", { id: "msT" }, "今日のスタンプカード"),
        el("span", { class: "ms-streak" + (sk ? "" : " off"), "data-ms-streak": "" }, sk >= 2 ? sk + "日連続" : sk === 1 && !M.streakToday() ? "昨日から続き中" : "")),
      el("p", { class: "ms-sub" }, dateText() + "（朝5時に切りかわります）。ハンコを3つ集めよう。"),
      el("ol", { class: "ms-slots" },
        slot(shown, "a", c.a, K[0], K[1], "ハンコ"),
        slot(shown, "b", c.b, "40字以上の感想を1件", logged ? "一言を" + r.min_chars + "字以上（空白は数えない）で書いた感想です。" : needLogin, pt(st && st.b, 3)),
        slot(shown, "c", c.c, "感想が少ない作品に感想を1件", logged ? "他の人の感想が" + r.tier1_max + "件以下の作品です（「感想まだ0件」の印が目印）。" : needLogin, pt(st && st.c, 5))),
      el("div", { class: "ms-bonus" + (allDone ? " done" + (allDone === "pop" ? " pop" : "") : "") },
        el("span", { class: "ms-ring sm", "aria-hidden": "true" }, allDone ? el("span", { class: "ms-stamp" }, "OK") : null),
        el("div", { class: "ms-tx" }, el("b", null, "3つぜんぶそろうと ボーナス ", pt(st && st.all, 5), el("span", { class: "ms-sr" }, allDone ? "（達成）" : "（まだ）")),
          el("small", null, st && st.all && st.all.need_play ? "感想の2つはできました。今日はまだ作品を遊んでいないので、1本遊ぶとボーナスがつきます。" : "感想の2つをそろえて、今日遊んでいると、ボーナスがつきます。")))
    ];
    if (st) kids.push(el("p", { class: "ms-pts" }, "いまのポイント ", el("b", null, st.balance + "pt"), "　今日もらった分 " + st.points_today + " / " + st.daily_cap + "pt（ミッションも上限に含みます）"));
    if (unknown) kids.push(el("p", { class: "ms-note" }, M.err ? "感想のミッションの結果を読み込めませんでした。時間をおいて開きなおしてね。" : "確認しています…"));
    if (!logged) kids.push(el("p", { class: "ms-note" }, "ログインしなくても、(a) のハンコは集められます（この端末に残ります）。"));
    var act = el("div", { class: "ms-acts" },
      !logged ? el("a", { class: "tpb-btn", href: BASE + "me.html" }, "ログインする") : null,
      o.onGo ? el("button", { class: "tpb-btn" + (logged ? "" : " ghost"), type: "button", onclick: o.onGo }, "▶ 作品を遊ぶ") : el("a", { class: "tpb-btn" + (logged ? "" : " ghost"), href: BASE }, "▶ ショートで遊ぶ"),
      o.onClose ? el("button", { class: "tpb-btn ghost", type: "button", onclick: o.onClose }, "とじる") : null);
    kids.push(act);
    S.set("msShown", shown);
    box.replaceChildren.apply(box, kids);
  };
  // 箱（ダイアログ）で開く
  M.openCard = function (anchor) {
    var box = el("div", { class: "tpb-dialog msc", role: "dialog", "aria-modal": "true", "aria-labelledby": "msT" });
    function go() { T.closeOverlay() }
    var opt = { onClose: T.closeOverlay, onGo: document.getElementById("feed") ? go : null };
    M.draw(box, opt); T.dialog(box, anchor);
    M.refresh().then(function () { if (box.isConnected) M.draw(box, opt) });
    return box;
  };

  // ---- 作品一覧の帯 ----
  function mountBands() {
    document.querySelectorAll("[data-ms-band]").forEach(function (h) {
      if (h.tagName === "BUTTON") return;
      var b = el("button", { class: "ms-band", type: "button", "data-ms-open": "", "data-ms-band": "", "aria-label": "今日のミッション。スタンプカードを開く" },
        el("span", { class: "ms-bt" }, "今日のミッション"), el("b", { "data-ms-count": "" }), el("span", { class: "ms-dots", "aria-hidden": "true" }, el("i"), el("i"), el("i")),
        el("span", { class: "ms-bs", "data-ms-streak": "", hidden: true }), el("span", { class: "ms-go", "aria-hidden": "true" }, el("span", { class: "ms-gt" }, "カードを見る "), "›"));
      h.replaceWith(b);
    });
  }

  // ---- 見た目 ----
  var css = "" +
    ".msc{--ink:#2A241E;--muted:#6B6158;--line:#DCCFB8;--shu:#C8401F;--shu-ink:#A5311A;--card:#FFFDF8;--karashi-soft:#F8E6B0;color:#2A241E;background-color:#F6F1E7;background-image:var(--noise,none);font-family:'M PLUS Rounded 1c','Hiragino Maru Gothic ProN','Hiragino Sans','Yu Gothic','Noto Sans JP',system-ui,sans-serif}" +
    ".msc.tpb-dialog{max-width:440px;gap:12px;border:2px solid #DCCFB8}" +
    ".msc.ms-inline{padding:16px;display:grid;gap:12px;border:2px solid #DCCFB8;border-radius:6px}" +
    ".msc .ms-head{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap}" +
    ".msc h3{margin:0;display:block;width:fit-content;font-size:17px;font-weight:800;background:rgba(226,169,59,.85);padding:3px 18px;margin-left:-6px;transform:rotate(-1.5deg)}" +
    ".msc .ms-streak{font-size:13px;font-weight:800;color:#A5311A;border:2px solid #C8401F;border-radius:3px;padding:0 8px;transform:rotate(2deg);min-height:26px;display:inline-flex;align-items:center}.msc .ms-streak:empty,.msc .ms-streak.off:empty{display:none}" +
    ".msc .ms-sub,.msc .ms-note,.msc .ms-pts{margin:0;font-size:13px;line-height:1.6;color:#6B6158}.msc .ms-pts b{color:#A5311A}" +
    ".msc .ms-slots{margin:0;padding:0;list-style:none;display:grid;gap:10px}" +
    ".msc .ms-slot,.msc .ms-bonus{display:grid;grid-template-columns:60px minmax(0,1fr) auto;gap:12px;align-items:center;min-height:76px;padding:8px 12px;border:2px dashed #C9B994;border-radius:4px;background:#FFFDF8}" +
    ".msc .ms-bonus{grid-template-columns:44px minmax(0,1fr);min-height:60px;background:#F8E6B0;border-style:solid;border-color:rgba(42,36,30,.14)}" +
    ".msc .ms-ring{width:56px;height:56px;border-radius:50%;border:2px dashed #C9B994;display:grid;place-items:center;flex:none}.msc .ms-ring.sm{width:42px;height:42px}" +
    ".msc .done .ms-ring{border-color:transparent}" +
    ".msc .ms-stamp{display:grid;place-items:center;width:100%;height:100%;border-radius:50%;border:3px solid #C8401F;color:#A5311A;font-weight:800;font-size:24px;line-height:1;transform:rotate(-12deg);background:rgba(200,64,31,.07);box-shadow:inset 0 0 0 2px rgba(200,64,31,.22)}.msc .ms-ring.sm .ms-stamp{font-size:15px}" +
    ".msc .pop .ms-stamp{animation:msStamp .55s cubic-bezier(.2,.9,.3,1.15) both}" +
    "@keyframes msStamp{0%{transform:scale(2.6) rotate(-30deg);opacity:0}55%{transform:scale(.9) rotate(-9deg);opacity:1}100%{transform:scale(1) rotate(-12deg);opacity:1}}" +
    "@media (prefers-reduced-motion:reduce){.msc .pop .ms-stamp{animation:none}}" +
    ".msc .ms-tx{display:grid;gap:2px;min-width:0}.msc .ms-tx b{font-size:15px;line-height:1.4}.msc .ms-tx small{font-size:12px;line-height:1.5;color:#6B6158}.msc .ms-bonus .ms-tx small{color:#2A241E}" +
    ".msc .ms-pt{font-size:14px;font-weight:800;color:#A5311A;white-space:nowrap;text-align:right}" +
    ".msc .ms-sr,.ms-band .ms-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}" +
    ".msc .ms-acts{display:grid;gap:8px}" +
    "@media (max-width:420px){.msc .ms-slot{grid-template-columns:52px minmax(0,1fr);}.msc .ms-slot .ms-ring{width:48px;height:48px}.msc .ms-slot .ms-pt{grid-column:2;text-align:left}}" +
    ".ms-band{display:flex;align-items:center;gap:10px;width:100%;min-height:44px;padding:6px 14px;border:0;border-radius:3px;background:#F8E6B0;color:#2A241E;font:inherit;font-size:14px;font-weight:700;box-shadow:0 1px 0 rgba(42,36,30,.18);cursor:pointer;text-align:left;font-family:'M PLUS Rounded 1c','Hiragino Maru Gothic ProN','Hiragino Sans','Yu Gothic',system-ui,sans-serif}" +
    ".ms-band:hover{background:#F3DC98}.ms-band:focus-visible{outline:3px solid #2F5D9B;outline-offset:2px}" +
    ".ms-band b{color:#A5311A;font-size:15px}.ms-band .ms-dots{display:inline-flex;gap:4px}.ms-band .ms-dots i{width:12px;height:12px;border-radius:50%;border:2px solid #A5311A;box-sizing:border-box}.ms-band .ms-dots i.on{background:#C8401F}" +
    ".ms-band .ms-bs{font-size:12px;color:#A5311A;border:1.5px solid #C8401F;border-radius:3px;padding:0 6px}.ms-band .ms-go{margin-left:auto;font-size:12px;font-weight:700;color:#2A241E;white-space:nowrap}" +
    ".ms-band.full{background:#F6D5C9}.ms-band>*{white-space:nowrap}.ms-band .ms-bs[hidden]{display:none}" +
    "@media (max-width:480px){.ms-band{gap:8px;padding:6px 12px}.ms-band .ms-gt{display:none}.ms-band .ms-go{font-size:20px;line-height:1}}" +
    ".ms-nb{margin-left:auto;font-size:12px;font-weight:800;color:#A5311A}" +
    "@media (prefers-reduced-motion:reduce){.ms-band{transition:none}}";
  document.head.append(el("style", null, css));

  // ---- つなぎ ----
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("[data-ms-open]"); if (!a) return;
    if (e.ctrlKey || e.metaKey || e.shiftKey || e.button > 0) return;
    e.preventDefault(); M.openCard(a);
  });
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState !== "visible") return;
    var x = S.get("msExt", null);
    if (x) { S.set("msExt", null); var dt = Date.now() - x.t; if (dt >= 20000 && dt < 21600000) M.markA(x.slug, x.fresh) }
    emit(); if (T.maybeLoggedIn()) M.refresh();
  });
  function init() { mountBands(); emit(); if (T.maybeLoggedIn()) M.refresh() }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
  // サイドバー（tpb.js が描く）のあとに数字を入れる
  setTimeout(emit, 0);
})();
