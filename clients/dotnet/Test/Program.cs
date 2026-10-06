// Runs the library against a small local server and exits 1 when something is wrong.
using System.IO.Compression;
using System.Net;
using System.Text;

var got = new List<(string Path, string Body)>();
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
        lock (got) foreach (var line in text.Split('\n')) got.Add((c.Request.Url!.AbsolutePath, line));
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
Dokkit.Client.Flush();

var all = string.Join("\n", got.Select(g => g.Path + " " + g.Body));
string[] want =
{
    "/api/v1/report {\"type\":\"deploy\"", "\"type\":\"beat\"", "\"every_seconds\":30", "\"state\":\"degraded\"",
    "oldest item is \\\"14\\\" minutes old", "\"event\":\"start\"", "\"event\":\"progress\"", "\"done\":4000",
    "\"event\":\"fail\"", "/api/v1/errors {", "\"type\":\"InvalidOperationException\"", "\"level\":\"warn\",\"msg\":\"Disk at 91 percent\"", "\"handled\":false", "\"own\":true",
};
var missing = want.Where(w => !all.Contains(w)).ToList();
if (missing.Count > 0 || all.Contains("4411") || all.Contains("BAD KEY") || all.Contains("ignored") || all.Contains("too quiet"))
{
    Console.WriteLine("FAIL\nmissing: " + string.Join(" | ", missing) + "\n" + all);
    return 1;
}
Console.WriteLine("ok: " + got.Count + " lines");
return 0;
