# 项目申报书附件

`PROPOSAL.md`（仓库根目录）是唯一内容源，生成两份等价的 A4 一页文件：

| 文件 | 用途 | 大小 |
| --- | --- | --- |
| `PROPOSAL.pdf` | 报名表收 PDF 时上传 | ~233 KB |
| `PROPOSAL.docx` | 报名表收 Word 时上传（Word 里打开仍是一页） | ~40 KB |

两份文件的章节和文字完全一致，按报名表里「项目申报书样本」的 8 点提纲组织：
1 项目名称 → 2 项目简介 → 3 项目方向与通用性 → 4 预期使用场景（≥3 个）→
5 拟实现的核心功能 → 6 原创性 → 7 移植或参考说明 → 8 GitHub 仓库链接。
样本原文：<https://bxup9uklfcb.feishu.cn/wiki/Rm3PwCxC7iEwJtkK1xMcYHZkn36>
（要求 markdown、一页以内）。联系方式写「见报名表」，邮箱和手机不进公开仓库。

## 生成 PDF

```bash
pandoc PROPOSAL.md --from=gfm --to=html5 --standalone \
  --css=proposal.css -o submission/PROPOSAL.html

html="$(cygpath -m "$PWD/submission/PROPOSAL.html")"
pdf="$(cygpath -m "$PWD/submission/PROPOSAL.pdf")"

"/c/Program Files/Google/Chrome/Application/chrome.exe" \
  --headless=new --disable-gpu --no-sandbox \
  --user-data-dir=/tmp/chrome-pdf-profile \
  --no-pdf-header-footer \
  --print-to-pdf="$pdf" "file:///$html"
```

`PROPOSAL.html` 是中间产物，不纳入版本控制；`proposal.css` 控制一页版式。

## 生成 DOCX

```bash
python submission/build_docx.py
```

`build_docx.py` 逐行读 `PROPOSAL.md`：`# ` 是标题（17pt），`## ` 是二级标题（11.5pt，带下划线），
`- ` 是悬挂缩进的条目，反引号片段用 Consolas。页面 A4、上下 9 mm / 左右 14 mm、正文 9pt
微软雅黑，目标是**一页**。

## 确认页数

PDF：

```bash
node -e "const s=require('fs').readFileSync('submission/PROPOSAL.pdf').toString('latin1');console.log((s.match(/\/Type\s*\/Page\b(?!s)/g)||[]).length,'page(s)')"
```

DOCX（用本机 Word 导出 PDF 并读页数，打印 `1` 即合格）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File submission/docx_pages.ps1 \
  -Docx "$(cygpath -w "$PWD/submission/PROPOSAL.docx")" \
  -Pdf "$(cygpath -w /tmp/proposal-check.pdf)"
```

改完版式或正文后，两份都要重新生成并各自确认页数为 `1`。
