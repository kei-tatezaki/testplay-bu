/* テストプレイ部：ショートの並び順（作る人優先）
 *
 * 1. まず「箱」で分ける
 *    この端末で遊べて未プレイ → 遊んだけど感想はまだ → 感想を送った → この端末では遊べない
 * 2. 箱の中は点数順
 *    + 新作（出てから7日間、だんだん弱くなる）
 *    + 感想が少ない作品（0件がいちばん強い）… 作る人に反応を届けるため
 *    + 遊ばれた数が少ない作品
 *    + 遊びたい度（感想の「また遊びたい」と👍🤔。件数が少ないうちは50%に寄せる）
 *    + その人の好み（👍・感想を送った作品と同じジャンル／確かめたいことは上、🤔・すぐスワイプした作品の仲間は下）
 *    − その作品自体をすぐスワイプした回数、🤔を押した作品
 *    + 少しのランダム（人と日によって変わる。同じ日に開き直しても順番は変わらない）
 * 3. 10本ごとに最低3本は「感想が3件未満」の作品を入れる
 */
(function (root) {
  "use strict";
  var EMPTY = { plays: 0, likes: 0, hmms: 0, feedbacks: 0, again_much: 0, again_some: 0 };

  function hash01(str) {
    var h = 2166136261;
    for (var i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
    return ((h >>> 0) % 100000) / 100000;
  }
  function rating(s) {
    if (!s) return null;
    var n = s.feedbacks + s.likes + s.hmms;
    if (!n) return null;
    return (s.again_much + 0.5 * s.again_some + s.likes + 3 * 0.5) / (n + 3);
  }
  function tagsOf(g) {
    var t = [];
    if (g.genre) t.push("g:" + g.genre);
    if (g.check) t.push("c:" + g.check);
    return t;
  }
  function affinity(games, hist) {
    var a = {}, by = {};
    games.forEach(function (g) { by[g.slug] = g; });
    function add(slug, v) { var g = by[slug]; if (g) tagsOf(g).forEach(function (t) { a[t] = (a[t] || 0) + v; }); }
    Object.keys(hist.reacts || {}).forEach(function (slug) {
      if (hist.reacts[slug] === "like") add(slug, 1);
      if (hist.reacts[slug] === "hmm") add(slug, -1);
    });
    (hist.sent || []).forEach(function (slug) { add(slug, 0.5); });
    Object.keys(hist.seen || {}).forEach(function (slug) {
      var q = (hist.seen[slug] || {}).quick || 0;
      if (q) add(slug, -0.3 * Math.min(q, 3));
    });
    return a;
  }
  function score(g, ctx) {
    var s = ctx.stats[g.slug] || EMPTY, x = 0;
    var age = g.added ? (ctx.today - Date.parse(g.added + "T00:00:00+09:00")) / 864e5 : 99;
    if (age >= 0 && age < 7) x += 1.0 * (1 - age / 7);
    x += 1.2 / (1 + s.feedbacks);
    x += 0.4 / (1 + s.plays / 5);
    var r = rating(s);
    if (r !== null) x += 0.8 * (r - 0.5);
    var aff = 0;
    tagsOf(g).forEach(function (t) { aff += ctx.aff[t] || 0; });
    x += 0.4 * Math.max(-3, Math.min(3, aff));
    var seen = (ctx.hist.seen || {})[g.slug];
    if (seen && seen.quick) x -= 0.3 * Math.min(seen.quick, 3);
    if ((ctx.hist.reacts || {})[g.slug] === "hmm") x -= 1.0;
    x += 0.3 * hash01(ctx.seed + ":" + g.slug);
    return { g: g, x: x, s: s, rating: r };
  }
  function rank(games, ctx) {
    ctx.aff = affinity(games, ctx.hist);
    var played = new Set(ctx.hist.played || []), sent = new Set(ctx.hist.sent || []);
    function box(o) {
      if (!ctx.canPlay(o.g)) return 3;
      if (sent.has(o.g.slug)) return 2;
      if (played.has(o.g.slug)) return 1;
      return 0;
    }
    var pool = games.map(function (g) { var o = score(g, ctx); o.box = box(o); return o; });
    pool.sort(function (a, b) { return a.box - b.box || b.x - a.x; });
    var out = [];
    while (pool.length) {
      var pos = out.length, block = out.slice(pos - (pos % 10));
      var low = block.filter(function (o) { return o.s.feedbacks < 3; }).length;
      var left = 10 - block.length, k = 0;
      if (low < 3 && left <= 3 - low) {
        var j = pool.findIndex(function (o) { return o.s.feedbacks < 3 && o.box === pool[0].box; });
        if (j >= 0) k = j;
      }
      out.push(pool.splice(k, 1)[0]);
    }
    return out;
  }
  var api = { rank: rank, rating: rating, hash01: hash01 };
  root.TPBRank = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
