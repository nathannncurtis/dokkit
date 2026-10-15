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
        const int QueueSize = 1000, QueueBytes = 4 << 20, MaxLine = 65536;
        static readonly object Sending = new object();
        static int lineBytes;
        static Batch retry;
        static readonly object Gate = new object();
        static readonly Queue<string> Lines = new Queue<string>();
        // Reports are built on the sender thread, so reading symbols never slows the app.
        static readonly Queue<Func<Dictionary<string, object>>> Errors = new Queue<Func<Dictionary<string, object>>>();
        static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        static readonly AsyncLocal<bool> InSend = new AsyncLocal<bool>();
        static HttpClient http;
        static string url, version, environment, host, own;

        /// <summary>How many lines were dropped because the queue was full or could not be sent.</summary>
        public static int Dropped { get; private set; }

        /// <summary>Turns the library on. With no address or key it stays off and every call does nothing.
        /// Frames of assemblies named <paramref name="own"/> or <paramref name="own"/>.* are the app's own; by default, the entry assembly's first name segment.
        /// The version is announced once as a deploy line unless <paramref name="announceVersion"/> is false; the server records a deploy only when the version changes.</summary>
        public static void Start(string version = null, string environment = null, string url = null, string key = null, string own = null, bool announceVersion = true)
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
                Client.own = own;
                Client.environment = environment ?? Environment.GetEnvironmentVariable("DOKKIT_ENV");
                host = Environment.MachineName;
                var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer " + key);
                http = client;
                new Thread(Run) { IsBackground = true, Name = "dokkit" }.Start();
                AppDomain.CurrentDomain.ProcessExit += (s, e) => ExitFlush();
                if (version != null && announceVersion) Add(Line("deploy", "version", version));
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
                if (http == null || error == null || InSend.Value) return;
                var at = Now();
                var copy = (tags ?? new Dictionary<string, string>()).ToDictionary(t => t.Key, t => (object)t.Value);
                lock (Gate) { if (Errors.Count < 100) Errors.Enqueue(() => Report(error, handled, copy, at)); }
                Wake.Set();
            }
            catch { }
        }

        static Dictionary<string, object> Report(Exception error, bool handled, Dictionary<string, object> tags, string at)
        {
            // The entry assembly's first name segment, so its sibling projects count too. Without one, anything but the framework.
            var prefix = own ?? Assembly.GetEntryAssembly()?.GetName().Name?.Split('.')[0];
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
            return new Dictionary<string, object>
            {
                ["at"] = at, ["type"] = error.GetType().Name, ["handled"] = handled, ["release"] = version,
                ["environment"] = environment, ["host"] = host, ["frames"] = frames, ["tags"] = tags,
            };
        }

        static bool IsOwn(Assembly assembly, string prefix)
        {
            var name = assembly?.GetName().Name;
            if (name == null) return false;
            if (prefix != null) return name == prefix || name.StartsWith(prefix + ".", StringComparison.Ordinal);
            return name != "mscorlib" && name != "netstandard" && !name.StartsWith("System", StringComparison.Ordinal)
                && !name.StartsWith("Microsoft", StringComparison.Ordinal) && name != "Dokkit" && !name.StartsWith("Dokkit.", StringComparison.Ordinal);
        }

        /// <summary>Also reports errors nothing caught.</summary>
        public static void CatchUnhandled() =>
            AppDomain.CurrentDomain.UnhandledException += (s, e) => { Capture(e.ExceptionObject as Exception, false); ExitFlush(); };

        // The app is exiting: never hold it more than 5 seconds.
        static void ExitFlush()
        {
            var t = new Thread(Flush) { IsBackground = true, Name = "dokkit-exit" };
            t.Start();
            t.Join(5000);
        }

        /// <summary>Sends what is waiting. Called for you when the app exits.</summary>
        public static void Flush()
        {
            lock (Sending)
            {
                try { SendLines(); } catch { /* What could not be sent is dropped. The app is never told. */ }
                try { SendErrors(); } catch { }
            }
        }

        static void SendLines()
        {
            while (http != null)
            {
                var batch = retry ?? NextLines();
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

        static void SendErrors()
        {
            while (http != null)
            {
                Func<Dictionary<string, object>> error;
                lock (Gate) error = Errors.Count > 0 ? Errors.Peek() : null;
                if (error == null) return;
                byte[] body = null;
                var status = 599;
                try
                {
                    body = Encoding.UTF8.GetBytes(Json(error()));
                    status = Post(new Batch { Path = "/api/v1/errors", Body = body, Kind = "application/json" });
                }
                catch { }
                // A report the server did not answer for stays for the next pass; one it refuses is dropped.
                if (body != null && (status >= 500 || status == 429)) return;
                lock (Gate) { Errors.Dequeue(); if (body == null || status >= 400) Dropped++; }
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

        static Batch NextLines()
        {
            var batch = new List<string>();
            lock (Gate)
            {
                while (Lines.Count > 0 && batch.Count < 500)
                {
                    var line = Lines.Dequeue();
                    lineBytes -= line.Length;
                    batch.Add(line);
                }
            }
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
            InSend.Value = true;
            try { using (var response = http.PostAsync(url + batch.Path, content).GetAwaiter().GetResult()) return (int)response.StatusCode; }
            finally { InSend.Value = false; }
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
            if (http == null || InSend.Value) return;
            line["host"] = host;
            if (!string.IsNullOrEmpty(environment) && environment != "production") line["environment"] = environment;
            var text = Fit(line);
            if (text == null) { lock (Gate) Dropped++; return; }
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

        static int Size(string text) => Encoding.UTF8.GetByteCount(text);

        static string Fit(Dictionary<string, object> line)
        {
            var text = Json(line);
            var over = Size(text) - MaxLine;
            if (over <= 0) return text;
            if (!(line.TryGetValue("msg", out var m) && m is string msg)) return null;
            var n = msg.Length;
            while (over > 0 && n > 0)
            {
                n = Math.Max(0, n - over - 6);
                if (n > 0 && char.IsHighSurrogate(msg[n - 1])) n--;
                line["msg"] = msg.Substring(0, n) + " [cut]";
                text = Json(line);
                over = Size(text) - MaxLine;
            }
            return over > 0 ? null : text;
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
