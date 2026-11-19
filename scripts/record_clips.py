# サンプル作品をPlaywrightで実際に遊んで録画し、ffmpegで小さいmp4にする。画面の画像（shots/）も撮る。
# Supabaseへの通信はすべて止める（録画のプレイが記録やランキングに入らないように）。
import subprocess, time, sys, os, glob, shutil
from playwright.sync_api import sync_playwright
import pathlib, tempfile
ROOT=str(pathlib.Path(__file__).resolve().parent.parent); OUT=tempfile.mkdtemp(); os.makedirs(OUT,exist_ok=True)
os.makedirs(ROOT+"/clips",exist_ok=True); os.makedirs(ROOT+"/shots",exist_ok=True)
W,H=420,720
EV="""
window.__key=(type,code)=>window.dispatchEvent(new KeyboardEvent(type,{code,key:code==='Space'?' ':code,bubbles:true}));
window.__ptr=(type,x)=>{const c=document.getElementById('c'),r=c.getBoundingClientRect();c.dispatchEvent(new PointerEvent(type,{clientX:r.left+x/c.width*r.width,clientY:r.top+r.height*.8,pointerType:'mouse',buttons:1,pressure:.5,bubbles:true,cancelable:true,pointerId:1}))};
"""
JUMP=EV+"""
(()=>{const c=document.getElementById('c'),g=c.getContext('2d');let held=0;
 __key('keydown','Space');setTimeout(()=>__key('keyup','Space'),60);
 function loop(){const d=g.getImageData(126,250,110,50).data;let near=false,tall=false;
  for(let x=0;x<110;x+=2){const lo=(46*110+x)*4,hi=(4*110+x)*4;if(d[lo]>220&&d[lo+1]<130&&d[lo+2]<130){if(x<70||true)near=true;if(d[hi]>220&&d[hi+1]<130)tall=true}}
  if(near&&!held){__key('keydown','Space');held=1;setTimeout(()=>{__key('keyup','Space');setTimeout(()=>held=0,260)},tall?330:70)}
  requestAnimationFrame(loop)}
 setTimeout(loop,300)})();
"""
STACK=EV+"""
(()=>{let n=0,off=0;__ptr('pointerdown',180);
 function loop(){const d=__dbg();if(d.state==='play'&&d.cur&&d.top){const diff=d.cur.x-(d.top.x+off);if(Math.abs(diff)<=d.speed*.55+.5){__ptr('pointerdown',180);n++;off=(n%4===2)?(n%8===2?14:-11):0}}
  requestAnimationFrame(loop)}
 setTimeout(loop,500)})();
"""
STARS=EV+"""
(()=>{__ptr('pointerdown',180);let tx=180;
 function loop(){const d=__dbg();if(d.state==='play'){const PY=424;
   const rocks=d.items.filter(i=>i.rock&&i.y>PY-170&&i.y<PY+20);
   const stars=d.items.filter(i=>!i.rock&&i.y<PY&&i.y>40).sort((a,b)=>b.y-a.y);
   let want=tx;for(const s of stars){if(!rocks.some(r=>Math.abs(r.x-s.x)<44&&Math.abs(r.y-s.y)<120)){want=s.x;break}}
   for(const r of rocks){if(Math.abs(r.x-want)<46){want=r.x+(want>=r.x?52:-52);if(want<24)want=r.x+56;if(want>336)want=r.x-56}}
   tx=want;__ptr('pointermove',tx)}
  requestAnimationFrame(loop)}
 setTimeout(loop,400)})();
"""
def bot_dom_color(pg):
    pg.click("#start"); t=time.time()
    while time.time()-t<9.2:
        i=pg.evaluate("""()=>{const C=['rgb(214, 69, 61)','rgb(47, 111, 214)','rgb(47, 154, 82)','rgb(217, 164, 0)'];return C.indexOf(getComputedStyle(document.getElementById('word')).color)}""")
        if i>=0: pg.click(f"#grid button >> nth={i}")
        pg.wait_for_timeout(430)
def bot_lights(pg):
    sol=[[(1,1)],[(0,0)],[(0,1),(2,1)],[(1,1),(2,2),(0,3)],[(0,0),(1,2),(3,1),(2,3)]]; ns=[3,3,3,4,4]
    pg.wait_for_timeout(900)
    for si,(s,n) in enumerate(zip(sol,ns)):
        for r,c in s:
            pg.click(f"#board .cell >> nth={r*n+c}"); pg.wait_for_timeout(520)
        pg.wait_for_timeout(500)
        if si<4: pg.click("#next"); pg.wait_for_timeout(600)
def bot_memo(pg):
    pg.wait_for_timeout(500); pg.click("#go"); t=time.time()
    while time.time()-t<10.5:
        d=pg.evaluate("__dbg()")
        if d["playing"] and not d["busy"] and d["pos"]<len(d["seq"]):
            b=pg.locator(f".pad >> nth={d['seq'][d['pos']]}"); b.dispatch_event("pointerdown"); pg.wait_for_timeout(300)
        else: pg.wait_for_timeout(80)
def bot_houkago(pg):
    for pick in (1,0,0):
        pg.wait_for_timeout(1700); pg.click("#text"); pg.wait_for_timeout(900)
        pg.click(f"#choices button >> nth={pick}")
    pg.wait_for_timeout(1700); pg.click("#text"); pg.wait_for_timeout(1500)
def wait(sec): return lambda pg: pg.wait_for_timeout(int(sec*1000))
#        slug      要素      始める前のJS  動かし方        切り出す秒(開始,長さ)  画像を撮る秒
GAMES={"jump":("#c",JUMP,wait(10.5),(0.8,8),6),"stack":("#c",STACK,wait(11),(0.8,8.5),7.5),"stars":("#c",STARS,wait(11),(0.8,8.5),6),
       "color":("body",None,bot_dom_color,(0.5,8),4),"lights":("body",None,bot_lights,(0.6,9),4.35),"memo":("body",None,bot_memo,(0.8,9),6),"houkago":("fixed",None,bot_houkago,(1.0,9),6.2)}
only=sys.argv[1:] or list(GAMES)
srv=subprocess.Popen(["python3","-m","http.server","8766"],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(1)
try:
  with sync_playwright() as p:
    b=p.chromium.launch(executable_path="/usr/bin/google-chrome")
    for slug in only:
        sel,js,bot,(ss,dur),shot_at=GAMES[slug]
        vd=f"{OUT}/{slug}"; shutil.rmtree(vd,ignore_errors=True)
        ctx=b.new_context(viewport={"width":W,"height":H},record_video_dir=vd,record_video_size={"width":W,"height":H},locale="ja-JP")
        ctx.route("https://jwrzqaxuvmdbroemenng.supabase.co/**",lambda r:r.fulfill(status=200,content_type="application/json",body="[]"))
        pg=ctx.new_page(); t0=time.time()
        pg.goto(f"http://localhost:8766/play/{slug}/"); pg.wait_for_timeout(500)
        load=time.time()-t0
        box={"x":0,"y":70,"width":420,"height":580} if sel=="fixed" else pg.locator(sel).bounding_box()
        if sel=="body":
            # 上のタグとランキングなどは切って、遊ぶところだけ
            box=pg.evaluate("""()=>{const els=[...document.body.children].filter(e=>!['SCRIPT','STYLE'].includes(e.tagName)&&!e.hidden&&!e.classList.contains('panel')&&!e.classList.contains('small')&&e.offsetHeight>0);
              const t=Math.min(...els.map(e=>e.getBoundingClientRect().top)),bm=Math.max(...els.map(e=>e.getBoundingClientRect().bottom));return {x:0,y:Math.max(0,t-10),width:innerWidth,height:Math.min(innerHeight,bm+12)-Math.max(0,t-10)}}""")
        if js: pg.evaluate(js)
        import threading
        st=time.time()
        # 途中で画像を撮る
        def later():
            pass
        if callable(bot):
            # ボットの途中で撮れないので、先に時間を測って撮る場合は別ページにしない：単純に bot 後ではなく bot 前に予約
            pg.evaluate(f"setTimeout(()=>window.__shot=1,{int(shot_at*1000)})")
        import types
        done=[False]
        orig_wait=pg.wait_for_timeout
        def w2(ms):
            end=time.time()+ms/1000
            while time.time()<end:
                orig_wait(min(60,max(1,int((end-time.time())*1000))))
                if not done[0] and time.time()-st>=shot_at:
                    done[0]=True; pg.screenshot(path=f"{ROOT}/shots/{slug}.png",clip=box)
        pg.wait_for_timeout=w2
        bot(pg)
        if not done[0]: pg.screenshot(path=f"{ROOT}/shots/{slug}.png",clip=box)
        print(slug,"dbg:",pg.evaluate("window.__dbg?JSON.stringify(__dbg()).slice(0,120):document.title"))
        ctx.close()
        webm=glob.glob(vd+"/*.webm")[0]
        x,y,w,h=[int(v)//2*2 for v in (box["x"],box["y"],box["width"],box["height"])]
        outp=f"{ROOT}/clips/{slug}.mp4"
        subprocess.run(["ffmpeg","-y","-loglevel","error","-ss",str(ss+load),"-t",str(dur),"-i",webm,"-an","-vf",f"crop={w}:{h}:{x}:{y},fps=30,format=yuv420p","-c:v","libx264","-crf","27","-preset","slow","-movflags","+faststart",outp],check=True)
        print(slug,"->",outp,os.path.getsize(outp)//1024,"KB",(w,h))
    b.close()
finally: srv.terminate()
