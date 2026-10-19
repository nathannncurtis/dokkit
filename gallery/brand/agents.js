const PROMPT = `Wire this app into Dokkit. First read https://dokkit.dev/llms-full.txt, which describes Dokkit's dokkit.toml file, its command line and its libraries.

1. Run \`dokkit init\` in this repository and answer its questions for this app, or write dokkit.toml yourself from that reference.
2. Add the Dokkit library for this repository's language, and send a beat from the main loop.
3. Run \`dokkit check\` and show me what it would send.

Change nothing else, and do not commit.`;
const HOW = {
  claude: "Run claude in the app's repository and paste this.",
  cursor: "Open the repository in Cursor, start an Agent chat, and paste this.",
  codex: "Run codex in the app's repository and paste this.",
  copilot: "Open the repository in VS Code, switch Copilot Chat to agent mode, and paste this.",
};
function tool(t) {
  $$("[data-tool]").forEach((b) => b.setAttribute("aria-selected", b.dataset.tool === t));
  $("#how").textContent = HOW[t];
}
$("#prompt").textContent = PROMPT;
tool("claude");

// The tools each scope offers, as the server's MCP lists them.
const TOOLS = {
  read: ["attention", "find", "service", "jobs", "job_runs", "errors", "since_deploy", "machines", "machine", "issues", "issue", "deploys", "versions", "rules", "proposals", "series", "processes", "process_history", "day", "alert_settings", "alert_people", "alert_who", "alert_suggestions", "releases", "certificate", "downtime_schedules"],
  "read-logs": ["logs", "archives"],
  act: ["snooze", "acknowledge", "unsnooze", "note", "bulk", "watch", "unwatch", "routing", "machine_routing", "hold", "accept_proposal", "dismiss_proposal", "keep_messages", "set_job_timing", "scan_machine", "plan_downtime", "end_downtime", "schedule_downtime", "remove_scheduled_downtime"],
  admin: ["add_rule", "update_rule", "delete_rule", "set_checks", "allow_restart", "keys", "make_key", "revoke_key", "people", "add_person", "remove_person", "update_program", "set_certificate", "remove_certificate", "certificate_settings", "set_certificate_settings", "renew_certificate", "update_machine", "update_all", "add_app", "add_dependency", "add_job", "set_alert_settings", "test_alert", "set_alert_person", "set_alert_who", "accept_suggestion", "dismiss_suggestion", "restore_archive"],
};
const TOTAL = Object.values(TOOLS).flat().length;
function scopes() {
  const all = $("#scAll").checked;
  return { read: true, "read-logs": all || $("#scLogs").checked, act: all || $("#scAct").checked, admin: all };
}
function offer() {
  const on = scopes();
  let n = 0;
  $("#tools").innerHTML = Object.entries(TOOLS).map(([s, names]) => names.map((t) => { n += on[s]; return `<code class="${on[s] ? (s === "admin" ? "adm" : "") : "off"}">${t}</code>`; }).join("")).join("");
  $("#toolCount").textContent = `${n} of ${TOTAL}`;
  $("#toolSay").textContent = `This token is offered ${n} of ${TOTAL} tools. ` + (on.admin ? "It can do anything you can, keys and people included."
    : (on.act ? "It can act on issues and plan downtime. It cannot touch keys, people or rules." : "It cannot change anything.") + (on["read-logs"] ? "" : " Log contents are left out of every answer."));
}
let sure = false;
$("#tokenPanel").addEventListener("input", (e) => {
  const box = $("#scAll");
  if (e.target === box) {
    if (box.checked && !sure) { box.checked = false; $("#sure").hidden = false; return $("#sureText").focus(); }
    if (!box.checked) sure = false;
  }
  if (e.target.id === "sureText") return ($("#sureYes").disabled = e.target.value.trim() !== "dokkit.brightwater.example");
  offer(); ask(asked);
});
const shut = () => { $("#sure").hidden = true; $("#sureText").value = ""; $("#sureYes").disabled = true; };
$("#sureYes").onclick = () => { sure = true; $("#scAll").checked = true; shut(); offer(); ask(asked); };
$("#sureNo").onclick = shut;

const ASK = [
  () => [["call", "attention"], ["got", "3 need you · 2 soon · 4 not watched"],
    ["says", "Three things. nightly-purge did not run at 01:00 on db-01 (DOK-12), and that one paged you. The upload portal is answering slowly (DOK-09). The disk on nas is at 91% (DOK-13)."]],
  (on) => [["call", 'job_runs { id: "nightly-purge" }'], ["got", "last good run yesterday 01:00, 4 min · no start reported today"],
    ...(on["read-logs"]
      ? [["call", 'logs { service: "nightly-purge", level: "error" }'], ["got", "00:58 db-01 cron: cannot start purge.sh: /var/spool is over quota"],
         ["says", "It never started. At 00:58 cron on db-01 could not start it because /var/spool was over its quota. The run the night before was normal, so this is new."]]
      : [["says", "It never started: no start was reported after 01:00, and the run before it was normal. I cannot say why. This token is not offered the logs tool."],
         ["note", "Let the token read the logs, on the left, and it can."]])],
  () => [["call", 'since_deploy { id: "upload-portal" }'], ["got", "2.4.1 onto web-02 at 09:31 · 1 new error group · 1 issue opened"],
    ["says", "Version 2.4.1 went onto web-02 at 09:31. Nine minutes later the portal began answering slowly (DOK-09), and there is one new error group: TimeoutError in resize.py, 14 reports. Nothing else changed."]],
  (on) => on.act
    ? [["call", 'snooze { id: "DOK-13", until: "Monday 09:00" }'], ["got", "snoozed"], ["says", "Done. DOK-13 is snoozed until Monday 09:00. It closes by itself before then if the disk drops under 90%."]]
    : [["says", "I cannot. This token reads, and is not offered snooze."], ["note", "Let the token act, on the left, and ask again."]],
  (on) => on.admin
    ? [["call", 'add_rule { kind: "machine", machine: "db-01", state: "down", channel: "page" }'], ["got", "rule added, last in the list"], ["says", "Done. If db-01 goes down, you are paged. A service's own routing and earlier rules still win."]]
    : [["says", "I cannot. Rules decide who is told, and this token is not offered add_rule."], ["note", "Full control, on the left, makes you confirm first."]],
];
let asked = 0, turn = 0;
function ask(q) {
  asked = q;
  const mine = ++turn, talk = $("#talk");
  const lines = [["you", $(`.qs [data-q="${q}"]`).textContent], ...ASK[q](scopes())];
  talk.innerHTML = "";
  lines.forEach(([kind, text], i) => setTimeout(() => {
    if (mine !== turn) return;
    talk.querySelector(".wait")?.classList.remove("wait");
    const p = document.createElement("p");
    p.className = kind + (i < lines.length - 1 ? " wait" : "");
    p.textContent = (kind === "call" ? "→ " : "") + text;
    talk.append(p);
  }, still ? 0 : i * 600));
  return lines.length;
}
document.addEventListener("click", (e) => {
  const q = e.target.closest("[data-q]"), t = e.target.closest("[data-tool]");
  if (q) { $$(".qs button").forEach((b) => b.classList.toggle("on", b === q)); ask(+q.dataset.q); }
  if (t) tool(t.dataset.tool);
});
offer();

// The conversation plays once, and the page waits for it, when the token reaches the top.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  const tl = gsap.timeline({ paused: true });
  tl.call(() => ask(0)).to({}, { duration: ASK[0]().length * 0.6 + 0.9 });
  holdFor("#token", tl, "top 12%");
} else ask(0);

railFor($$(".step"), $$(".rail a"));
