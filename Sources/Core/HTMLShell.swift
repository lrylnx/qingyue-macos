import Foundation

/* 三种格式共用的 HTML 外壳：CSS + 交互脚本。
 *
 * 为什么把交互放在网页里而不是原生：这一层本来就是 HTML，选中/查找/滚动/
 * 表格就地编辑浏览器天生就有，用原生重写一遍纯属浪费。原生只负责「解析 + 落盘」，
 * 中间的展示与手势交给 WebKit。
 */

enum ViewerMode {
    case doc, sheet, ppt
}

enum HTMLShell {

    static func page(_ mode: ViewerMode, body: String, extraCSS: String = "",
                     extraJS: String = "", topBar: String = "") -> String {
        let modeClass: String
        switch mode {
        case .doc: modeClass = "m-doc"
        case .sheet: modeClass = "m-sheet"
        case .ppt: modeClass = "m-ppt"
        }

        return #"""
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{
  --ink:#1B1B1F; --ink2:#5A6068; --line:#E2E2DF; --paper:#FFFFFF;
  --bg:#EFEEEA; --accent:#1F6FEB; --hit:#FFE58A; --hit2:#FFB4A8;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  font-family:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",-apple-system,sans-serif;
  color:var(--ink); background:var(--bg); -webkit-font-smoothing:antialiased;
  font-size:10.5pt; line-height:1.72;
}
::selection{background:#CFE3FF}
mark{background:var(--hit); color:inherit; padding:0; border-radius:2px}
mark.cur{background:#FFA53D; outline:1px solid #E8890B}

/* ---------- 顶栏 ---------- */
.bar{
  position:sticky; top:0; z-index:100; display:flex; align-items:center; gap:10px;
  height:44px; padding:0 14px; background:rgba(250,250,248,.92);
  border-bottom:1px solid var(--line); backdrop-filter:saturate(1.6) blur(12px);
  font-size:12.5px;
}
.bar .t{font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:42%}
.bar .sp{flex:1}
.bar .chip{
  display:inline-flex; align-items:center; gap:4px; height:24px; padding:0 9px;
  border:1px solid var(--line); border-radius:12px; background:#fff;
  color:var(--ink2); cursor:pointer; user-select:none; white-space:nowrap;
}
.bar .chip:hover{border-color:#C9C9C4; color:var(--ink)}
.bar .chip.on{background:var(--accent); border-color:var(--accent); color:#fff}
.bar input[type=search]{
  width:180px; height:26px; padding:0 10px; border:1px solid var(--line);
  border-radius:13px; outline:none; font-size:12.5px; background:#fff;
  font-family:inherit;
}
.bar input[type=search]:focus{border-color:var(--accent); width:230px}
.bar .cnt{color:var(--ink2); font-variant-numeric:tabular-nums; min-width:56px}

/* ---------- docx ---------- */
.m-doc{padding:0}
.paper-wrap{padding:26px 16px 90px; display:flex; justify-content:center}
.paper{
  background:var(--paper); width:100%; max-width:760px; padding:56px 64px 72px;
  box-shadow:0 1px 2px rgba(0,0,0,.06), 0 10px 30px rgba(0,0,0,.07);
  border-radius:2px; min-height:60vh;
}
.p{margin:0 0 .18em 0; white-space:pre-wrap; word-break:break-word; line-height:1.72}
.pe{height:.72em}
.p.li{padding-left:1.5em; text-indent:-1.5em}
.p.li .bm{display:inline-block; min-width:1.5em; color:var(--ink2)}
.h1,.h2,.h3,.h4,.h5,.h6{font-weight:700; line-height:1.4; white-space:normal}
.h1{font-size:1.72em; margin:1.1em 0 .55em}
.h2{font-size:1.42em; margin:1em 0 .5em}
.h3{font-size:1.22em; margin:.9em 0 .45em}
.h4{font-size:1.1em; margin:.8em 0 .4em}
.h5,.h6{font-size:1em; margin:.7em 0 .35em}
.tb{border-collapse:collapse; width:100%; margin:.7em 0; table-layout:fixed; font-size:.94em}
.tb td{border:1px solid #D4D4D4; padding:4px 7px; vertical-align:top; word-break:break-word}
.tb .cp{margin:0; white-space:pre-wrap}
.tb .vc{}
/* 图片用 inline-block 而不是 block：Word 里的内联图片是行内元素，靠段落的
   text-align 决定居中/靠右。写成 block 的话 text-align 对它完全无效，
   所有"居中图片"都会变成贴左边。vertical-align:bottom 是去掉基线空隙。 */
.pimg{display:inline-block; vertical-align:bottom; margin:.35em 0; border-radius:2px}
.tab{display:inline-block; width:2em}
.vecimg{color:var(--ink2); background:#F3F3F1; padding:1px 6px; border-radius:3px; font-size:.85em}
.pgbrk{height:0; border-top:1px dashed #D8D8D4; margin:1.4em 0}
.p[data-p]{transition:background .12s}
.p[data-p]:hover{background:#FAFAF7}
body.editing .p[data-p]{cursor:text}
.p.sel{background:#EAF2FF; outline:2px solid var(--accent); border-radius:3px}
.p[contenteditable="true"]{background:#fff; outline:2px solid var(--accent); border-radius:3px;
  box-shadow:0 2px 10px rgba(31,111,235,.16)}

/* ---------- xlsx ---------- */
.m-sheet{padding:0}
.grid-wrap{overflow:auto; padding:0 0 80px; max-height:calc(100vh - 44px)}
.sht{border-collapse:separate; border-spacing:0; font-size:12.5px; background:#fff;
  table-layout:fixed; font-variant-numeric:tabular-nums}
.sht th,.sht td{
  border-right:1px solid #DEE2E7; border-bottom:1px solid #DEE2E7;
  padding:2px 7px; height:23px; white-space:nowrap; overflow:hidden;
  text-overflow:ellipsis; max-width:340px;
}
.sht thead th{
  position:sticky; top:0; z-index:3; background:#F3F5F8; font-weight:500;
  color:#6B7280; font-size:11.5px; text-align:center; user-select:none;
}
.sht thead th[data-col]{cursor:pointer}
.sht thead th[data-col]:hover{background:#E8ECF1; color:#374151}
.sht .rn{
  position:sticky; left:0; z-index:2; background:#F3F5F8; color:#9AA1AA;
  text-align:right; font-size:11px; font-weight:400; user-select:none;
  width:46px; min-width:46px; padding:2px 8px 2px 4px;
}
.sht .corner{position:sticky; left:0; top:0; z-index:5; width:46px; min-width:46px}
.sht td.num{text-align:right}
.sht td[data-c]{cursor:cell}
.sht td[data-c]:hover{background:#F7FAFF}
.sht td.sel{background:#EAF2FF !important; outline:2px solid var(--accent); outline-offset:-2px}
.sht td[contenteditable="true"]{
  background:#fff !important; outline:2px solid var(--accent); outline-offset:-2px;
  overflow:visible; white-space:pre; z-index:9; position:relative;
}
.sht tr.hide{display:none}
.note{
  position:sticky; left:0; padding:8px 14px; color:#8A6D1B; background:#FFF6DB;
  border-top:1px solid #EFE0AE; font-size:12px;
}

/* ---------- pptx ---------- */
.m-ppt{padding:0}
.stage{
  padding:20px 20px 90px; display:flex; flex-direction:column; align-items:center; gap:20px;
}
.slide{
  position:relative; background:#fff; overflow:hidden; flex:none;
  box-shadow:0 1px 2px rgba(0,0,0,.08), 0 8px 26px rgba(0,0,0,.10);
  border-radius:3px;
}
.sh{position:absolute; overflow:visible}
.sh.pic{background:transparent}
.sh img{display:block}
/* 文本框不裁切：PPT 的文本框本身就是允许文字溢出的，
   设成 hidden 会把超出一行的那半句直接吃掉 */
.sh .tx{
  display:flex; flex-direction:column; width:100%; height:100%;
  overflow:visible; word-break:break-word;
}
.sh .tx p{margin:0; line-height:1.18; white-space:pre-wrap}
/* wrap="none"：文字按内容宽度排版，超出部分照样显示（PPT 的默认行为） */
.sh .tx.nowrap{width:max-content}
.sh .tx.nowrap p{white-space:nowrap}
.sh .bu{display:inline-block; width:1.1em; margin-left:-1.1em}
.sh-flow{padding:6px 10px; color:#333; font-size:14px; line-height:1.5}
.sh-flow p{margin:0}
.pt{border-collapse:collapse; width:100%; height:100%; font-size:13px}
.pt td{border:1px solid rgba(0,0,0,.18); padding:4px 6px; vertical-align:middle; overflow:hidden}
.pnum{
  position:fixed; right:16px; bottom:16px; z-index:60; display:flex; gap:6px; align-items:center;
  background:rgba(255,255,255,.94); border:1px solid var(--line); border-radius:18px;
  padding:5px 10px; font-size:12px; color:var(--ink2); box-shadow:0 4px 14px rgba(0,0,0,.10);
  font-variant-numeric:tabular-nums;
}
.pnum button{
  width:24px; height:24px; border:none; background:#F1F2F4; border-radius:12px;
  cursor:pointer; color:var(--ink2); font-size:13px; line-height:1;
}
.pnum button:hover{background:#E4E6EA}
.pnum input{width:38px; text-align:center; border:1px solid var(--line); border-radius:4px;
  font-size:12px; font-family:inherit; outline:none; padding:2px 0}

/* ---------- 打印 ---------- */
@media print{
  body{background:#fff}
  .bar,.pnum,.note{display:none !important}
  .paper-wrap{padding:0}
  .paper{box-shadow:none; max-width:none; padding:0}
  .slide{box-shadow:none; break-after:page; zoom:1 !important}
  .grid-wrap{max-height:none; overflow:visible}
}
</style>
<style>\#(extraCSS)</style>
</head>
<body class="\#(modeClass)">
\#(topBar)
\#(body)
<script>
const host = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ly) || null;
function send(o){ if(host) host.postMessage(o); }

/* ---------- 查找高亮 ---------- */
let hits = [], hitIdx = -1;
function clearHits(){
  document.querySelectorAll('mark').forEach(m=>{
    const p = m.parentNode;
    if(!p) return;
    p.replaceChild(document.createTextNode(m.textContent), m);
    p.normalize();
  });
  hits = []; hitIdx = -1;
  const el = document.getElementById('hitCount');
  if(el) el.textContent = '';
}
function highlight(q){
  clearHits();
  if(!q || !q.trim()) return;
  const needle = q.toLowerCase();
  const root = document.getElementById('root') || document.body;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n){
      if(!n.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      const tag = n.parentNode && n.parentNode.nodeName;
      if(tag === 'SCRIPT' || tag === 'STYLE' || tag === 'MARK') return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  const nodes = [];
  while(walker.nextNode()) nodes.push(walker.currentNode);
  for(const n of nodes){
    const text = n.nodeValue, lower = text.toLowerCase();
    let from = 0, idx;
    const frags = [];
    while((idx = lower.indexOf(needle, from)) !== -1){
      frags.push([idx, idx + needle.length]);
      from = idx + needle.length;
      if(frags.length > 400) break;
    }
    if(!frags.length) continue;
    const frag = document.createDocumentFragment();
    let cur = 0;
    for(const [a,b] of frags){
      if(a > cur) frag.appendChild(document.createTextNode(text.slice(cur, a)));
      const m = document.createElement('mark');
      m.textContent = text.slice(a, b);
      frag.appendChild(m);
      hits.push(m);
      cur = b;
    }
    if(cur < text.length) frag.appendChild(document.createTextNode(text.slice(cur)));
    n.parentNode.replaceChild(frag, n);
  }
  const el = document.getElementById('hitCount');
  if(el) el.textContent = hits.length ? ('1 / ' + hits.length) : '无结果';
  if(hits.length) stepHit(1);
}
function stepHit(dir){
  if(!hits.length) return;
  if(hitIdx >= 0 && hits[hitIdx]) hits[hitIdx].classList.remove('cur');
  hitIdx = (hitIdx + dir + hits.length) % hits.length;
  const m = hits[hitIdx];
  m.classList.add('cur');
  m.scrollIntoView({block:'center', behavior:'smooth'});
  const el = document.getElementById('hitCount');
  if(el) el.textContent = (hitIdx + 1) + ' / ' + hits.length;
}
document.addEventListener('keydown', e=>{
  if((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f'){
    const box = document.getElementById('q');
    if(box){ e.preventDefault(); box.focus(); box.select(); }
  }
  if(e.key === 'Escape') document.activeElement && document.activeElement.blur();
});

/* ---------- 缩放（pptx） ---------- */
function fitSlides(){
  const slides = document.querySelectorAll('.slide');
  if(!slides.length) return;
  const avail = Math.min(window.innerWidth - 40, 1400);
  const w = parseFloat(slides[0].dataset.w || slides[0].offsetWidth);
  let s = avail / w;
  s = Math.max(0.24, s);
  document.documentElement.style.setProperty('--zoom', s);
  slides.forEach(el=>{ el.style.zoom = s; });
}
window.addEventListener('resize', ()=>{ fitSlides(); });
</script>
<script>\#(extraJS)</script>
</body></html>
"""#
    }

    // MARK: - 顶栏

    static func topBar(title: String, mode: ViewerMode, trailing: String = "") -> String {
        let safe = XMLText.escape(title)
        return """
<div class="bar">
  <div class="t">\(safe)</div>
  <div class="sp"></div>
  <input id="q" type="search" placeholder="查找 ⌘F" autocomplete="off">
  <span class="cnt" id="hitCount"></span>
  \(trailing)
</div>
"""
    }

    /// 共用的查找脚本挂到顶栏上
    static let searchJS = #"""
(function(){
  const q = document.getElementById('q');
  if(!q) return;
  let timer = null;
  q.addEventListener('input', ()=>{
    clearTimeout(timer);
    timer = setTimeout(()=>highlight(q.value), 220);
  });
  q.addEventListener('keydown', e=>{
    if(e.key === 'Enter'){ e.preventDefault(); stepHit(e.shiftKey ? -1 : 1); }
    if(e.key === 'Escape'){ q.value=''; clearHits(); q.blur(); }
  });
})();
"""#
}
