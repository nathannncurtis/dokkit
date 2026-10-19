// The two reference pages are drawn from files: cli.json is the program's own help, openapi.json is spec/openapi.json.
const $ = (q) => document.querySelector(q);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const prose = (s) => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");
const pretty = (o) => esc(typeof o === "string" ? o : JSON.stringify(o, null, 2));

if ($("#cli")) fetch("cli.json").then((r) => r.json()).then((d) => {
  $("#help").textContent = "$ dokkit help\n" + d.help;
  $("#checkOut").textContent = "$ dokkit check\n" + d.check;
  $("#toc").innerHTML = d.groups.map((g) => `<b>${esc(g.name)}</b>` + g.commands.map((c, i) => `<a href="#${c.name}-${i}">${esc(c.synopsis.split(" ").slice(0, ["task", "folder"].includes(c.name) ? 3 : 2).join(" "))}</a>`).join("")).join("");
  $("#cli").innerHTML = d.groups.map((g) => `<h2>${esc(g.name)}</h2>` + g.commands.map((c, i) =>
    `<details class="op" id="${c.name}-${i}" data-find="${esc((c.synopsis + " " + c.short).toLowerCase())}"><summary><h3>${esc(c.synopsis)}</h3><p class="sum">${esc(c.short)}</p></summary><div class="op-body"><p>${esc(c.more)}</p></div></details>`).join("")).join("");
  ready();
});

if ($("#api")) fetch("openapi.json").then((r) => r.json()).then((d) => {
  const ref = (o) => (o && o.$ref ? o.$ref.split("/").slice(1).reduce((a, k) => a[k], d) : o);
  const body = (c) => { const j = Object.values(c?.content || {})[0]; return j && (j.example ?? Object.values(j.examples || {})[0]?.value); };
  const ops = [];
  for (const [path, item] of Object.entries(d.paths))
    for (const verb of ["get", "post", "put", "patch", "delete"]) if (item[verb]) ops.push({ path, verb, ...item[verb] });
  const tags = d.tags.map((t) => ({ ...t, ops: ops.filter((o) => o.tags?.[0] === t.name) })).filter((t) => t.ops.length);
  $("#toc").innerHTML = tags.map((t) => `<b>${esc(t.name)}</b>` + t.ops.map((o) => `<a href="#${o.operationId}" title="${esc(o.path)}">${o.verb.toUpperCase()} ${esc(o.path.replace("/api/v1", ""))}</a>`).join("")).join("");
  $("#count").textContent = `${ops.length} calls, version ${d.info.version}.`;
  $("#api").innerHTML = tags.map((t) => `<h2 id="tag-${esc(t.name)}">${esc(t.name)}</h2><p>${prose(t.description)}</p>` + t.ops.map((o) => {
    const params = (o.parameters || []).map(ref);
    const sent = body(ref(o.requestBody));
    const curl = `curl ${o.verb === "get" ? "" : "-X " + o.verb.toUpperCase() + " "}-H "Authorization: Bearer $DOKKIT_KEY" '${d.servers[0].url}${o.path}'${sent ? " -d '" + (typeof sent === "string" ? sent : JSON.stringify(sent)) + "'" : ""}`;
    const answers = Object.entries(o.responses || {}).map(([code, r]) => [code, ref(r)]);
    const good = answers.find(([code]) => code[0] === "2");
    return `<details class="op" id="${o.operationId}" data-find="${esc((o.verb + " " + o.path + " " + o.summary).toLowerCase())}">
      <summary><h3><span class="verb ${o.verb}">${o.verb.toUpperCase()}</span>${esc(o.path)}</h3>
      <p class="sum">${prose(o.summary)}</p></summary><div class="op-body"><p>${prose(o.description)}</p>
      ${params.length ? `<table><thead><tr><th>Takes</th><th>In</th><th></th></tr></thead><tbody>${params.map((p) => `<tr><td><code>${esc(p.name)}</code>${p.required ? "" : " (optional)"}</td><td>${esc(p.in)}</td><td>${prose(p.description)}</td></tr>`).join("")}</tbody></table>` : ""}
      <h4>Ask</h4><pre>${esc(curl)}</pre>
      ${good && body(good[1]) !== undefined ? `<h4>Answer, ${good[0]}</h4><pre>${pretty(body(good[1]))}</pre>` : ""}
      <table><tbody>${answers.map(([code, r]) => `<tr><td><code>${code}</code></td><td>${prose(r.description)}</td></tr>`).join("")}</tbody></table>
    </div></details>`;
  }).join("")).join("");
  ready();
});

// Everything starts folded; the sidebar, a link or the search box opens what you are after.
function ready() {
  const ops = [...document.querySelectorAll("details.op")], find = $("#find"), count = $("#findCount");
  const open = (id) => { const el = document.getElementById(id); if (el?.matches("details")) { el.open = true; el.scrollIntoView({ block: "start" }); } };
  if (location.hash) open(location.hash.slice(1));
  addEventListener("hashchange", () => open(location.hash.slice(1)));
  $("#foldAll")?.addEventListener("click", (e) => {
    const shut = ops.some((o) => o.open);
    ops.forEach((o) => (o.open = !shut && !o.hidden));
    e.target.textContent = shut ? "Open all" : "Close all";
  });
  find?.addEventListener("input", () => {
    const q = find.value.trim().toLowerCase();
    let n = 0;
    ops.forEach((o) => { const hit = !q || o.dataset.find.includes(q); o.hidden = !hit; n += hit; });
    document.querySelectorAll("#api > h2, #api > h2 + p, #cli > h2").forEach((h) => {
      let el = h.nextElementSibling, any = false;
      while (el && el.tagName !== "H2") { if (el.matches("details.op") && !el.hidden) any = true; el = el.nextElementSibling; }
      h.hidden = !any;
    });
    count.textContent = q ? `${n} of ${ops.length}` : `${ops.length}`;
  });
  if (count) count.textContent = `${ops.length}`;
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-copy]");
  if (!t) return;
  const el = $("#" + t.dataset.copy), label = t.textContent;
  // The clipboard needs https; on plain http the link is selected instead.
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(el.textContent).then(() => (t.textContent = "Copied"));
  else { getSelection().selectAllChildren(el); t.textContent = "Selected"; }
  setTimeout(() => (t.textContent = label), 1400);
});
