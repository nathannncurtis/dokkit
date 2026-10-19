// Each file is taken from that library's README and the usage at the top of its source.
const GH = "https://github.com/nathannncurtis/dokkit/tree/main/clients/";
const LIBS = [
  { id: "python", name: "Python", file: "app.py", src: "dokkit.py", needs: "one file, standard library only", by: "pip",
    c: "#", k: "import|with|as|try|except|while|def|return", api: "dokkit\\.\\w+",
    install: [["cmd", "pip install path/to/dokkit/clients/python"]],
    logs: "<code>logging.getLogger().addHandler(dokkit.handler())</code> sends the <code>logging</code> module's records.",
    code: `# pip install path/to/dokkit/clients/python
import logging
import dokkit

dokkit.start(version="2.3.0")   # reads DOKKIT_URL and DOKKIT_KEY
logging.getLogger().addHandler(dokkit.handler())

dokkit.beat("worker")           # from the main loop

with dokkit.job("nightly-purge") as run:
    run.progress(4000, 9000)

try:
    upload()
except Exception:
    dokkit.capture()            # its type and stack, never its message` },
  { id: "dotnet", name: "C# and .NET", file: "Program.cs", src: "Dokkit/Dokkit.cs", needs: ".NET Standard 2.0, no packages", by: "dotnet add reference",
    c: "//", k: "using|var|try|catch|new", api: "Client\\.\\w+|AddDokkit|\\.Progress|\\.Done",
    install: [["cmd", "dotnet add reference path/to/dokkit/clients/dotnet/Dokkit/Dokkit.csproj"], ["cmd", "dotnet add reference path/to/dokkit/clients/dotnet/Dokkit.Logging/Dokkit.Logging.csproj"]],
    logs: "<code>builder.Logging.AddDokkit()</code> sends <code>Microsoft.Extensions.Logging</code>. It is in its own project, <code>Dokkit.Logging</code>, so the library itself needs no packages.",
    code: `// dotnet add reference path/to/dokkit/clients/dotnet/Dokkit/Dokkit.csproj
// dotnet add reference path/to/dokkit/clients/dotnet/Dokkit.Logging/Dokkit.Logging.csproj
using Dokkit;

Client.Start(version: "2.3.0");     // reads DOKKIT_URL and DOKKIT_KEY
var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddDokkit();        // from Dokkit.Logging

Client.Beat("worker");

using (var run = Client.Job("nightly-purge"))
{
    run.Progress(4000, 9000);
    run.Done();
}

try { Upload(); }
catch (Exception e) { Client.Capture(e); }` },
  { id: "javascript", name: "JavaScript", file: "app.js", src: "dokkit.js", needs: "Node 18 or later, and browsers, no packages", by: "npm",
    c: "//", k: "import|from|as|const|await|async|try|catch", api: "dokkit\\.\\w+|\\.progress",
    install: [["cmd", "npm install path/to/dokkit/clients/javascript"]],
    logs: "<code>dokkit.patchConsole()</code> sends <code>console</code> calls too, and returns a function that puts the console back. <code>dokkit.consoleLogger()</code> leaves the global one alone.",
    code: `// npm install path/to/dokkit/clients/javascript
import * as dokkit from "dokkit";

dokkit.start({ version: "2.3.0" });     // reads DOKKIT_URL and DOKKIT_KEY
const restore = dokkit.patchConsole();  // console.* also goes to the log

dokkit.beat("worker");

await dokkit.job("nightly-purge", async (run) => {
  run.progress(4000, 9000);
});

try {
  await upload();
} catch (error) {
  dokkit.capture(error);
}` },
  { id: "go", name: "Go", file: "main.go", src: "dokkit.go", needs: "one file, standard library only", by: "go mod edit",
    c: "//", k: "package|import|func|defer|if|return|nil|error", api: "dokkit\\.\\w+|\\.Progress",
    install: [["cmd", "go mod edit -require github.com/nathannncurtis/dokkit/clients/go@v0.0.0"], ["cmd", "go mod edit -replace github.com/nathannncurtis/dokkit/clients/go=path/to/dokkit/clients/go"]],
    logs: "<code>slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))</code> sends <code>log/slog</code> records.",
    code: `// go mod edit -require github.com/nathannncurtis/dokkit/clients/go@v0.0.0
// go mod edit -replace github.com/nathannncurtis/dokkit/clients/go=path/to/dokkit/clients/go
package main

import (
    "log/slog"

    dokkit "github.com/nathannncurtis/dokkit/clients/go"
)

func main() {
    dokkit.Start("2.3.0")             // reads DOKKIT_URL and DOKKIT_KEY
    defer dokkit.Flush()
    slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))

    dokkit.Beat("worker", 60)

    err := dokkit.Job("nightly-purge", func(run *dokkit.Run) error {
        run.Progress(4000, 9000)
        return nil
    })
    if err != nil {
        dokkit.Capture(err)
    }
}` },
  { id: "elixir", name: "Elixir", file: "app.exs", src: "lib/dokkit.ex", needs: "Elixir 1.18 or later, no packages", by: "mix.exs",
    c: "#", k: "fn|end|do|try|rescue", api: "Dokkit\\.\\w+|:logger\\.add_handler",
    install: [["file", "{:dokkit, path: \"path/to/dokkit/clients/elixir\"}", "In mix.exs"]],
    logs: "The <code>Dokkit</code> module is a <code>:logger</code> handler: <code>:logger.add_handler(:dokkit, Dokkit, %{level: :info})</code>.",
    code: `# mix.exs: {:dokkit, path: "path/to/dokkit/clients/elixir"}
Dokkit.start(version: "2.3.0", app: :my_app)   # reads DOKKIT_URL and DOKKIT_KEY
:logger.add_handler(:dokkit, Dokkit, %{level: :info})

Dokkit.beat("worker")

Dokkit.job("nightly-purge", fn progress ->
  progress.(4000, 9000)
end)

try do
  upload()
rescue
  error -> Dokkit.capture(error, __STACKTRACE__)
end` },
  { id: "rust", name: "Rust", file: "main.rs", src: "src/lib.rs", needs: "one file and one package, ureq", by: "Cargo.toml",
    c: "//", k: "fn|let|if|Ok|Err|Some|Result", api: "dokkit::\\w+|\\.progress",
    install: [["file", "dokkit = { path = \"path/to/dokkit/clients/rust\", features = [\"log\"] }", "In Cargo.toml"]],
    logs: "With the <code>log</code> feature, <code>log::set_logger(&amp;dokkit::Logger)</code> takes the <code>log</code> crate's records. The feature is off by default.",
    code: `// Cargo.toml: dokkit = { path = "path/to/dokkit/clients/rust", features = ["log"] }
fn main() {
    dokkit::start("2.3.0");                 // reads DOKKIT_URL and DOKKIT_KEY
    log::set_logger(&dokkit::Logger).unwrap();
    log::set_max_level(log::LevelFilter::Info);

    dokkit::beat("worker", 60);

    let done: Result<(), std::io::Error> = dokkit::job("nightly-purge", |run| {
        run.progress(4000, Some(9000));
        Ok(())
    });
    if let Err(error) = done {
        dokkit::capture(&error);
    }
    dokkit::flush();
}` },
  { id: "java", name: "Java", file: "App.java", src: "src/main/java/dev/dokkit/Dokkit.java", needs: "Java 11 or later, no dependencies", by: "mvn install",
    c: "//", k: "import|public|class|static|void|throws|try|catch|new", api: "Dokkit\\.\\w+|\\.progress",
    install: [["cmd", "mvn install", "In clients/java"], ["file", "dev.dokkit:dokkit:0.1.0", "Then depend on"]],
    logs: "<code>java.util.logging.Logger.getLogger(\"\").addHandler(Dokkit.handler())</code> sends <code>java.util.logging</code> records. Kotlin and Scala use it as it is.",
    code: `// mvn install in clients/java, then depend on dev.dokkit:dokkit:0.1.0
import dev.dokkit.Dokkit;
import java.util.logging.Logger;

public class App {
    public static void main(String[] args) throws Exception {
        Dokkit.start("2.3.0");             // reads DOKKIT_URL and DOKKIT_KEY
        Logger.getLogger("").addHandler(Dokkit.handler());

        Dokkit.beat("worker");

        Dokkit.job("nightly-purge", run -> {
            run.progress(4000, 9000);
        });

        try {
            upload();
        } catch (Exception e) {
            Dokkit.capture(e);
        }
    }
}` },
  { id: "php", name: "PHP", file: "worker.php", src: "Dokkit.php", needs: "PHP 8.0 or later, no packages or extensions", by: "composer",
    c: "//", k: "require|new|function|try|catch", api: "Dokkit::\\w+|DokkitLogger|->info",
    install: [["pre", `"repositories": [{ "type": "path", "url": "path/to/dokkit/clients/php" }],
"require": { "dokkit/dokkit": "*" }`, "In composer.json"]],
    logs: "<code>new DokkitLogger()</code> has the PSR-3 methods. It implements <code>Psr\\Log\\LoggerInterface</code> when <code>psr/log</code> is installed.",
    code: `<?php
// composer.json: a path repository at path/to/dokkit/clients/php, then "dokkit/dokkit": "*"
require 'vendor/autoload.php';

Dokkit::start('2.3.0');             // reads DOKKIT_URL and DOKKIT_KEY
$log = new DokkitLogger();          // PSR-3

Dokkit::beat('worker');

Dokkit::job('nightly-purge', function ($progress) {
    $progress(4000, 9000);
});

try {
    upload();
} catch (Throwable $e) {
    Dokkit::capture($e);
}
$log->info('purge finished');` },
  { id: "swift", name: "Swift", file: "App.swift", src: "Dokkit.swift", needs: "Foundation only, iOS 13 and macOS 10.15 or later", by: "Package.swift",
    c: "//", k: "import|try|do|catch|in", api: "Dokkit\\.\\w+|\\.progress",
    install: [["file", ".package(path: \"path/to/dokkit/clients/swift\")", "In Package.swift"]],
    logs: "No log handler. Swift's logging frameworks are packages, and the library takes none, so call <code>Dokkit.log</code>.",
    code: `// Package.swift: .package(path: "path/to/dokkit/clients/swift")
import Dokkit

Dokkit.start(version: "2.3.0")      // reads DOKKIT_URL and DOKKIT_KEY
Dokkit.beat("sync")

try Dokkit.job("nightly-purge") { run in
    run.progress(4000, of: 9000)
}

do {
    try upload()
} catch {
    Dokkit.capture(error)
}

// No log handler: swift-log is a package, and this takes none.
Dokkit.log("info", "sync finished")` },
  { id: "powershell", name: "PowerShell", file: "purge.ps1", src: "Dokkit.psm1", needs: "Windows PowerShell 5.1 and PowerShell 7", by: "Import-Module",
    c: "#", k: "try|catch", api: "[A-Z][a-z]+-Dokkit\\w*",
    install: [["cmd", "Import-Module path\\to\\dokkit\\clients\\powershell\\Dokkit.psd1"]],
    logs: "No log handler, since PowerShell has no logging framework. Call <code>Write-DokkitLog</code>.",
    code: `# Import-Module path\\to\\dokkit\\clients\\powershell\\Dokkit.psd1
Start-Dokkit -Version '2.3.0'       # reads DOKKIT_URL and DOKKIT_KEY
Send-DokkitBeat worker

Invoke-DokkitJob nightly-purge { Send-DokkitProgress 4000 9000 }

try {
    Invoke-Upload
} catch {
    Send-DokkitError $_
}

# No log handler: PowerShell has no logging framework.
Write-DokkitLog info 'purge finished'
Send-Dokkit` },
  { id: "shell", name: "Shell", file: "nightly.sh", src: "dokkit.sh", needs: "one file to source, needs only curl", by: "copy and source",
    c: "#", k: "", api: "dokkit_\\w+",
    install: [["cmd", ". path/to/dokkit.sh"]],
    logs: "No log handler, since shell has no logging framework. Call <code>dokkit_log</code>.",
    code: `#!/bin/sh
# copy dokkit.sh from clients/shell, then source it
. ./dokkit.sh                       # reads DOKKIT_URL and DOKKIT_KEY

dokkit_deploy 2.3.0
dokkit_beat worker

dokkit_job nightly-purge ./purge.sh

upload || dokkit_capture UploadError "Upload failed"

# No log handler: shell has no logging framework.
dokkit_log info "purge finished"` },
];

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
function paint(line, lib) {
  const re = new RegExp([`(${lib.c}.*$)`, `("(?:[^"\\\\]|\\\\.)*"|'(?:[^'\\\\]|\\\\.)*')`, `(${lib.api})`, lib.k ? `\\b(${lib.k})\\b` : "(?!)", "\\b(\\d+(?:\\.\\d+)?)\\b"].join("|"), "g");
  let out = "", last = 0;
  for (const m of line.matchAll(re)) {
    const kind = ["com", "str", "api", "kw", "num"][m.slice(1).findIndex((g) => g !== undefined)];
    out += esc(line.slice(last, m.index)) + `<span class="${kind}">${esc(m[0])}</span>`;
    last = m.index + m[0].length;
  }
  return out + esc(line.slice(last));
}

$("#tabs").innerHTML = LIBS.map((l, i) => `<button role="tab" id="tab-${l.id}" aria-controls="pane-${l.id}" aria-selected="${!i}" tabindex="${i ? -1 : 0}" data-lib="${i}">${l.file}</button>`).join("");
$("#tree").innerHTML = LIBS.map((l, i) => `<button type="button" data-lib="${i}"><span>${l.id}/</span><small>${l.src.split("/").pop()}</small></button>`).join("");
$("#panes").innerHTML = LIBS.map((l, i) => `<pre class="ide-code" role="tabpanel" id="pane-${l.id}" aria-labelledby="tab-${l.id}" tabindex="0"${i ? " hidden" : ""}>${l.code.split("\n").map((ln) => `<span class="l"><span class="t">${paint(ln, l) || " "}</span></span>`).join("")}</pre>`).join("");

let at = 0;
function show(i) {
  at = i;
  const l = LIBS[i];
  $$("#tabs [role=tab]").forEach((b, j) => { b.setAttribute("aria-selected", j === i); b.tabIndex = j === i ? 0 : -1; });
  $$("#tree button").forEach((b, j) => b.toggleAttribute("aria-current", j === i));
  $$("#panes pre").forEach((p, j) => (p.hidden = j !== i));
  const tab = $(`#tab-${l.id}`), strip = $("#tabs");
  strip.scrollLeft = tab.offsetLeft - (strip.clientWidth - tab.offsetWidth) / 2;
  $("#idePath").textContent = `my-app / ${l.file}`;
  $("#ideLang").textContent = `${l.name} · clients/${l.id}/${l.src}`;
  $("#ideNeeds").textContent = l.needs;
}

$("#libcards").innerHTML = LIBS.map((l) => `<details class="card"><summary>${l.name} <small>${l.by}</small></summary><div class="card-body">${l.install.map(([kind, text, label], j) => {
  const id = `in-${l.id}-${j}`;
  if (kind === "pre") return `<p class="lab">${label}</p><div class="prompt small"><pre id="${id}">${esc(text)}</pre><button type="button" class="copy small" data-copy="${id}">Copy</button></div>`;
  return `${label ? `<p class="lab">${label}</p>` : ""}<div class="cmd${kind === "file" ? " file" : ""}"><code id="${id}">${esc(text)}</code><button type="button" class="copy small" data-copy="${id}">Copy</button></div>`;
}).join("")}<p>${l.logs}</p><a class="gh" href="${GH}${l.id}">clients/${l.id} on GitHub</a></div></details>`).join("");

let tl = null;
function pick(i) {
  if (tl?.isActive()) tl.progress(1);
  show(i);
  if (tl) gsap.set($$(".t", $$("#panes pre")[i]), { clipPath: "inset(0 0% 0 0)" });
}
document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-lib]");
  if (b) pick(+b.dataset.lib);
});
$("#tabs").addEventListener("keydown", (e) => {
  const d = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
  if (!d) return;
  pick((at + d + LIBS.length) % LIBS.length);
  $$("#tabs [role=tab]")[at].focus();
});
show(0);

// Each file types in, one tab after another, while the scroll waits at the editor.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  tl = gsap.timeline({ paused: true });
  $$("#panes pre").forEach((p, i) => {
    tl.call(() => show(i))
      .fromTo($$(".t", p), { clipPath: "inset(0 100% 0 0)" }, { clipPath: "inset(0 0% 0 0)", duration: 0.06, stagger: 0.014, ease: "none" })
      .to({}, { duration: 0.1 });
  });
  // On a phone the sticky rail would cover the editor's top, so the section heading takes that place.
  holdFor(matchMedia("(max-width: 1000px)").matches ? "#editor" : "#ide", tl, "top 12%");
}

railFor($$(".step"), $$(".rail a"));
