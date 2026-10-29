# 项目申报书附件

`PROPOSAL.pdf` 由仓库根目录的 `PROPOSAL.md` 生成，A4 一页，直接上传到报名表的「项目申报书」附件字段。

重新生成（Git Bash）：

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
改完版式后确认页数：

```bash
node -e "const s=require('fs').readFileSync('submission/PROPOSAL.pdf').toString('latin1');console.log((s.match(/\/Type\s*\/Page\b(?!s)/g)||[]).length,'page(s)')"
```
