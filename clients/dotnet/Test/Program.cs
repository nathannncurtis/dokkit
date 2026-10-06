// Runs the library against a small local server and exits 1 when something is wrong.
using System.IO.Compression;
using System.Net;
using System.Text;

var got = new List<(string Path, string Body)>();
var refused = false;
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
        var refuse = c.Request.Url!.AbsolutePath == "/api/v1/report" && !refused;
        if (refuse) refused = true;
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
using (var logs = Microsoft.Extensions.Logging.LoggerFactory.Create(b => Dokkit.DokkitLogging.AddDokkit(b, Microsoft.Extensions.Logging.LogLevel.Warning)))
{
    var log = logs.CreateLogger("app");
    Microsoft.Extensions.Logging.LoggerExtensions.LogInformation(log, "too quiet to send");
    Microsoft.Extensions.Logging.LoggerExtensions.LogWarning(log, "Disk at {Percent} percent", 91);
}
Dokkit.Client.Stats("{\n  \"stat\": 7\n}");
Dokkit.Client.Flush();
Dokkit.Client.Flush();

var safe = typeof(Dokkit.Client).GetMethod("Safe", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
bool Safe(string url) => (bool)safe.Invoke(null, new object[] { url })!;
var guarded = Safe("https://dokkit.example") && Safe("http://localhost:80") && !Safe("http://dokkit.example");

var all = string.Join("\n", got.Select(g => g.Path + " " + g.Body));
string[] want =
{
    "/api/v1/report {\"type\":\"deploy\"", "\"type\":\"beat\"", "\"every_seconds\":30", "\"state\":\"degraded\"",
    "oldest item is \\\"14\\\" minutes old", "\"event\":\"start\"", "\"event\":\"progress\"", "\"done\":4000",
    "\"event\":\"fail\"", "/api/v1/errors {", "\"type\":\"InvalidOperationException\"", "\"level\":\"warn\",\"msg\":\"Disk at 91 percent\"", "\"handled\":false", "\"own\":true",
};
var missing = want.Where(w => !all.Contains(w)).ToList();
if (!all.Contains("\"document\":{   \"stat\": 7 }")) missing.Add("stats on one line");
if (!guarded) missing.Add("http to another machine refused");
if (Dokkit.Client.Dropped != 0) missing.Add("nothing dropped, got " + Dokkit.Client.Dropped);
if (missing.Count > 0 || all.Contains("4411") || all.Contains("BAD KEY") || all.Contains("ignored") || all.Contains("too quiet"))
{
    Console.WriteLine("FAIL\nmissing: " + string.Join(" | ", missing) + "\n" + all);
    return 1;
}
Console.WriteLine("ok: " + got.Count + " lines");
return 0;
