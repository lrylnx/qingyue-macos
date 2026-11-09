import Foundation

/* 把解析结果拼成可交互的 HTML 页面。每种格式一份脚本。 */

enum Pages {

    // MARK: - Word

    static func docx(_ d: DocxDocument, name: String, editing: Bool) -> String {
        let paperWidth = max(520, d.pageWidthPt * 4.0 / 3.0)
        let padX = max(28, d.marginPt * 4.0 / 3.0)
        let size = d.defaultBodySize.map { "body{font-size:\(fmt($0))pt}" } ?? ""

        let css = #"""
        .paper{max-width:\#(fmt(paperWidth))px; padding:52px \#(fmt(padX))px 72px}
        \#(size)
        """#

        let bar = HTMLShell.topBar(title: name, mode: .doc, trailing: """
          <span class="chip \(editing ? "on" : "")" id="btnEdit">编辑</span>
        """)

        let body = """
<div class="paper-wrap"><div class="paper" id="root">\(d.html)</div></div>
"""

        let js = #"""
(function(){
  let editMode = \#(editing ? "true" : "false");
  let cur = null;

  /* 取段落文字时跳过项目符号/编号标记，否则保存后会多出 "•" 前缀 */
  function textOf(el){
    let s = '';
    el.childNodes.forEach(n=>{
      if(n.nodeType === 1 && n.classList && n.classList.contains('bm')) return;
      s += n.textContent;
    });
    return s;
  }

  function begin(el){
    if(cur === el) return;
    if(cur) end(cur, true);
    cur = el;
    el.dataset.orig = textOf(el);
    el.classList.add('sel');
    el.contentEditable = 'true';
    el.focus();
    const r = document.createRange();
    r.selectNodeContents(el);
    const sel = getSelection();
    sel.removeAllRanges(); sel.addRange(r);
  }

  function end(el, commit){
    if(!el) return;
    const v = textOf(el);
    el.contentEditable = 'false';
    el.classList.remove('sel');
    if(el === cur) cur = null;
    if(!commit || v === el.dataset.orig) return;
    el.style.opacity = '.55';
    send({action:'editText', p: parseInt(el.dataset.p), text: v});
  }

  const paper = document.getElementById('root');
  paper.querySelectorAll('.p[data-p]').forEach(el=>{
    el.addEventListener('dblclick', e=>{
      if(el.querySelector('img') || !el.innerHTML.replace(/<[^>]+>/g,'').trim()) return;
      e.preventDefault();
      begin(el);
    });
    el.addEventListener('click', ()=>{
      if(editMode && !el.isContentEditable) begin(el);
    });
    el.addEventListener('blur', ()=>{ if(el.isContentEditable) end(el, true); });
    el.addEventListener('keydown', e=>{
      if(e.key === 'Enter' && !e.shiftKey){ e.preventDefault(); el.blur(); }
      if(e.key === 'Escape'){ el.textContent = el.dataset.orig; el.blur(); }
    });
    el.addEventListener('paste', e=>{
      e.preventDefault();
      const t = (e.clipboardData || window.clipboardData).getData('text');
      document.execCommand('insertText', false, t);
    });
  });

  const btn = document.getElementById('btnEdit');
  if(btn) btn.addEventListener('click', ()=>{
    editMode = !editMode;
    btn.classList.toggle('on', editMode);
    document.body.classList.toggle('editing', editMode);
    send({action:'toggleEdit', on: editMode});
  });
  if(editMode) document.body.classList.add('editing');

  /* Swift 处理完编辑结果后回调 */
  window.lyEditResult = function(ok, p, text){
    const el = paper.querySelector('.p[data-p="'+p+'"]');
    if(!el) return;
    el.style.opacity = '';
    if(!ok){
      el.textContent = el.dataset.orig || text;
      flash(el, '#FFD9D4');
    } else {
      flash(el, '#D9F5DA');
    }
  };
  window.lyEditDone = function(p){ window.lyEditResult(true, p, ''); };

  function flash(el, c){
    const old = el.style.background;
    el.style.background = c;
    setTimeout(()=>{ el.style.background = old; }, 420);
  }
})();
"""# + "\n" + HTMLShell.searchJS

        return HTMLShell.page(.doc, body: body, extraCSS: css, extraJS: js, topBar: bar)
    }

    /// 老式 .doc / .wps：只读。用同一套纸张样式，但不接编辑（二进制写回没做）
    static func legacyDoc(_ d: LegacyDoc, name: String) -> String {
        let paperWidth = max(520, d.pageWidthPt * 4.0 / 3.0)
        let padX = max(28, d.marginPt * 4.0 / 3.0)
        let size = d.defaultBodySize.map { "body{font-size:\(fmt($0))pt}" } ?? ""

        let css = #"""
        .paper{max-width:\#(fmt(paperWidth))px; padding:52px \#(fmt(padX))px 72px}
        \#(size)
        """#

        let bar = HTMLShell.topBar(title: name, mode: .doc, trailing: "")
        let body = """
<div class="paper-wrap"><div class="paper" id="root">\(d.html)</div></div>
"""
        return HTMLShell.page(.doc, body: body, extraCSS: css,
                              extraJS: HTMLShell.searchJS, topBar: bar)
    }

    // MARK: - Excel

    static func sheet(_ wb: any SheetSource, sheetIndex: Int, name: String) -> String {
        let r = wb.drawSheet(sheetIndex)
        let sheetName = wb.sheets[safe: sheetIndex]?.name ?? "Sheet"

        var notice = ""
        if r.truncated {
            notice = "<div class=\"note\">只显示前 \(r.rowCount > 4000 ? 4000 : r.rowCount) 行（共 \(r.rowCount) 行）。用上面的搜索框筛选可以快速定位。</div>"
        }

        let bar = HTMLShell.topBar(title: name, mode: .sheet, trailing: """
          <span class="chip" id="btnSort" title="按当前列排序">排序</span>
        """)

        let body = "<div class=\"grid-wrap\" id=\"root\">\(r.html)\(notice)</div>"

        let js = #"""
(function(){
  const grid = document.querySelector('.sht');
  if(!grid) return;
  let cur = null;
  let selCell = null;

  function cells(){ return Array.from(grid.querySelectorAll('tbody td[data-c]')); }

  /* --- 选中 --- */
  function select(td){
    if(selCell) selCell.classList.remove('sel');
    selCell = td;
    if(td) td.classList.add('sel');
  }

  /* --- 就地编辑 --- */
  function begin(td){
    if(cur) end(cur, true);
    cur = td;
    td.dataset.orig = td.textContent;
    td.contentEditable = 'true';
    td.classList.add('sel');
    td.focus();
    const r = document.createRange();
    r.selectNodeContents(td);
    const s = getSelection();
    s.removeAllRanges(); s.addRange(r);
  }

  function end(td, commit){
    if(!td) return;
    const v = td.textContent;
    td.contentEditable = 'false';
    if(td === cur) cur = null;
    if(!commit || v === td.dataset.orig){ td.textContent = td.dataset.orig || ''; return; }
    td.style.opacity = '.55';
    send({action:'editCell', r: parseInt(td.parentNode.dataset.row),
          c: parseInt(td.dataset.c), text: v});
  }

  cells().forEach(td=>{
    td.addEventListener('mousedown', ()=>select(td));
    td.addEventListener('dblclick', e=>{ e.preventDefault(); begin(td); });
    td.addEventListener('blur', ()=>{ if(td.isContentEditable) end(td, true); });
    td.addEventListener('keydown', e=>{
      if(e.key === 'Enter'){ e.preventDefault(); td.blur(); }
      if(e.key === 'Tab'){ e.preventDefault(); td.blur(); move(td, e.shiftKey ? -1 : 1); }
      if(e.key === 'Escape'){ td.textContent = td.dataset.orig || ''; td.blur(); }
    });
  });

  function move(td, dir){
    const list = cells();
    const i = list.indexOf(td);
    const nxt = list[i + dir];
    if(nxt){ select(nxt); nxt.scrollIntoView({block:'nearest', inline:'nearest'}); }
  }

  window.lyCellResult = function(ok, r, c, text){
    const td = grid.querySelector('tr[data-row="'+r+'"] td[data-c="'+c+'"]');
    if(!td) return;
    td.style.opacity = '';
    if(!ok){ td.textContent = td.dataset.orig || ''; td.style.background = '#FFE2DE'; }
    else { td.style.background = '#E3F7E5'; td.textContent = text; }
    setTimeout(()=>{ td.style.background = ''; }, 700);
  };

  /* --- 排序 --- */
  const btnSort = document.getElementById('btnSort');
  const hasMerge = !!grid.querySelector('td[rowspan],td[colspan]');
  if(btnSort){
    if(hasMerge){ btnSort.style.opacity = '.45'; btnSort.title = '含合并单元格，不支持排序'; }
    btnSort.addEventListener('click', ()=>{
      if(hasMerge) return;
      const anchor = selCell || grid.querySelector('tbody td[data-c]');
      if(!anchor) return;
      const col = anchor.dataset.c;
      const tbody = grid.querySelector('tbody');
      const rows = Array.from(tbody.querySelectorAll('tr'));
      const asc = btnSort.dataset.asc !== '1';
      btnSort.dataset.asc = asc ? '1' : '0';
      btnSort.textContent = asc ? '升序 ▲' : '降序 ▼';
      rows.sort((a,b)=>{
        const x = (a.querySelector('td[data-c="'+col+'"]')||{}).textContent || '';
        const y = (b.querySelector('td[data-c="'+col+'"]')||{}).textContent || '';
        const nx = parseFloat(x.replace(/[,\s%¥$]/g, ''));
        const ny = parseFloat(y.replace(/[,\s%¥$]/g, ''));
        const bothNum = !isNaN(nx) && !isNaN(ny);
        let r = bothNum ? (nx - ny) : x.localeCompare(y, 'zh-Hans-CN');
        return asc ? r : -r;
      });
      rows.forEach(r=>tbody.appendChild(r));
      renRowNumbers();
    });
  }

  /* 排序后行号要跟视觉顺序一致，否则左侧数字会看起来是乱的 */
  function renRowNumbers(){
    const tbody = grid.querySelector('tbody');
    let i = 0;
    tbody.querySelectorAll('tr').forEach(tr=>{
      i += parseInt(tr.dataset.spanRows || '1');
      if(!tr.dataset.spanRows){
        const rn = tr.querySelector('.rn');
        if(rn) rn.textContent = String(i);
      }
    });
  }

  /* --- 筛选：搜索框在表格模式里是「过滤行」而不是「全文高亮」 --- */
  const q = document.getElementById('q');
  if(q){
    const repl = q.cloneNode(true);
    q.parentNode.replaceChild(repl, q);
    let timer = null;
    repl.addEventListener('input', ()=>{
      clearTimeout(timer);
      timer = setTimeout(()=>filterRows(repl.value), 160);
    });
    repl.addEventListener('keydown', e=>{
      if(e.key === 'Escape'){ repl.value = ''; filterRows(''); repl.blur(); }
    });
  }

  function filterRows(v){
    const tbody = grid.querySelector('tbody');
    if(!tbody) return;
    const needle = (v || '').trim().toLowerCase();
    let shown = 0;
    tbody.querySelectorAll('tr').forEach(tr=>{
      if(!needle){ tr.classList.remove('hide'); shown++; return; }
      const hit = tr.textContent.toLowerCase().includes(needle);
      tr.classList.toggle('hide', !hit);
      if(hit) shown++;
    });
    const c = document.getElementById('hitCount');
    if(c) c.textContent = needle ? (shown + ' 行') : '';
  }

  /* 键盘上下左右移动选中的格子 */
  document.addEventListener('keydown', e=>{
    if(!selCell || document.activeElement === selCell) return;
    if(!['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)) return;
    e.preventDefault();
    const c = parseInt(selCell.dataset.c), r = parseInt(selCell.parentNode.dataset.row);
    const target = {ArrowUp:[r-1,c], ArrowDown:[r+1,c], ArrowLeft:[r,c-1], ArrowRight:[r,c+1]}[e.key];
    const td = grid.querySelector('tr[data-row="'+target[0]+'"] td[data-c="'+target[1]+'"]');
    if(td){ select(td); td.scrollIntoView({block:'nearest', inline:'nearest'}); }
  });
})();
"""#

        return HTMLShell.page(.sheet, body: body, extraJS: js, topBar: bar)
    }

    // MARK: - PowerPoint

    static func ppt(_ p: PptxDocument, name: String) -> String {
        pptShell(html: p.renderAll(), count: p.slidePaths.count, name: name)
    }

    /// 老式 .ppt / .dps：文本视图。二进制版把版式（自选图形坐标）放在另一套 Escher
    /// 记录里，这里只取每页的文字，按页居中排版 —— 内容对得上，版式不还原。
    static func legacyPpt(_ p: LegacyPpt, name: String) -> String {
        let w = p.slideWidthPt * 4.0 / 3.0
        let h = p.slideHeightPt * 4.0 / 3.0
        let base = max(15.0, h * 0.042)

        var html = ""
        for texts in p.slideTexts {
            html += "<div class=\"slide\" style=\"width:\(fmt(w))px;height:\(fmt(h))px\">"
            html += "<div class=\"sh\" style=\"left:6%;top:9%;width:88%;height:82%\">"
            html += "<div class=\"tx\" style=\"justify-content:center;text-align:center;padding:0 3%\">"
            if texts.isEmpty {
                html += "<p style=\"font-size:\(fmt(base))px;color:#9AA0A6\">（这一页没有文字）</p>"
            }
            for (j, t) in texts.enumerated() {
                let size = j == 0 ? base * 1.75 : base
                let weight = j == 0 ? "font-weight:700;" : ""
                let mt = j == 0 ? "" : "margin-top:\(fmt(base * 0.45))px;"
                html += "<p style=\"\(weight)\(mt)font-size:\(fmt(size))px;margin-bottom:0;text-align:center\">\(XMLText.escape(t))</p>"
            }
            html += "</div></div></div>"
        }
        return pptShell(html: html, count: p.slideTexts.count, name: name)
    }

    private static func pptShell(html: String, count: Int, name: String) -> String {
        let bar = HTMLShell.topBar(title: name, mode: .ppt, trailing: """
          <span class="chip" id="btnFit">适应宽度</span>
        """)

        let body = """
<div class="stage" id="root">\(html)</div>
<div class="pnum">
  <button id="pvPrev" title="上一页">‹</button>
  <input id="pvNum" value="1"><span>/ \(count)</span>
  <button id="pvNext" title="下一页">›</button>
</div>
"""

        let js = #"""
(function(){
  const slides = Array.from(document.querySelectorAll('.slide'));
  if(!slides.length) return;

  /* 记录逻辑尺寸，缩放时按它算比例 */
  slides.forEach(s=>{ s.dataset.w = s.offsetWidth; });

  function fit(){
    const avail = Math.min(window.innerWidth - 36, 1360);
    const w = parseFloat(slides[0].dataset.w) || 1280;
    let z = Math.min(1.5, avail / w);
    slides.forEach(s=>{ s.style.zoom = z; });
  }
  fit();
  window.addEventListener('resize', fit);

  const num = document.getElementById('pvNum');
  let cur = 1;

  function go(n){
    cur = Math.max(1, Math.min(slides.length, n));
    if(num) num.value = cur;
    slides[cur-1].scrollIntoView({block:'start', behavior:'smooth'});
  }
  /* 给原生侧边栏/菜单调用 */
  window.lyGo = go;
  window.lyStep = function(d){ go(cur + d); };
  function current(){
    const mid = window.innerHeight * 0.35;
    for(let i = 0; i < slides.length; i++){
      const r = slides[i].getBoundingClientRect();
      if(r.bottom > mid) return i + 1;
    }
    return slides.length;
  }

  document.getElementById('pvPrev').onclick = ()=>go(cur - 1);
  document.getElementById('pvNext').onclick = ()=>go(cur + 1);
  document.getElementById('btnFit') && (document.getElementById('btnFit').onclick = fit);
  if(num) num.addEventListener('change', ()=>go(parseInt(num.value) || 1));

  window.addEventListener('keydown', e=>{
    if(document.activeElement && document.activeElement.tagName === 'INPUT') return;
    if(['ArrowDown','PageDown','ArrowRight'].includes(e.key)){ e.preventDefault(); go(cur + 1); }
    if(['ArrowUp','PageUp','ArrowLeft'].includes(e.key)){ e.preventDefault(); go(cur - 1); }
    if(e.key === 'Home'){ e.preventDefault(); go(1); }
    if(e.key === 'End'){ e.preventDefault(); go(slides.length); }
  });
  window.addEventListener('scroll', ()=>{
    const c = current();
    if(num && document.activeElement !== num) num.value = c;
    cur = c;
  }, {passive:true});
})();
"""#

        return HTMLShell.page(.ppt, body: body, extraJS: js, topBar: bar)
    }
}
