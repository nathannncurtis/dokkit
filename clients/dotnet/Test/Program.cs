// Runs the library against a small local server and exits 1 when something is wrong.
using System.IO.Compression;
using System.Net;
using System.Text;

var got = new List<(string Path, string Body)>();
var refused = false;
var hits = new List<string>();
var errorsDown = false;
var reportsDownOnce = false;
var listener = new HttpListener();
listener.Prefixes.Add("http://localhost:47912/");
listener.Start();
_ = Task.Run(() =>
{
    while (true)
    {
        var c = listener.GetContext();
        Stream body = c.Request.InputStream;
        if (c.Request.Headers["Content-Encoding"] == "gzip") body = new GZipStream(body, CompressionMode.Decompress);
        var text = new StreamReader(body, Encoding.UTF8).ReadToEnd();
        if (c.Request.Headers["Authorization"] != "Bearer dka_test") text = "BAD KEY";
        // The first report is refused once; the library has to send it again.
        var path = c.Request.Url!.AbsolutePath;
        var refuse = path == "/api/v1/report" && !refused;
        if (refuse) refused = true;
        if (path == "/api/v1/errors" && errorsDown) refuse = true;
        if (path == "/api/v1/report" && reportsDownOnce) { refuse = true; reportsDownOnce = false; }
        lock (got) hits.Add(path + (refuse ? " 503" : " 200"));
        lock (got) if (!refuse) foreach (var line in text.Split('\n')) got.Add((c.Request.Url!.AbsolutePath, line));
        c.Response.StatusCode = refuse ? 503 : 200;
        c.Response.Close();
    }
});

Dokkit.Client.Beat("ignored: not started");
Dokkit.Client.Start(version: "2.3.0", url: "http://localhost:47912", key: "dka_test");
Dokkit.Client.Beat("worker", 30);
Dokkit.Client.Check("queue-age", "degraded", 14, "oldest item is \"14\" minutes old");
using (var run = Dokkit.Client.Job("nightly-purge"))
{
    run.Progress(4000, 9000);
    try { throw new InvalidOperationException("patient 4411"); }
    catch (Exception e) { run.Fail(e); }
}
var shaky = new Exception("shaky");
using (var logs = Microsoft.Extensions.Logging.LoggerFactory.Create(b => Dokkit.DokkitLogging.AddDokkit(b, Microsoft.Extensions.Logging.LogLevel.Warning)))
{
    var log = logs.CreateLogger("app");
    Microsoft.Extensions.Logging.LoggerExtensions.LogInformation(log, "too quiet to send");
    Microsoft.Extensions.Logging.LoggerExtensions.LogWarning(log, "Disk at {Percent} percent", 91);
    // A formatter that throws must not reach the app, and the error is still sent.
    log.Log(Microsoft.Extensions.Logging.LogLevel.Error, default, 1, shaky, (Func<int, Exception?, string>)((s, e) => throw new InvalidOperationException()));
}
Dokkit.Client.Stats("{\n  \"stat\": 7\n}");
Dokkit.Client.Flush();
Dokkit.Client.Flush();

var flag = (AsyncLocal<bool>)typeof(Dokkit.Client).GetField("InSend", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.GetValue(null)!;
using (var fed = Microsoft.Extensions.Logging.LoggerFactory.Create(b => Dokkit.DokkitLogging.AddDokkit(b)))
{
    flag.Value = true;
    Microsoft.Extensions.Logging.LoggerExtensions.LogError(fed.CreateLogger("System.Net.Http.HttpClient"), new Exception("fed"), "from the sender");
    flag.Value = false;
}

errorsDown = true;
Dokkit.Client.Log("info", "line while errors are down");
Dokkit.Client.Capture(new ArgumentException("kept"));
Dokkit.Client.Flush();
var keptWhileDown = got.Any(g => g.Body.Contains("line while errors are down")) && !got.Any(g => g.Body.Contains("ArgumentException"));
errorsDown = false;
Dokkit.Client.Flush();

reportsDownOnce = true;
Dokkit.Client.Log("info", "line retried");
Dokkit.Client.Capture(new FormatException("independent"));
Dokkit.Client.Flush();
Dokkit.Client.Flush();
var independent = false;
lock (got) for (var i = 0; i + 1 < hits.Count; i++) if (hits[i] == "/api/v1/report 503" && hits[i + 1].StartsWith("/api/v1/errors")) independent = true;

Dokkit.Client.Log("info", new string('\u00e9', 50000));
Dokkit.Client.Log("info", new string('a', 70000));
Dokkit.Client.Flush();
var cut = got.Where(g => g.Body.Contains("\"msg\":\"")).Select(g => g.Body).Where(b => b.Contains(" [cut]\",")).ToList();
var cutOk = cut.Count == 2 && cut.All(b => Encoding.UTF8.GetByteCount(b) <= 65536);

var started = typeof(Dokkit.Client).GetField("http", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
Dokkit.Client.Start(version: "9.9.9", url: "http://localhost:47912", key: "dka_test");
Dokkit.Client.Flush();
var announcedOnce = !got.Any(g => g.Body.Contains("9.9.9"));
started.SetValue(null, null);
Dokkit.Client.Start(version: "8.8.8", url: "http://localhost:47912", key: "dka_test", announceVersion: false, environment: "dev");
Dokkit.Client.Beat("after quiet start");
Dokkit.Client.Log("info", "dev log");
using (var devRun = Dokkit.Client.Job("dev-job")) devRun.Done();
Dokkit.Client.Flush();
var quiet = got.Any(g => g.Body.Contains("after quiet start")) && !got.Any(g => g.Body.Contains("8.8.8"));
var devOk = new[] { "after quiet start", "dev log", "dev-job" }.All(w => got.Any(g => g.Body.Contains(w) && g.Body.Contains("\"environment\":\"dev\"")));
started.SetValue(null, null);
Dokkit.Client.Start(url: "http://localhost:47912", key: "dka_test", environment: "production");
Dokkit.Client.Beat("production beat");
Dokkit.Client.Flush();
var prodOk = got.Any(g => g.Body.Contains("production beat")) && !got.Any(g => g.Body.Contains("production beat") && g.Body.Contains("\"environment\""));

var safe = typeof(Dokkit.Client).GetMethod("Safe", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
bool Safe(string url) => (bool)safe.Invoke(null, new object[] { url })!;
var guarded = Safe("https://dokkit.example") && Safe("http://localhost:80") && !Safe("http://dokkit.example");

var droppedBefore = Dokkit.Client.Dropped;
var silent = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
silent.Start();
started.SetValue(null, null);
Dokkit.Client.Start(url: "http://127.0.0.1:" + ((System.Net.IPEndPoint)silent.LocalEndpoint).Port, key: "dka_test", announceVersion: false);
Dokkit.Client.Log("info", "to a server that never answers");
var exitWatch = System.Diagnostics.Stopwatch.StartNew();
typeof(Dokkit.Client).GetMethod("ExitFlush", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.Invoke(null, null);
var exitSeconds = exitWatch.Elapsed.TotalSeconds;

var isOwn = typeof(Dokkit.Client).GetMethod("IsOwn", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
bool Own(System.Reflection.Assembly a, string? p) => (bool)isOwn.Invoke(null, new object?[] { a, p })!;
var lib = typeof(Dokkit.Client).Assembly;
var owns = Own(lib, "Dokkit") && !Own(lib, "Orders") && !Own(typeof(object).Assembly, null) && !Own(lib, null)
    && Own(typeof(Enumerable).Assembly, null) == false && Own(System.Reflection.Assembly.GetExecutingAssembly(), null);

var all = string.Join("\n", got.Select(g => g.Path + " " + g.Body));
string[] want =
{
    "/api/v1/report {\"type\":\"deploy\"", "\"type\":\"beat\"", "\"every_seconds\":30", "\"state\":\"degraded\"",
    "oldest item is \\\"14\\\" minutes old", "\"event\":\"start\"", "\"event\":\"progress\"", "\"done\":4000",
    "\"event\":\"fail\"", "/api/v1/errors {", "\"type\":\"InvalidOperationException\"", "\"level\":\"warn\",\"msg\":\"Disk at 91 percent\"", "\"handled\":false", "\"own\":true", "\"type\":\"Exception\"",
};
var missing = want.Where(w => !all.Contains(w)).ToList();
if (!all.Contains("\"document\":{   \"stat\": 7 }")) missing.Add("stats on one line");
if (!owns) missing.Add("own frames");
if (!keptWhileDown) missing.Add("a line is sent while error posts fail, and the error is kept");
if (!got.Any(g => g.Path == "/api/v1/errors" && g.Body.Contains("ArgumentException"))) missing.Add("kept error sent later");
if (!got.Any(g => g.Body.Contains("FormatException")) || !got.Any(g => g.Body.Contains("line retried"))) missing.Add("failed batch retried");
if (!independent) missing.Add("a failed log batch does not skip error reports");
if (!cutOk) missing.Add("long lines cut under 64 KB with the marker, got " + cut.Count);
if (!announcedOnce) missing.Add("second Start announces nothing");
if (!quiet) missing.Add("announceVersion false sends no deploy line");
if (!devOk) missing.Add("dev environment on log, beat and job lines");
if (!prodOk) missing.Add("production adds no environment");
if (!guarded) missing.Add("http to another machine refused");
if (droppedBefore != 0) missing.Add("nothing dropped, got " + droppedBefore);
if (exitSeconds > 6) missing.Add("the exit flush waits at most 5 seconds, took " + exitSeconds);
if (missing.Count > 0 || all.Contains("4411") || all.Contains("BAD KEY") || all.Contains("ignored") || all.Contains("from the sender") || all.Contains("too quiet"))
{
    Console.WriteLine("FAIL\nmissing: " + string.Join(" | ", missing) + "\n" + all);
    return 1;
}
Console.WriteLine("ok: " + got.Count + " lines");
return 0;
