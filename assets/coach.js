/* 感想シートのコーチ：書き出しチップ・ルールのコーチ（AIなし・端末の中だけ）・AIのコーチ（任意・ボタン）
   使い方（feed_template.html）：const C = TPBCoach.mount({ta, el, SB_URL, SB_KEY, getSession}); 感想シートを開くたび C.open(g) */
(function(){
"use strict";
const reduce = () => matchMedia('(prefers-reduced-motion:reduce)').matches;
const nsLen = s => [...String(s).replace(/[\s　]/g,'')].length;
const MIN_AI = 20;          // AIに見てもらうのに、自分で打つ字数（空白除く）
const AI_TIMEOUT = 10000;   // 10秒
const MAX_NOTES = 2;

// ---- 1. 書き出し（2段目 × 1段目 = 7 × 3） ----
const KINDS = [['good','👍 良かったところ'],['bad','🤔 気になったところ'],['idea','💡 こうしたら？']];
const TOPICS = ['操作','見た目','音','ルール・目的','難しさ','最初のわかりやすさ','その他'];
const STEMS = {
  good:{'操作':'操作で気持ちよかったのは、','見た目':'見た目で好きだったのは、','音':'音で印象に残ったのは、','ルール・目的':'ルールで面白いと思ったのは、','難しさ':'難しさがちょうどよかったのは、','最初のわかりやすさ':'最初にわかりやすかったのは、','その他':'ほかに良かったのは、'},
  bad:{'操作':'操作で気になったのは、','見た目':'見た目で見づらかったのは、','音':'音で気になったのは、','ルール・目的':'ルールや目的でわからなかったのは、','難しさ':'難しく感じたのは、','最初のわかりやすさ':'最初に迷ったのは、','その他':'ほかに気になったのは、'},
  idea:{'操作':'操作は、こうすると、','見た目':'見た目は、こうすると、','音':'音は、こうすると、','ルール・目的':'ルールは、こうすると、','難しさ':'難しさは、こうすると、','最初のわかりやすさ':'最初の説明は、こうすると、','その他':'ほかには、こうすると、'}
};
// 作者が確かめたいこと（g.check）に近い2段目
function hotTopics(g){
  const s=String((g&&g.check)||''), out=new Set();
  if(/操作|手触り|手ざわり|コントロール/.test(s)) out.add('操作');
  if(/見た目|絵|グラフィック|デザイン|色|画面/.test(s)) out.add('見た目');
  if(/音|BGM|サウンド/.test(s)) out.add('音');
  if(/ルール|目的|楽し|面白|おもしろ|アイデア|新し/.test(s)) out.add('ルール・目的');
  if(/難し|バランス|ちょうど/.test(s)) out.add('難しさ');
  if(/チュートリアル|最初|説明|わかりやす|導入|はじめ/.test(s)) out.add('最初のわかりやすさ');
  return out;
}

// ---- 2. ルールのコーチ ----
const TONE = [   // [きつい言葉, 置き換え（null は候補なし）] 長いものを先に
  ['やる価値がない','自分には合わなかった'],['やる価値ない','自分には合わなかった'],['センスがない','自分の好みとは違った'],['センスない','自分の好みとは違った'],
  ['クソゲー','気になるところが多いゲーム'],['つまらない','自分には合わなかった'],['つまんない','自分には合わなかった'],['つまらん','自分には合わなかった'],
  ['意味不明','よくわからなかった'],['下手くそ','これからに期待したい'],['最悪','かなり気になった'],['ゴミ','改善してほしいところが多い'],
  ['ひどい','かなり気になる'],['酷い','かなり気になる'],['駄作','自分には合わなかった作品'],['ダサい','自分の好みではない'],
  ['クソ','かなり気になる'],['くそ','かなり気になる'],['糞','かなり気になる'],['バカ',null],['馬鹿',null],['アホ',null],['死ね',null]
];
const VAGUE = /面白[いかっただすくな]*|おもしろ[いかっただすくな]*|楽し[いかっただすくな]*|よかっ?た|良かっ?た|よい|良い|いい|最高|好き|すごい|凄い|神ゲー|難し[いかっただすくな]*|むずかし[いかっただすくな]*|かった|です|でした|ました|とても|すごく|めっちゃ|ちょっと|少し|けっこう|かなり|ね|よ|な|です|ます/g;
const STOP = new Set(['ゲーム','プレイ','テストプレイ','タイトル','作品','スタート','ステージ','テスト','プロトタイプ','一','二','三','時','回','個','同','的','後','中','前','全','本','度','間','内','他','方','点','目','気','手','事','物','者','分','自','何','毎','次','順','部','今','人','用','上','下','出','入','見','行','来','合','大','小','多','少','新','高','低','長','短','感']);
const GENERIC_NOTE = 'これはどのゲームでも言えそう。この作品ならではの場面を1つ入れてみて';
const norm = s => String(s||'').normalize('NFKC');
function gameTerms(g){
  const src=norm([g.title,g.genre,g.oneliner,g.check,g.question,g.controls,g.minutes,g.description].concat(g.highlights||[]).join('　'));
  const set=new Set();
  (src.match(/[ァ-ヶー]{2,}|[一-龠々]+|[0-9]+|[A-Za-z]{2,}/g)||[]).forEach(t=>{
    t=t.toLowerCase();
    if(STOP.has(t)) return;
    if(/^[ァ-ヶー]+$/.test(t)&&t.length<2) return;
    set.add(t);
    if(/^[一-龠々]{3,}$/.test(t)) set.add(t.slice(0,2));          // 操作感 → 操作
    if(/^[一-龠々]+$/.test(t)&&t.length>=2) [...t].forEach(c=>{ if(!STOP.has(c)) set.add(c) }); // 勝負 → 勝, 負 は多すぎるので下で絞る
  });
  // 1文字の漢字は、色・赤・光のように作品の中身を言う字だけ残す（「感」「点」などは STOP）。数字は2文字以上か、単位つき
  return [...set].filter(t=>t.length>=2||/^[一-龠々]$/.test(t)||/^[0-9]+$/.test(t));
}
function hasTerm(text,terms){ const t=norm(text).toLowerCase(); return terms.some(x=>t.includes(x)) }
function toneHits(text){
  const hits=[];
  TONE.forEach(([w,r])=>{ if(text.includes(w)&&!hits.some(h=>h.w.includes(w))) hits.push({w,r}) });
  return hits;
}
function isVagueOnly(text){ const rest=norm(text).replace(VAGUE,'').replace(/[\s　、。！？!?～〜ー…・w笑]/g,''); return [...rest].length<3 }
const REASON=/から|ので|ため|けど|けれど|おかげ|せいで|たら|なので|のに|ところが|だけど/;
const SCENE=/場面|とき|時|面|ステージ|最初|最後|途中|ところ|あたり|回目|秒|[0-9０-９]/;
function analyze(text,terms){
  const t=text.trim(), n=nsLen(t), notes=[];
  if(n<3) return notes;
  const th=toneHits(t);
  if(th.length) notes.push({kind:'tone',msg:'この言い方だと、作者が傷つくかも。',acts:th.filter(h=>h.r).slice(0,2).map(h=>({label:'「'+h.w+'」→「'+h.r+'」',do:'replace',w:h.w,r:h.r}))});
  const term=hasTerm(t,terms);
  if(n<15||isVagueOnly(t)) notes.push({kind:'specific',msg:'どの場面で、なぜそう思った？を1つ足すと、作者に伝わりやすいよ',acts:[{label:'書き出しを足す',do:'append',s:'特に〜の場面で、'}]});
  else if(!term) notes.push({kind:'generic',msg:GENERIC_NOTE,acts:[]});
  if(!notes.length&&term&&n>=25&&REASON.test(t)&&(SCENE.test(norm(t))||n>=40)) notes.push({kind:'praise',msg:'場面と理由が書けてる！',acts:[]});
  return notes.slice(0,MAX_NOTES);
}

// ---- 3. 組み立て ----
function mount(o){
  const {ta,el,SB_URL,SB_KEY,getSession}=o, $=id=>document.getElementById(id);
  const stem1=$('stem1'), stem2=$('stem2'), hint=$('stemHint'), notesBox=$('cNotes'), undoBox=$('cUndo'), aiBtn=$('aiBtn'), aiWhy=$('aiWhy'), aiOut=$('aiOut'), cMsg=$('cMsg');
  let game=null, terms=[], kind=null, timer=0, sig='', undo=null, prevLen=0, typed=0, busy=false, ai=null, hot=new Set(), applyN=0;

  // ---- 感想欄の書きかえ（すべてここを通る。自分で打った字には数えない） ----
  function setText(v,sel){
    ta.value=v; if(sel) ta.setSelectionRange(sel[0],sel[1]); else ta.setSelectionRange(v.length,v.length);
    ta.dispatchEvent(new Event('input',{bubbles:true}));      // isTrusted=false。この下の input ハンドラは数えず、字数の表示（upd）だけ動く
  }
  function remember(label){ undo={v:ta.value,a:ta.selectionStart,b:ta.selectionEnd,label}; showUndo() }
  function showUndo(){
    undoBox.textContent=''; if(!undo){ undoBox.hidden=true; return }
    undoBox.hidden=false; undoBox.append(el('span',{},undo.label+' '),el('button',{type:'button',class:'cbtn',onclick:()=>{ const u=undo; undo=null; setText(u.v,[u.a,u.b]); showUndo(); ta.focus() }},'元に戻す'));
  }
  function insertAtCaret(s,selectMark){
    const v=ta.value, a=ta.selectionStart, b=ta.selectionEnd, before=v.slice(0,a);
    const pre=(before&&!/[。！？!?、\n]$/.test(before))?'。':'';
    const add=pre+s;
    if([...v.slice(0,a)+add+v.slice(b)].length>(+ta.maxLength||400)){ flash('これ以上は入らないよ（400字まで）'); return false }
    const nv=v.slice(0,a)+add+v.slice(b), at=a+pre.length;
    if(selectMark){ const k=add.indexOf(selectMark); setText(nv,[a+k,a+k+selectMark.length]) } else setText(nv,[a+add.length,a+add.length]);
    return at||true;
  }
  let flashT=0;
  function flash(t){ cMsg.textContent=t; clearTimeout(flashT); flashT=setTimeout(()=>{cMsg.textContent=''},3500) }

  // ---- 書き出しチップ ----
  KINDS.forEach(([k,label])=>stem1.append(el('button',{type:'button',class:'chip k-'+k,'aria-pressed':'false','data-k':k,onclick:()=>pickKind(k)},label)));
  TOPICS.forEach(t=>stem2.append(el('button',{type:'button',class:'chip t2','data-t':t,onclick:()=>pickTopic(t)},t)));
  function pickKind(k){
    kind=(kind===k)?null:k;
    stem1.querySelectorAll('.chip').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.k===kind)));
    stem2.hidden=!kind; hint.hidden=!kind||!hot.size;
    stem2.className='chips c2 k-'+(kind||'');
  }
  function pickTopic(t){
    if(!kind) return;
    const r=insertAtCaret(STEMS[kind][t]); if(r){ ta.focus(); flash('書き出しを入れたよ。続きを書いてね') }
  }
  function paintHot(){
    stem2.querySelectorAll('.chip').forEach(b=>{ const h=hot.has(b.dataset.t); b.classList.toggle('hot',h); b.setAttribute('aria-label',b.dataset.t+(h?'（作者が確かめたいこと）':'')); b.textContent=(h?'★ ':'')+b.dataset.t });
    hint.hidden=!kind||!hot.size;
  }

  // ---- ルールのコーチ（入力が止まって 600ms 後） ----
  function run(){
    const list=analyze(ta.value,terms), s=JSON.stringify(list.map(n=>[n.kind,n.msg,n.acts.map(a=>a.label)]));
    if(s===sig) return; sig=s; renderNotes(list);
  }
  function renderNotes(list){
    notesBox.textContent='';
    list.forEach((n,i)=>{
      const card=el('div',{class:'cnote n-'+n.kind+(i%2?' alt':'')},el('p',{},n.msg));
      if(n.acts.length){ const row=el('div',{class:'cacts'}); n.acts.forEach(a=>row.append(el('button',{type:'button',class:'cbtn',onclick:()=>doAct(a)},a.label))); card.append(row) }
      notesBox.append(card);
    });
    if(ai) ai.notes.forEach(c=>notesBox.append(aiNote(c)));
  }
  function doAct(a){
    if(a.do==='replace'){ remember('言い方を直しました。'); setText(ta.value.split(a.w).join(a.r)); }
    else if(a.do==='append'){ remember('書き出しを足しました。'); ta.setSelectionRange(ta.value.length,ta.value.length); if(!insertAtCaret(a.s,'〜')){ undo=null; showUndo() } }
    ta.focus(); clearTimeout(timer); run();
  }
  const KLABEL={specific:'具体的に',tone:'言い方',generic:'この作品ならでは',praise:'いいね',idea:'アイデア'};
  function aiNote(c){ return el('div',{class:'cnote n-ai n-'+c.kind},el('p',{},c.message)) }

  // ---- 入力の見張り ----
  ta.addEventListener('input',e=>{
    const now=nsLen(ta.value), d=now-prevLen; prevLen=now;
    if(e.isTrusted){
      if(!/paste|drop|replace/i.test(e.inputType||'')) typed=Math.max(0,typed+d); else if(d<0) typed=Math.max(0,typed+d);
      if(undo){ undo=null; showUndo() }
      if(ai&&ai.rewrite){ ai.rewrite=null; renderAi() }     // 文を直したら、古い「こう直してみる？」は引っこめる
    }
    typed=Math.min(typed,now);
    clearTimeout(timer); timer=setTimeout(run,e.isTrusted?600:0);
    syncAi();
  });

  // ---- AIのコーチ ----
  async function syncAi(){
    const ses=await getSession(); const left=MIN_AI-typed;
    let why='';
    if(!ses) why='ログインすると使えます';
    else if(left>0) why='自分で'+MIN_AI+'字以上書くと押せるよ（あと'+left+'字）';
    aiBtn.disabled=busy||!!why; aiBtn.setAttribute('aria-busy',String(busy));
    if(!busy) aiWhy.textContent=why||(ai&&typeof ai.remaining==='number'?'今日あと'+ai.remaining+'回':'');
  }
  aiBtn.addEventListener('click',async()=>{
    if(busy||typed<MIN_AI) return;
    const ses=await getSession(); if(!ses||!ses.access_token){ aiFail(); return }
    busy=true; aiBtn.disabled=true; aiBtn.textContent='見ています…'; aiWhy.textContent='';
    const ctrl=new AbortController(), tm=setTimeout(()=>ctrl.abort(),AI_TIMEOUT), g=game;
    const text=ta.value.trim();
    let res=null, st=0;
    try{
      const r=await fetch(SB_URL+'/functions/v1/feedback-coach',{method:'POST',signal:ctrl.signal,headers:{'Content-Type':'application/json',Authorization:'Bearer '+ses.access_token,apikey:SB_KEY},
        body:JSON.stringify({slug:g.slug,title:g.title,genre:g.genre||'',description:[g.oneliner].concat(g.highlights||[]).filter(Boolean).join(' / '),check:g.check||'',text})});
      st=r.status; if(r.ok) res=await r.json();
    }catch(e){ res=null }
    clearTimeout(tm); busy=false; aiBtn.textContent='🤖 AIに見てもらう';
    if(game!==g) return;     // 待っているあいだにシートを閉じた
    const okShape=res&&Array.isArray(res.comments);
    if(!okShape){ ai=null; aiFail(st); renderAi(); renderNotes(analyze(ta.value,terms)); syncAi(); return }
    ai={notes:res.comments.filter(c=>c&&typeof c.message==='string'&&c.message).slice(0,3).map(c=>({kind:String(c.kind||'idea'),message:c.message})),rewrite:(typeof res.rewrite==='string'&&res.rewrite.trim())?res.rewrite.trim():null,remaining:typeof res.remaining==='number'?res.remaining:null};
    aiFailBox(false); sig=''; run(); renderAi(); syncAi();
  });
  function aiFailBox(on,t){ $('aiFail').hidden=!on; $('aiFail').textContent=on?(t||'いまはAIコーチを使えません。ルールのコーチだけで続けられます'):'' }
  function aiFail(st){ aiFailBox(true,st===429?'いまはAIコーチを使えません（今日の回数を使い切ったかも）':null); syncAi() }
  function renderAi(){
    aiOut.textContent='';
    if(!ai||!ai.rewrite) return;
    const rw=ai.rewrite;
    aiOut.append(el('div',{class:'crewrite'},el('p',{class:'crt'},'こう直してみる？'),el('p',{class:'crb'},rw),
      el('div',{class:'cacts'},el('button',{type:'button',class:'cbtn pri',onclick:()=>{ remember('AIの案にしました。'); setText(rw); ai.rewrite=null; renderAi(); ta.focus() }},'これにする'))));
  }

  // ---- シートを開くたび ----
  function open(g){
    game=g; terms=gameTerms(g); hot=hotTopics(g); kind=null; undo=null; ai=null; typed=0; prevLen=nsLen(ta.value); sig=''; busy=false;
    clearTimeout(timer); stem1.querySelectorAll('.chip').forEach(b=>b.setAttribute('aria-pressed','false')); stem2.hidden=true; paintHot(); hint.hidden=true;
    notesBox.textContent=''; aiOut.textContent=''; aiFailBox(false); cMsg.textContent=''; showUndo(); aiBtn.textContent='🤖 AIに見てもらう'; syncAi();
  }
  function close(){ game=null; clearTimeout(timer) }
  return {open,close,analyze:t=>analyze(t,terms),terms:()=>terms.slice()};
}
window.TPBCoach={mount,analyze,gameTerms,STEMS,TOPICS};
})();
