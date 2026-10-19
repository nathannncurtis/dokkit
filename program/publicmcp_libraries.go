package main

type library struct {
	Language string `json:"language"`
	Install  string `json:"install"`
	Setup    string `json:"setup"`
	Start    string `json:"start"`
	Beat     string `json:"beat"`
	Job      string `json:"job"`
	Capture  string `json:"capture"`
	Logging  string `json:"logging"`
}

var libraries = []library{
	{
		Language: "python",
		Install:  "pip install \"git+https://github.com/nathannncurtis/dokkit#subdirectory=clients/python\" (one file, dokkit.py, standard library only; not on PyPI)",
		Setup:    "import dokkit\nReads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV. dokkit.start(version=\"2.3.0\", url=URL, key=KEY) uses what it is given and does not read the environment; blank means off.",
		Start:    `dokkit.start(version="2.3.0")   # sends a deploy line; announce_version=False leaves it out`,
		Beat:     `dokkit.beat("worker", every_seconds=60)   # from the main loop`,
		Job: `with dokkit.job("nightly-purge") as run:
    run.progress(4000, 9000)`,
		Capture: `try:
    ...
except Exception:
    dokkit.capture()   # inside the except block; or dokkit.capture(error)
dokkit.catch_unhandled()   # also reports what nothing caught`,
		Logging: `logging.getLogger().addHandler(dokkit.handler())   # or dokkit.log("info", "paid", {"order": 42})`,
	},
	{
		Language: "javascript",
		Install:  "From a clone of https://github.com/nathannncurtis/dokkit: npm install path/to/dokkit/clients/javascript (one file, dokkit.js, no packages, Node 18+ and browsers, ES module; types in dokkit.d.ts; not on npm yet)",
		Setup:    "import * as dokkit from \"dokkit\";\nReads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; start({ url, key, environment }) overrides them.",
		Start:    `dokkit.start({ version: "2.3.0" })   // sends a deploy line; announceVersion: false leaves it out`,
		Beat:     `dokkit.beat("worker", 60)   // from the main loop`,
		Job: `await dokkit.job("nightly-purge", async (run) => {
  run.progress(4000, 9000);
});`,
		Capture: `try { ... } catch (error) { dokkit.capture(error); }
dokkit.catchUnhandled();   // also reports what nothing caught`,
		Logging: `const restore = dokkit.patchConsole();   // console.log/info/debug/warn/error/trace also go through dokkit.log
// or: const logger = dokkit.consoleLogger();   // a wrapped console, the global one untouched
// or: dokkit.log("info", "paid", { order: 42 });`,
	},
	{
		Language: "dotnet",
		Install:  "From a clone of https://github.com/nathannncurtis/dokkit: dotnet add reference path/to/dokkit/clients/dotnet/Dokkit/Dokkit.csproj (one file, .NET Standard 2.0, no packages; not on NuGet yet). For logging also: dotnet add reference path/to/dokkit/clients/dotnet/Dokkit.Logging/Dokkit.Logging.csproj",
		Setup:    "using Dokkit;\nReads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; Client.Start(url: ..., key: ..., environment: ...) overrides them.",
		Start:    `Client.Start(version: "2.3.0");   // sends a deploy line; announceVersion: false leaves it out`,
		Beat:     `Client.Beat("worker", 60);   // from the main loop`,
		Job: `using (var run = Client.Job("nightly-purge"))
{
    run.Progress(4000, 9000);
    run.Done();   // disposing without Done() or Fail(ex) reports a failed run
}`,
		Capture: `try { ... } catch (Exception ex) { Client.Capture(ex); }
Client.CatchUnhandled();   // also reports what nothing caught`,
		Logging: `builder.Logging.AddDokkit();   // Microsoft.Extensions.Logging; needs Dokkit.Logging; AddDokkit(LogLevel.Warning) for a floor
// or: Client.Log("info", "paid");`,
	},
	{
		Language: "go",
		Install:  "go get github.com/nathannncurtis/dokkit/clients/go@main (one file, standard library only)",
		Setup:    "import \"github.com/nathannncurtis/dokkit/clients/go\" (package dokkit)\nReads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV. dokkit.StartWith(\"2.3.0\", addr, key) uses what it is given and does not read the environment.",
		Start:    `dokkit.Start("2.3.0")   // sends a deploy line; set dokkit.AnnounceVersion = false before Start to leave it out`,
		Beat:     `dokkit.Beat("worker", 60)   // from the main loop`,
		Job: `err := dokkit.Job("nightly-purge", func(run *dokkit.Run) error {
    run.Progress(4000, 9000)
    return nil
})`,
		Capture: `if err != nil { dokkit.Capture(err) }   // dokkit.CaptureTagged(err, map[string]string{"order": "42"}) adds tags
defer dokkit.Recover()   // reports a panic, then flushes
dokkit.Flush()   // before exit`,
		Logging: `slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))
// or: dokkit.Log("info", "paid", map[string]any{"order": 42})`,
	},
	{
		Language: "java",
		Install:  "From a clone of https://github.com/nathannncurtis/dokkit run mvn install in clients/java, then depend on dev.dokkit:dokkit:0.1.0 (one file, no dependencies, Java 11+; Kotlin and Scala use it as it is; not on Maven Central yet). In code: import dev.dokkit.Dokkit;",
		Setup:    "Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV. Dokkit.start(version, url, key) uses what it is given. Dokkit.own = \"com.billing\" names the app's package so only its frames count as the app's own.",
		Start:    `Dokkit.start("2.3.0");   // sends a deploy line; Dokkit.start("2.3.0", url, key, false) leaves it out`,
		Beat:     `Dokkit.beat("worker", 60);   // from the main loop; Dokkit.beat("worker") means 60`,
		Job: `Dokkit.job("nightly-purge", run -> {
    run.progress(4000, 9000);
});`,
		Capture: `try { ... } catch (Exception e) { Dokkit.capture(e); }
Dokkit.catchUnhandled();   // also reports what nothing caught`,
		Logging: `java.util.logging.Logger.getLogger("").addHandler(Dokkit.handler());
// or: Dokkit.log("info", "paid");`,
	},
	{
		Language: "elixir",
		Install:  `In mix.exs deps: {:dokkit, git: "https://github.com/nathannncurtis/dokkit", sparse: "clients/elixir"} (one file, no packages, Elixir 1.18+; not on Hex)`,
		Setup:    "Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; Dokkit.start(url: ..., key: ..., environment: ...) overrides them.",
		Start:    `Dokkit.start(version: "2.3.0", app: :billing_api)   # sends a deploy line; announce_version: false leaves it out`,
		Beat:     `Dokkit.beat("worker", 60)   # from the main loop`,
		Job:      `Dokkit.job("nightly-purge", fn progress -> progress.(4000, 9000) end)   # returns what the function returns`,
		Capture: `try do
  ...
rescue
  error -> Dokkit.capture(error, __STACKTRACE__)
end`,
		Logging: `:logger.add_handler(:dokkit, Dokkit, %{level: :info})
# or: Dokkit.log("info", "paid")`,
	},
	{
		Language: "php",
		Install:  `From a clone of https://github.com/nathannncurtis/dokkit, composer.json: "repositories": [{ "type": "path", "url": "path/to/dokkit/clients/php" }], "require": { "dokkit/dokkit": "*" } (one file, no packages or extensions, PHP 8.0+; not on Packagist yet). Without Composer: require 'Dokkit.php';`,
		Setup:    "Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; Dokkit::start($version, $url, $key, $announceVersion, $environment) overrides them.",
		Start:    `Dokkit::start('2.3.0');   // sends a deploy line from a command-line process; $announceVersion false leaves it out`,
		Beat:     `Dokkit::beat('worker', 60);   // from the main loop of a worker; call Dokkit::flush() from the loop too`,
		Job:      `Dokkit::job('nightly-purge', function ($progress) { $progress(4000, 9000); });`,
		Capture: `try { ... } catch (Throwable $e) { Dokkit::capture($e); }
Dokkit::catchUnhandled();   // also reports what nothing caught`,
		Logging: `$logger = new DokkitLogger();   // PSR-3 methods, e.g. $logger->error('Upload failed', ['order' => 42]); implements Psr\Log\LoggerInterface when psr/log is installed
// or: Dokkit::log('info', 'paid', ['order' => 42]);`,
	},
	{
		Language: "powershell",
		Install:  `From a clone of https://github.com/nathannncurtis/dokkit: Import-Module path\to\dokkit\clients\powershell\Dokkit.psd1 (one module, Windows PowerShell 5.1 and PowerShell 7; not on the PowerShell Gallery yet)`,
		Setup:    "Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; Start-Dokkit -Url ... -Key ... -Environment ... overrides them.",
		Start:    `Start-Dokkit -Version '2.3.0'   # queues a deploy line; -AnnounceVersion $false leaves it out`,
		Beat:     `Send-DokkitBeat worker -EverySeconds 60   # from the main loop`,
		Job:      `Invoke-DokkitJob nightly-purge { Send-DokkitProgress 4000 9000 }`,
		Capture: `try { ... } catch { Send-DokkitError $_ }
Send-Dokkit   # sends what is queued; also runs when a job ends`,
		Logging: `Write-DokkitLog info 'paid'   # no logging framework to hook; levels trace, debug, info, warn, error, fatal`,
	},
	{
		Language: "rust",
		Install:  `Cargo.toml: dokkit = { git = "https://github.com/nathannncurtis/dokkit" } (one file, one dependency: ureq; not on crates.io). For the log crate add features = ["log"].`,
		Setup:    `Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV. dokkit::start_with("2.3.0", url, key) uses what it is given; dokkit::environment("staging") and dokkit::announce_version(false) are called before start.`,
		Start:    `dokkit::start("2.3.0");   // sends a deploy line once per process`,
		Beat:     `dokkit::beat("worker", 60);   // from the main loop`,
		Job: `let done: Result<(), std::io::Error> = dokkit::job("nightly-purge", |run| {
    run.progress(4000, Some(9000));
    Ok(())
});`,
		Capture: `if let Err(error) = done { dokkit::capture(&error); }
dokkit::catch_unhandled();   // also reports panics
dokkit::flush();   // before exit`,
		Logging: `// with features = ["log"]:
log::set_logger(&dokkit::Logger).unwrap();
log::set_max_level(log::LevelFilter::Info);
// or: dokkit::log("info", "paid"); dokkit::log_fields("info", "paid", &[("order", 42.into())]);`,
	},
	{
		Language: "shell",
		Install:  "Copy clients/shell/dokkit.sh from a clone of https://github.com/nathannncurtis/dokkit next to the script and source it: . path/to/dokkit.sh (one file, needs only curl)",
		Setup:    "Reads DOKKIT_URL, DOKKIT_KEY and DOKKIT_ENV; blank url or key means off. DOKKIT_VERSION and DOKKIT_ANNOUNCE_VERSION=0 control the automatic deploy line.",
		Start:    `dokkit_deploy 2.3.0   # sends a deploy line now; with DOKKIT_VERSION set, the first report of a process sends one`,
		Beat:     `dokkit_beat worker 60`,
		Job:      `dokkit_job nightly-purge ./purge.sh   # runs the command, reports start and how it ended, returns its exit code`,
		Capture:  `dokkit_capture UploadError "Upload failed"   # sends the error type only; the message is not sent and there is no stack`,
		Logging:  `dokkit_log error "Upload failed"   # no logging framework to hook`,
	},
	{
		Language: "swift",
		Install:  `From a clone of https://github.com/nathannncurtis/dokkit, Package.swift dependencies: .package(path: "path/to/dokkit/clients/swift") (one file, Foundation only, iOS 13 and macOS 10.15+; not published yet). In code: import Dokkit`,
		Setup:    "Reads DOKKIT_URL and DOKKIT_KEY when url and key are not given; Dokkit.start(version:environment:url:key:) overrides them, and environment falls back to DOKKIT_ENV.",
		Start:    `Dokkit.start(version: "2.3.0", url: "https://dokkit.example", key: "dka_...")   // sends a deploy line; announceVersion: false leaves it out`,
		Beat:     `Dokkit.beat("sync", everySeconds: 60)   // from a timer`,
		Job:      `try Dokkit.job("nightly-purge") { run in run.progress(4000, of: 9000) }`,
		Capture: `do { try work() } catch { Dokkit.capture(error) }
Dokkit.flush()   // before the app exits`,
		Logging: `Dokkit.log("info", "paid")   // no log handler: Swift logging frameworks are packages and the library takes no dependency`,
	},
}

var languageAliases = map[string]string{
	"py": "python", "python3": "python",
	"js": "javascript", "node": "javascript", "nodejs": "javascript", "typescript": "javascript", "ts": "javascript", "deno": "javascript", "bun": "javascript",
	"c#": "dotnet", "csharp": "dotnet", ".net": "dotnet", "net": "dotnet", "f#": "dotnet", "fsharp": "dotnet", "vb": "dotnet", "aspnet": "dotnet",
	"golang": "go",
	"kotlin": "java", "scala": "java", "jvm": "java",
	"ex": "elixir", "phoenix": "elixir", "erlang": "elixir",
	"bash": "shell", "sh": "shell", "zsh": "shell", "curl": "shell",
	"pwsh": "powershell", "ps": "powershell", "ps1": "powershell",
	"rs":  "rust",
	"ios": "swift", "macos": "swift",
}
