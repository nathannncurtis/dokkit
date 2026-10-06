// The Dokkit client library for .NET. One file, no packages.
//
//     Dokkit.Client.Start(version: "2.3.0");   // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     Dokkit.Client.Beat("worker");            // from the main loop
//     using (var run = Dokkit.Client.Job("nightly-purge")) { run.Progress(4000, 9000); run.Done(); }
//     Dokkit.Client.Check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
//     Dokkit.Client.Capture(exception);
//
// Nothing here throws into the app or waits on the network. Lines wait in a queue of fixed
// size and a background thread sends them. Error message text is never sent. An http:// address
// to another machine keeps the library off unless DOKKIT_INSECURE=1.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Threading;

namespace Dokkit
{
    public static class Client
    {
        const int QueueSize = 1000, QueueBytes = 4 << 20;
        static readonly object Sending = new object();
        static int lineBytes;
        static Batch retry;
        static readonly object Gate = new object();
        static readonly Queue<string> Lines = new Queue<string>();
        static readonly Queue<Dictionary<string, object>> Errors = new Queue<Dictionary<string, object>>();
        static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        static HttpClient http;
        static string url, version, environment, host;

        /// <summary>How many lines were dropped because the queue was full or could not be sent.</summary>
        public static int Dropped { get; private set; }

        /// <summary>Turns the library on. With no address or key it stays off and every call does nothing.</summary>
        public static void Start(string version = null, string environment = null, string url = null, string key = null)
        {
            try
            {
                url = url ?? Environment.GetEnvironmentVariable("DOKKIT_URL");
                key = key ?? Environment.GetEnvironmentVariable("DOKKIT_KEY");
                if (string.IsNullOrEmpty(url) || string.IsNullOrEmpty(key) || http != null) return;
                if (!Safe(url))
                {
                    Console.Error.WriteLine("dokkit: " + url + " is not https and not this machine; staying off. Set DOKKIT_INSECURE=1 to allow it.");
                    return;
                }
                Client.url = url.TrimEnd('/');
                Client.version = version;
                Client.environment = environment ?? Environment.GetEnvironmentVariable("DOKKIT_ENV");
                host = Environment.MachineName;
                var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer " + key);
                http = client;
                new Thread(Run) { IsBackground = true, Name = "dokkit" }.Start();
                AppDomain.CurrentDomain.ProcessExit += (s, e) => Flush();
                if (version != null) Add(Line("deploy", "version", version));
            }
            catch { http = null; }
        }

        static bool Safe(string url) =>
            !url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || Environment.GetEnvironmentVariable("DOKKIT_INSECURE") == "1"
            || (Uri.TryCreate(url, UriKind.Absolute, out var uri) && (uri.IsLoopback || uri.Host == "localhost"));

        public static void Beat(string name, int everySeconds = 60) =>
            Add(Line("beat", "name", name, "every_seconds", everySeconds));

        /// <summary>state is "ok", "degraded" or "down".</summary>
        public static void Check(string name, string state, double? value = null, string note = null) =>
            Add(Line("custom", "check", name, "state", state, "value", value, "note", note));

        public static void Metric(string name, double value, string unit = null) =>
            Add(Line("metric", "name", name, "value", value, "unit", unit));

        /// <summary>level is trace, debug, info, warn, error or fatal.</summary>
        public static void Log(string level, string message) =>
            Add(Line("log", "t", Now(), "level", level, "msg", message));

        /// <summary>Sends a stats document already written as JSON, for an app dokkit cannot reach.</summary>
        public static void Stats(string documentJson) =>
            Add(Line("stats", "document", new Raw(documentJson)));

        /// <summary>Reports a run of a job. Call Done when it worked; disposing without Done reports a failure.</summary>
        public static Run Job(string name) => new Run(name);

        /// <summary>Sends an error: its type and stack, never its message.</summary>
        public static void Capture(Exception error, bool handled = true, IDictionary<string, string> tags = null)
        {
            try
            {
                if (http == null || error == null) return;
                // The entry assembly's first name segment, so its sibling projects count too. Without one, anything but the framework.
                var prefix = Assembly.GetEntryAssembly()?.GetName().Name?.Split('.')[0];
                var frames = new List<object>();
                // Innermost last, as the format asks.
                foreach (var f in (new StackTrace(error, true).GetFrames() ?? new StackFrame[0]).Reverse())
                {
                    var method = f.GetMethod();
                    if (method == null) continue;
                    frames.Add(new Dictionary<string, object>
                    {
                        ["file"] = method.DeclaringType?.FullName,
                        ["function"] = method.Name,
                        ["line"] = f.GetFileLineNumber() == 0 ? (object)null : f.GetFileLineNumber(),
                        ["own"] = IsOwn(method.DeclaringType?.Assembly, prefix),
                    });
                }
                var report = new Dictionary<string, object>
                {
                    ["at"] = Now(), ["type"] = error.GetType().Name, ["handled"] = handled, ["release"] = version,
                    ["environment"] = environment, ["host"] = host, ["frames"] = frames,
                    ["tags"] = (tags ?? new Dictionary<string, string>()).ToDictionary(t => t.Key, t => (object)t.Value),
                };
                lock (Gate) { if (Errors.Count < 100) Errors.Enqueue(report); }
                Wake.Set();
            }
            catch { }
        }

        static bool IsOwn(Assembly assembly, string prefix)
        {
            var name = assembly?.GetName().Name;
            if (name == null) return false;
            if (prefix != null) return name == prefix || name.StartsWith(prefix + ".", StringComparison.Ordinal);
            return name != "mscorlib" && name != "netstandard" && !name.StartsWith("System", StringComparison.Ordinal)
                && !name.StartsWith("Microsoft", StringComparison.Ordinal) && name != "Dokkit";
        }

        /// <summary>Also reports errors nothing caught.</summary>
        public static void CatchUnhandled() =>
            AppDomain.CurrentDomain.UnhandledException += (s, e) => { Capture(e.ExceptionObject as Exception, false); Flush(); };

        /// <summary>Sends what is waiting. Called for you when the app exits.</summary>
        public static void Flush()
        {
            lock (Sending)
            {
                try
                {
                    while (http != null)
                    {
                        var batch = retry ?? Next();
                        retry = null;
                        if (batch == null) return;
                        int status;
                        try { status = Post(batch); } catch { status = 599; }
                        if (status < 400) continue;
                        // A failed batch gets one more try; what is lost then is counted.
                        var again = status >= 500 || status == 429;
                        if (again && ++batch.Tries < 2) retry = batch;
                        else lock (Gate) Dropped += batch.Count;
                        if (again) return;
                    }
                }
                catch { /* What could not be sent is dropped. The app is never told. */ }
            }
        }

        sealed class Batch
        {
            public string Path, Kind;
            public byte[] Body;
            public bool Gzip;
            public int Count, Tries;
            public readonly string Id = Guid.NewGuid().ToString();
        }

        static Batch Next()
        {
            Dictionary<string, object> error = null;
            var batch = new List<string>();
            lock (Gate)
            {
                if (Errors.Count > 0) error = Errors.Dequeue();
                else while (Lines.Count > 0 && batch.Count < 500)
                {
                    var line = Lines.Dequeue();
                    lineBytes -= line.Length;
                    batch.Add(line);
                }
            }
            if (error != null)
                return new Batch { Path = "/api/v1/errors", Body = Encoding.UTF8.GetBytes(Json(error)), Kind = "application/json", Count = 1 };
            if (batch.Count == 0) return null;
            return new Batch { Path = "/api/v1/report", Body = Gzip(string.Join("\n", batch)), Kind = "application/x-ndjson", Gzip = true, Count = batch.Count };
        }

        static void Run()
        {
            while (true) { Wake.WaitOne(2000); Flush(); }
        }

        static int Post(Batch batch)
        {
            var content = new ByteArrayContent(batch.Body);
            content.Headers.TryAddWithoutValidation("Content-Type", batch.Kind);
            if (batch.Gzip)
            {
                content.Headers.TryAddWithoutValidation("Content-Encoding", "gzip");
                content.Headers.TryAddWithoutValidation("Dokkit-Batch", batch.Id);
            }
            using (var response = http.PostAsync(url + batch.Path, content).GetAwaiter().GetResult()) return (int)response.StatusCode;
        }

        static byte[] Gzip(string text)
        {
            using (var buffer = new MemoryStream())
            {
                using (var z = new GZipStream(buffer, CompressionMode.Compress))
                {
                    var bytes = Encoding.UTF8.GetBytes(text);
                    z.Write(bytes, 0, bytes.Length);
                }
                return buffer.ToArray();
            }
        }

        static string Now() => DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);

        static Dictionary<string, object> Line(string type, params object[] pairs)
        {
            var line = new Dictionary<string, object> { ["type"] = type, ["at"] = Now() };
            for (var i = 0; i + 1 < pairs.Length; i += 2)
                if (pairs[i + 1] != null) line[(string)pairs[i]] = pairs[i + 1];
            return line;
        }

        internal static void Add(Dictionary<string, object> line)
        {
            if (http == null) return;
            line["host"] = host;
            var text = Json(line);
            lock (Gate)
            {
                if (text.Length > QueueBytes) { Dropped++; return; }
                while (Lines.Count > 0 && (Lines.Count >= QueueSize || lineBytes + text.Length > QueueBytes))
                {
                    lineBytes -= Lines.Dequeue().Length;
                    Dropped++;
                }
                Lines.Enqueue(text);
                lineBytes += text.Length;
            }
        }

        internal static void Nudge() => Wake.Set();
        internal static Dictionary<string, object> NewLine(string type, params object[] pairs) => Line(type, pairs);

        sealed class Raw { public readonly string Text; public Raw(string text) { Text = text.Replace('\r', ' ').Replace('\n', ' '); } }

        static string Json(object value)
        {
            switch (value)
            {
                case null: return "null";
                case Raw raw: return raw.Text;
                case bool b: return b ? "true" : "false";
                case string s:
                    var text = new StringBuilder("\"");
                    foreach (var c in s)
                    {
                        if (c == '"' || c == '\\') text.Append('\\').Append(c);
                        else if (c < ' ') text.Append("\\u").Append(((int)c).ToString("x4"));
                        else text.Append(c);
                    }
                    return text.Append('"').ToString();
                case IDictionary<string, object> map:
                    return "{" + string.Join(",", map.Select(p => Json(p.Key) + ":" + Json(p.Value))) + "}";
                case IEnumerable list:
                    return "[" + string.Join(",", list.Cast<object>().Select(Json)) + "]";
                case IFormattable number:
                    return number.ToString(null, CultureInfo.InvariantCulture);
                default:
                    return Json(value.ToString());
            }
        }
    }

    /// <summary>One run of a job.</summary>
    public sealed class Run : IDisposable
    {
        readonly string name, id = Guid.NewGuid().ToString();
        readonly Stopwatch watch = Stopwatch.StartNew();
        bool ended;

        internal Run(string name)
        {
            this.name = name;
            Send("start");
        }

        void Send(string @event, params object[] more) =>
            Client.Add(Client.NewLine("job", new object[] { "name", name, "run", id, "event", @event }.Concat(more).ToArray()));

        public void Progress(long done, long? total = null) => Send("progress", "done", done, "total", total);

        public void Done() => End("ok", 0);

        public void Fail(Exception error = null)
        {
            End("fail", 1);
            Client.Capture(error, false);
        }

        void End(string @event, int code)
        {
            if (ended) return;
            ended = true;
            Send(@event, "exit_code", code, "duration_ms", watch.ElapsedMilliseconds);
            Client.Nudge();
        }

        public void Dispose() => End("fail", 1);
    }
}
