#!/usr/bin/env python3
# 造一份"像真的"的 docx 测试文件：多级标题、混排格式、列表、合并表格、图片
import os, zipfile
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

OUT = os.path.expanduser("~/Desktop/轻阅测试.docx")

doc = Document()

# 中文默认字体
style = doc.styles['Normal']
style.font.name = 'PingFang SC'
style.font.size = Pt(10.5)
style.element.rPr.rFonts.set(qn('w:eastAsia'), 'PingFang SC')

def h(text, level):
    return doc.add_heading(text, level=level)

h('轻阅 查看器验收用例', 1)
p = doc.add_paragraph('这份文件用来验证段落、样式、列表、表格、图片能不能正确还原。')
p.alignment = WD_ALIGN_PARAGRAPH.CENTER

h('一、字符样式', 2)
p = doc.add_paragraph()
p.add_run('普通文字 ')
r = p.add_run('加粗'); r.bold = True
p.add_run('，')
r = p.add_run('斜体'); r.italic = True
p.add_run('，')
r = p.add_run('下划线'); r.underline = True
p.add_run('，')
r = p.add_run('红色'); r.font.color.rgb = RGBColor(0xC4, 0x28, 0x19)
p.add_run('，')
r = p.add_run('大字号'); r.font.size = Pt(15)
p.add_run('。')

p = doc.add_paragraph()
r = p.add_run('高亮背景')
hl = OxmlElement('w:highlight'); hl.set(qn('w:val'), 'yellow')
r._element.get_or_add_rPr().append(hl)
p.add_run('这个应该有一块黄底。')

h('二、列表', 2)
doc.add_paragraph('第一项：项目符号应为圆点', style='List Bullet')
doc.add_paragraph('第二项：缩进要对齐', style='List Bullet')
doc.add_paragraph('第三项：如果一行很长，第二行要悬挂缩进而不是顶到最左边，这一点很多阅读器做不好', style='List Bullet')
doc.add_paragraph('第一步：编号列表', style='List Number')
doc.add_paragraph('第二步：编号应递增', style='List Number')
doc.add_paragraph('第三步：而不是全部显示 1.', style='List Number')

h('三、表格', 2)
t = doc.add_table(rows=4, cols=4)
t.style = 'Table Grid'
t.alignment = WD_TABLE_ALIGNMENT.CENTER
data = [
    ['项目', '数量', '单价', '小计'],
    ['键盘', '2', '199.00', '398.00'],
    ['显示器', '1', '1299.00', '1299.00'],
    ['合计', '', '', '1697.00'],
]
for i, row in enumerate(data):
    for j, v in enumerate(row):
        cell = t.cell(i, j)
        cell.text = ''
        run = cell.paragraphs[0].add_run(v)
        if i == 0:
            run.bold = True
        if j >= 1:
            cell.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.RIGHT

# 合并：合计那一行后三列
t.cell(3, 1).merge(t.cell(3, 2))

h('四、图片', 2)
doc.add_paragraph('下面这张图应该居中完整显示，不被裁切：')
# 造一张纯色 PNG
try:
    import struct, zlib
    def png(w, h, rgb):
        raw = b''
        for y in range(h):
            raw += b'\x00' + bytes(rgb) * w
        def chunk(tag, data):
            c = tag + data
            return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
                chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
    path = '/tmp/ly-test.png'
    open(path, 'wb').write(png(360, 120, (196, 40, 25)))
    doc.add_picture(path, width=Inches(2.6))
    doc.paragraphs[-1].alignment = WD_ALIGN_PARAGRAPH.CENTER
except Exception as e:
    print('图片跳过:', e)

h('五、长段落（测行距与换行）', 2)
doc.add_paragraph(
    '这是一段故意写得很长的话，用来检查行距、字距、段间距是否正常，以及中文换行会不会'
    '在奇怪的地方断开。正常的表现是：左右两端基本对齐，行与行之间不挤也不散，标点不会'
    '跑到行首。如果这一段的最后一行只有两三个字，也属正常，不必强求。'
)
doc.add_paragraph('第二段用来确认段与段之间有空隙，而不是粘成一大坨。')

h('六、页脚边界情况', 2)
doc.add_paragraph('这一行后面是空白段落。')
doc.add_paragraph('')
doc.add_paragraph('')
doc.add_paragraph('前面空了五段，下面这行应该还在原位，不会被压缩掉。')

doc.save(OUT)
print('✓', OUT, os.path.getsize(OUT), 'bytes')
