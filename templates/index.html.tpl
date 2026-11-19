<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root{--bg:#f7f7f8;--card:#fff;--fg:#1d1f23;--muted:#6a6f78;--line:#e3e4e8;--accent:#2f6feb}
@media (prefers-color-scheme:dark){:root{--bg:#16181d;--card:#1e2127;--fg:#e7e9ee;--muted:#9aa1ac;--line:#2e333b;--accent:#6a9bff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.7 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
header{max-width:860px;margin:0 auto;padding:28px 20px 8px}
h1{font-size:22px;margin:0 0 6px}
.sub{color:var(--muted);margin:0}
main{max-width:860px;margin:0 auto;padding:16px 20px 40px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--line);font-size:14px}
th{color:var(--muted);font-weight:600;font-size:13px}
tr:last-child td{border-bottom:0}
td a{color:var(--accent);text-decoration:none}
.muted{color:var(--muted);font-size:12.5px}
footer{max-width:860px;margin:0 auto;padding:0 20px 40px;color:var(--muted);font-size:12.5px}
a{color:var(--accent)}
</style>
</head>
<body>
<header>
  <h1>{{TITLE}}</h1>
  <p class="sub">{{SUBTITLE}}</p>
</header>
<main>
<table>
<thead><tr><th>报告</th><th>项目</th><th>Q&amp;A</th><th>生成时间</th><th>状态</th></tr></thead>
<tbody>
{{ROWS}}
</tbody>
</table>
</main>
<footer>{{FOOTER}}</footer>
</body>
</html>