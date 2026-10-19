const tools = $$(".tool"), count = $("#toolCount");
$("#findTool").addEventListener("input", (ev) => {
  const q = ev.target.value.trim().toLowerCase();
  let n = 0;
  tools.forEach((t) => { const hit = !q || t.dataset.tool.includes(q); t.hidden = !hit; n += hit; });
  $$(".scope-sec").forEach((s) => (s.hidden = !$$(".tool", s).some((t) => !t.hidden)));
  count.textContent = q ? `${n} of ${tools.length} tools` : `${tools.length} tools`;
  window.ScrollTrigger?.refresh();
});
