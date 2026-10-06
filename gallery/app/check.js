// node check.js: renders every route against a stub DOM; fails on a throw or on "undefined" in the output.
var fs = require("fs"), vm = require("vm"), path = require("path");
var els = {};
var ctx = {
  location: { hash: "" },
  document: { documentElement: { className: "" }, getElementById: function (id) { return els[id] || (els[id] = { innerHTML: "" }); } },
  window: { addEventListener: function () {}, scrollTo: function () {} }, localStorage: { setItem: function () {}, getItem: function () { return null; } }, console: console
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, "../demo/data.js"), "utf8"), ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, "app.js"), "utf8"), ctx);
var routes = ["", "#/inbox", "#/all", "#/jobs", "#/logs", "#/errors", "#/alerts", "#/settings"], n = 0;
vm.runInContext("MACHINES", ctx).forEach(function (m) { routes.push("#/m/" + m.id); m.services.forEach(function (s) { routes.push("#/s/" + m.id + "/" + s.id); }); });
function show(r) {
  ctx.location.hash = r; vm.runInContext("render()", ctx);
  var html = els.side.innerHTML + els.page.innerHTML;
  var bad = html.match(/.{30}(undefined|NaN|\[object).{30}/);
  if (bad) throw new Error("bad output on " + r + ": " + bad[0]);
  if (/—|–|·/.test(html)) throw new Error("banned dash or dot on " + r);
  n++; return html;
}
routes.forEach(show);
["soon", "found", "now"].forEach(function (t) { vm.runInContext("setTab('" + t + "')", ctx); show("#/inbox"); });
[0, 1, 2].forEach(function (i) { vm.runInContext("snooze(" + i + ")", ctx); });
if (show("#/inbox").indexOf("Nothing needs you") < 0) throw new Error("snooze did not empty the inbox");
vm.runInContext("watch('idrive')", ctx);
if (show("#/s/nas-01/idrive").indexOf("Add a check") >= 0) throw new Error("watch did not take");
vm.runInContext("setTheme('dark')", ctx);
if (!/\bt-dark\b/.test(ctx.document.documentElement.className)) throw new Error("theme did not switch");
vm.runInContext("setLook('base', 'plum'); setLook('accent', 'orange')", ctx);
if (ctx.document.documentElement.className !== "t-dark d-plum a-orange") throw new Error("look classes wrong: " + ctx.document.documentElement.className);
if (show("#/inbox").indexOf("viewBox=\"0 0 100 100\"") < 0) throw new Error("logo missing from the sidebar");
console.log("ok: " + n + " renders across " + routes.length + " routes, actions pass");
