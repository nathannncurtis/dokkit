// The Dokkit client library for .NET. One file, no packages.
//
//     Dokkit.Client.Start(version: "2.3.0");   // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     Dokkit.Client.Beat("worker");            // from the main loop
//     using (var run = Dokkit.Client.Job("nightly-purge")) { run.Progress(4000, 9000); run.Done(); }
//     Dokkit.Client.Check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
//     Dokkit.Client.Capture(exception);
//
// Nothing here throws into the app or waits on the network. Lines wait in a queue of fixed
// size and a background thread sends them. Error message text is never sent.
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
        const int QueueSize = 1000;
        static readonly object Gate = new object();
        static readonly Queue<Dictionary<string, object>> Lines = new Queue<Dictionary<string, object>>();
        static readonly Queue<Dictionary<string, object>> Errors = new Queue<Dictionary<string, object>>();
        static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        static HttpClient http;
        static string url, version, environment, host;

        /// <summary>How many lines were dropped because the queue was full.</summary>
        public static int Dropped { get; private set; }

        /// <summary>Turns the library on. With no address or key it stays off and every call does nothing.</summary>
        public static void Start(string version = null, string environment = null, string url = null, string key = null)
        {
            try
            {
                url = url ?? Environment.GetEnvironmentVariable("DOKKIT_URL");
                key = key ?? Environment.GetEnvironmentVariable("DOKKIT_KEY");
                if (string.IsNullOrEmpty(url) || string.IsNullOrEmpty(key) || http != null) return;
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
                var own = Assembly.GetEntryAssembly();
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
                        ["own"] = method.DeclaringType?.Assembly == own,
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

        /// <summary>Also reports errors nothing caught.</summary>
        public static void CatchUnhandled() =>
            AppDomain.CurrentDomain.UnhandledException += (s, e) => { Capture(e.ExceptionObject as Exception, false); Flush(); };

        /// <summary>Sends what is waiting. Called for you when the app exits.</summary>
        public static void Flush()
        {
            try
            {
                while (true)
                {
                    Dictionary<string, object> error = null;
                    var batch = new List<Dictionary<string, object>>();
                    lock (Gate)
                    {
                        if (Errors.Count > 0) error = Errors.Dequeue();
                        else while (Lines.Count > 0 && batch.Count < 500) batch.Add(Lines.Dequeue());
                    }
                    if (error != null) { Post("/api/v1/errors", Encoding.UTF8.GetBytes(Json(error)), "application/json", false); continue; }
                    if (batch.Count == 0) return;
                    Post("/api/v1/report", Gzip(string.Join("\n", batch.Select(Json))), "application/x-ndjson", true);
                }
            }
            catch { /* What could not be sent is dropped. The app is never told. */ }
        }

        static void Run()
        {
            while (true) { Wake.WaitOne(2000); Flush(); }
        }

        static void Post(string path, byte[] body, string kind, bool gzip)
        {
            var content = new ByteArrayContent(body);
            content.Headers.TryAddWithoutValidation("Content-Type", kind);
            if (gzip)
            {
                content.Headers.TryAddWithoutValidation("Content-Encoding", "gzip");
                content.Headers.TryAddWithoutValidation("Dokkit-Batch", Guid.NewGuid().ToString());
            }
            http.PostAsync(url + path, content).GetAwaiter().GetResult().Dispose();
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
            lock (Gate)
            {
                if (Lines.Count >= QueueSize) { Lines.Dequeue(); Dropped++; }
                Lines.Enqueue(line);
            }
        }

        internal static void Nudge() => Wake.Set();
        internal static Dictionary<string, object> NewLine(string type, params object[] pairs) => Line(type, pairs);

        sealed class Raw { public readonly string Text; public Raw(string text) { Text = text; } }

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
