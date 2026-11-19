<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root{--bg:#f7f7f8;--card:#fff;--fg:#1d1f23;--muted:#6a6f78;--line:#e3e4e8;--accent:#2f6feb;--warn:#a15c00}
@media (prefers-color-scheme:dark){:root{--bg:#16181d;--card:#1e2127;--fg:#e7e9ee;--muted:#9aa1ac;--line:#2e333b;--accent:#6a9bff;--warn:#d29922}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.7 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
header{max-width:860px;margin:0 auto;padding:28px 20px 8px}
h1{font-size:22px;margin:0 0 6px}
.sub{color:var(--muted);margin:0 0 10px}
.stats{font-size:13px;color:var(--muted);display:flex;gap:14px;flex-wrap:wrap}
main{max-width:860px;margin:0 auto;padding:12px 20px 40px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin:16px 0;break-inside:avoid}
.card h2{margin:0 0 10px;font-size:17px;word-break:break-all}
.card h2 a{color:var(--accent);text-decoration:none}
.tag{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:1px 8px;margin-left:6px;font-weight:400}
.overview{margin:0 0 14px;font-size:15px}
h3{font-size:14px;color:var(--muted);margin:16px 0 8px;letter-spacing:.04em}
details{border-top:1px dashed var(--line);padding:8px 0}
details summary{cursor:pointer;font-weight:600;font-size:14.5px}
details p{margin:8px 0 0}
.refs{margin:6px 0 0;font-size:12px;color:var(--muted)}
code{font-family:Consolas,monospace;background:var(--bg);padding:1px 5px;border-radius:4px;font-size:12px}
.meta{display:grid;grid-template-columns:92px 1fr;gap:6px 12px;margin:14px 0 0;font-size:13.5px}
.meta dt{color:var(--muted)}
.meta dd{margin:0}
.meta ul{margin:0;padding-left:18px}
.warn{color:var(--warn);font-size:13px}
.muted{color:var(--muted)}
footer{max-width:860px;margin:0 auto;padding:0 20px 40px;color:var(--muted);font-size:12.5px}
a{color:var(--accent)}
@media print{body{background:#fff;color:#000}.card{border-color:#bbb}details>summary{list-style:none}details>*{display:block!important}header,main,footer{max-width:none}}
</style>
</head>
<body>
<header>
  <h1>{{TITLE}}</h1>
  <p class="sub">{{SUBTITLE}}</p>
  <div class="stats">{{STATS}}</div>
</header>
<main>
{{CARDS}}
<section class="failed">{{FAILED}}</section>
</main>
<footer>{{FOOTER}}</footer>
</body>
</html>