#!/usr/bin/env bash
# build-single-template.sh — generate navi-recap's themed single-file deck template.
#
# Bakes the vendored ppt-kit design system (base.css + fonts + ALL themes) into
# ONE self-contained HTML file. Themes are embedded as a JS map and applied to a
# live <style id="theme"> element, so pressing T cycles all 37 themes (navi-signal
# + 36 upstream) with NO external files — a true single-file deck that still has
# theme choice. Default theme: navi-signal (navi-recap's green-mono house look).
#
# This is a GENERATED artifact, regenerated from the vendored ppt-kit on every
# upstream sync (scripts/update-ppt.sh calls it). So the themes/base.css inside
# the template stay in sync with upstream; only the nav/T runtime is navi-recap's
# own (upstream's runtime.js can't theme-switch in a single file). Run standalone
# after editing navi-signal.css or this script:  ./scripts/build-single-template.sh
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import json, os, glob, sys

root = sys.argv[1]
own  = f"{root}/plugins/navi-recap/skills/navi-recap"
kit  = f"{own}/ppt-kit"
out  = f"{own}/examples/themed-single-skeleton.html"

def rd(p): return open(p, encoding="utf-8").read()

base_css  = rd(f"{kit}/assets/base.css")
fonts_css = rd(f"{kit}/assets/fonts.css")
anim_css  = rd(f"{kit}/assets/animations/animations.css")

# navi-signal first (default/house), then the 36 upstream themes alphabetically.
themes = {"navi-signal": rd(f"{own}/themes/navi-signal.css")}
for p in sorted(glob.glob(f"{kit}/assets/themes/*.css")):
    themes[os.path.splitext(os.path.basename(p))[0]] = rd(p)
themes_json = json.dumps(themes, ensure_ascii=False)

try:
    sha = json.load(open(f"{kit}/UPSTREAM.json"))["sha"][:10]
except Exception:
    sha = "unknown"

CHROME_CSS = """
/* navi-recap single-file chrome — token-driven so it reskins with the theme */
.nr-bar{position:fixed;left:0;bottom:0;height:3px;background:var(--accent);width:0;z-index:60;transition:width .4s var(--ease,ease)}
.nr-counter{position:fixed;right:28px;bottom:18px;font-family:var(--font-mono,monospace);font-size:12px;letter-spacing:.16em;color:var(--text-3);z-index:60}
.nr-counter b{color:var(--accent)}
.nr-hint{position:fixed;left:28px;top:20px;font-family:var(--font-mono,monospace);font-size:11px;letter-spacing:.05em;color:var(--text-3);opacity:.8;z-index:60}
.nr-toast{position:fixed;left:28px;bottom:18px;font-family:var(--font-mono,monospace);font-size:12px;letter-spacing:.1em;color:var(--text-1);background:var(--surface);border:1px solid var(--border);padding:5px 11px;border-radius:var(--radius-sm,8px);opacity:0;transform:translateY(6px);transition:.25s;z-index:61}
.nr-toast.show{opacity:1;transform:none}
.rv{opacity:0}
.slide.is-active .rv{animation:nr-rise .6s cubic-bezier(.2,.7,.2,1) both;animation-delay:calc(var(--d,0)*80ms)}
@keyframes nr-rise{from{opacity:0;transform:translateY(18px)}to{opacity:1;transform:none}}
"""

SLIDES = """
    <section class="slide is-active">
      <div class="inner">
        <p class="rv" style="--d:0;font-family:var(--font-mono);letter-spacing:.3em;font-size:13px;color:var(--accent);margin:0 0 22px">PRODUCT RECAP</p>
        <h1 class="rv" style="--d:1;font-family:var(--font-display);font-weight:900;font-size:clamp(40px,7vw,92px);line-height:1.04;margin:0">本月做了什么<br><span style="color:var(--accent)">What shipped</span></h1>
        <p class="rv" style="--d:2;color:var(--text-2);max-width:60ch;margin:26px 0 0;line-height:1.8">替换成你的 TL;DR。按 <b>T</b> 切主题 · <b>← →</b> 翻页 · <b>F</b> 全屏。</p>
        <div class="rv" style="--d:3;margin-top:54px;display:flex;gap:42px;font-family:var(--font-mono);font-size:12.5px;letter-spacing:.12em;color:var(--text-3)">
          <div><b style="display:block;color:var(--accent);font-size:24px;margin-bottom:6px">12</b>commits</div>
          <div><b style="display:block;color:var(--accent);font-size:24px;margin-bottom:6px">3</b>repos</div>
          <div><b style="display:block;color:var(--accent);font-size:24px;margin-bottom:6px">5</b>capabilities</div>
        </div>
      </div>
    </section>

    <section class="slide">
      <div class="inner">
        <p class="rv" style="--d:0;font-family:var(--font-mono);letter-spacing:.28em;font-size:12px;color:var(--accent);margin:0 0 18px">THEME 01</p>
        <h2 class="rv" style="--d:1;font-family:var(--font-display);font-weight:900;font-size:clamp(30px,4.6vw,56px);line-height:1.12;margin:0">一页一个主题</h2>
        <p class="rv" style="--d:2;color:var(--text-2);max-width:62ch;margin:18px 0 0;line-height:1.9">从 <code>ppt-kit/templates/single-page/</code> 拷一个版式块进来,替换示例数据。所有颜色/字体都走 CSS 变量,所以换主题时整页跟着变。</p>
      </div>
    </section>

    <section class="slide">
      <div class="inner" style="text-align:center">
        <h2 class="rv" style="--d:0;font-family:var(--font-display);font-weight:900;font-size:clamp(28px,4vw,50px);margin:0">谢谢</h2>
        <p class="rv" style="--d:1;color:var(--text-3);font-family:var(--font-mono);letter-spacing:.2em;margin:20px 0 0">PRODUCT RECAP</p>
      </div>
    </section>
"""

RUNTIME_JS = """
(function(){
  var THEMES = window.__NR_THEMES__, NAMES = Object.keys(THEMES);
  var themeEl = document.getElementById('theme'), toast = document.querySelector('.nr-toast');
  var ti = 0;
  function applyTheme(name){
    if(!THEMES[name]) name = NAMES[0];
    themeEl.textContent = THEMES[name];
    ti = NAMES.indexOf(name);
    document.documentElement.setAttribute('data-theme-name', name);
    try{ localStorage.setItem('nr-theme', name); }catch(e){}
    if(toast){ toast.textContent = name; toast.classList.add('show');
      clearTimeout(toast._t); toast._t = setTimeout(function(){toast.classList.remove('show');}, 1200); }
  }
  function cycleTheme(d){ ti = (ti + d + NAMES.length) % NAMES.length; applyTheme(NAMES[ti]); }
  var saved=null; try{ saved = localStorage.getItem('nr-theme'); }catch(e){}
  applyTheme(saved && THEMES[saved] ? saved : NAMES[0]);

  var slides = [].slice.call(document.querySelectorAll('.slide')), n = slides.length, i = 0;
  var bar = document.querySelector('.nr-bar'), cur = document.querySelector('.nr-counter b'),
      tot = document.querySelector('.nr-counter .tot');
  function pad(x){ return (x<10?'0':'')+x; }
  if(tot) tot.textContent = pad(n);
  function show(idx){
    idx = Math.max(0, Math.min(n-1, idx));
    slides.forEach(function(s,k){ s.classList.toggle('is-active', k===idx); s.classList.toggle('is-prev', k<idx); });
    i = idx;
    if(bar) bar.style.width = ((idx+1)/n*100)+'%';
    if(cur) cur.textContent = pad(idx+1);
    if(location.hash !== '#'+(idx+1)) history.replaceState(null,'','#'+(idx+1));
  }
  function fromUrl(){
    var m = location.hash.match(/^#(\\d+)/) || location.search.match(/[?&]s=(\\d+)/);
    var x = m ? parseInt(m[1],10) : 1; show((x>=1 && x<=n ? x : 1) - 1);
  }
  document.addEventListener('keydown', function(e){
    var k = e.key;
    if(k==='ArrowRight'||k==='PageDown'||k===' '){ e.preventDefault(); show(i+1); }
    else if(k==='ArrowLeft'||k==='PageUp'){ e.preventDefault(); show(i-1); }
    else if(k==='Home'){ show(0); } else if(k==='End'){ show(n-1); }
    else if(k==='t'||k==='T'){ cycleTheme(e.shiftKey?-1:1); }
    else if(k==='f'||k==='F'){ var d=document; if(!d.fullscreenElement){ (d.documentElement.requestFullscreen||function(){})(); } else { (d.exitFullscreen||function(){})(); } }
  });
  window.addEventListener('hashchange', fromUrl);
  var sx=0;
  document.addEventListener('touchstart', function(e){ sx=e.touches[0].clientX; }, {passive:true});
  document.addEventListener('touchend', function(e){ var dx=e.changedTouches[0].clientX-sx; if(Math.abs(dx)>50){ show(dx<0?i+1:i-1); } }, {passive:true});
  fromUrl();
})();
"""

TEMPLATE = """<!DOCTYPE html>
<html lang="zh" data-theme-name="navi-signal">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Product Recap — themed single-file deck</title>
<!-- GENERATED by scripts/build-single-template.sh from vendored ppt-kit (upstream __SHA__).
     Do NOT hand-edit — re-run the script. Themes from upstream stay in sync via update-ppt.sh.
     Single self-contained file: press T to cycle all 37 themes, no external assets. -->
<style id="fonts">
__FONTS__
</style>
<style id="base">
__BASE__
</style>
<style id="anim">
__ANIM__
</style>
<style id="chrome">
__CHROME__
</style>
<!-- filled at runtime with the active theme's CSS (default: navi-signal) -->
<style id="theme"></style>
</head>
<body>
  <div class="deck">
__SLIDES__
  </div>
  <div class="nr-hint">← → 翻页 · T 换主题 · F 全屏</div>
  <div class="nr-bar"></div>
  <div class="nr-counter"><b>01</b> / <span class="tot">01</span></div>
  <div class="nr-toast"></div>
  <script>window.__NR_THEMES__ = __THEMES__;</script>
  <script>
__RUNTIME__
  </script>
</body>
</html>
"""

html = (TEMPLATE
        .replace("__FONTS__", fonts_css)
        .replace("__BASE__", base_css)
        .replace("__ANIM__", anim_css)
        .replace("__CHROME__", CHROME_CSS)
        .replace("__SLIDES__", SLIDES)
        .replace("__THEMES__", themes_json)
        .replace("__RUNTIME__", RUNTIME_JS)
        .replace("__SHA__", sha))

os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w", encoding="utf-8").write(html)
print(f"wrote {out}")
print(f"  {len(themes)} themes (navi-signal + {len(themes)-1} upstream), {len(html)//1024} KB, upstream {sha}")
PY
