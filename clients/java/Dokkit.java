// The Dokkit client library for Java. One file, no packages. Java 11 or later.
//
//     Dokkit.start("2.3.0");                 // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     Dokkit.beat("worker");                 // from the main loop
//     Dokkit.job("nightly-purge", run -> { run.progress(4000, 9000); });
//     Dokkit.check("queue-age", "degraded", 14.0, "oldest item is 14 minutes old");
//     Dokkit.capture(exception);
//     java.util.logging.Logger.getLogger("").addHandler(Dokkit.handler());
//
// Nothing here throws into the app or waits on the network. Lines wait in a queue of fixed
// size and a background thread sends them. Error message text is never sent.

import java.io.ByteArrayOutputStream;
import java.net.InetAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.logging.Handler;
import java.util.logging.LogRecord;
import java.util.stream.Collectors;
import java.util.zip.GZIPOutputStream;

public final class Dokkit {
    private static final int QUEUE = 1000;
    private static final Object gate = new Object();
    private static final ArrayDeque<Map<String, Object>> lines = new ArrayDeque<>();
    private static final ArrayDeque<Map<String, Object>> errors = new ArrayDeque<>();
    private static HttpClient http;
    private static String url, key, version, environment, host;
    private static int dropped;

    /** Frames of classes whose names start with this are the app's own. Blank means everything outside the JDK. */
    public static String own = "";

    private Dokkit() {}

    /** Turns the library on. With no address or key it stays off and every call does nothing. */
    public static void start(String version) {
        start(version, System.getenv("DOKKIT_URL"), System.getenv("DOKKIT_KEY"));
    }

    public static synchronized void start(String version, String url, String key) {
        try {
            if (url == null || url.isEmpty() || key == null || key.isEmpty() || http != null) return;
            Dokkit.url = url.replaceAll("/+$", "");
            Dokkit.key = key;
            Dokkit.version = version;
            environment = System.getenv("DOKKIT_ENV");
            host = InetAddress.getLocalHost().getHostName();
            http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();
            Thread sender = new Thread(() -> {
                while (true) {
                    synchronized (gate) {
                        try { gate.wait(2000); } catch (InterruptedException e) { return; }
                    }
                    flush();
                }
            }, "dokkit");
            sender.setDaemon(true);
            sender.start();
            Runtime.getRuntime().addShutdownHook(new Thread(Dokkit::flush));
            if (version != null) add(line("deploy", "version", version));
        } catch (Exception e) {
            http = null;
        }
    }

    /** How many lines were dropped because the queue was full. */
    public static int dropped() { return dropped; }

    public static void beat(String name) { beat(name, 60); }

    public static void beat(String name, int everySeconds) {
        add(line("beat", "name", name, "every_seconds", everySeconds));
    }

    /** state is "ok", "degraded" or "down". value and note may be null. */
    public static void check(String name, String state, Double value, String note) {
        add(line("custom", "check", name, "state", state, "value", value, "note", note));
    }

    public static void metric(String name, double value, String unit) {
        add(line("metric", "name", name, "value", value, "unit", unit));
    }

    /** level is trace, debug, info, warn, error or fatal. */
    public static void log(String level, String message) {
        add(line("log", "t", Instant.now().toString(), "level", level, "msg", message));
    }

    /** Sends a stats document already written as JSON, for an app dokkit cannot reach. */
    public static void stats(String documentJson) {
        add(line("stats", "document", new Raw(documentJson)));
    }

    public interface Work { void run(Run run) throws Exception; }

    /** One run of a job. */
    public static final class Run {
        private final String name, id = UUID.randomUUID().toString();

        private Run(String name) { this.name = name; }

        private void send(String event, Object... more) {
            Map<String, Object> line = line("job", "name", name, "run", id, "event", event);
            line.putAll(pairs(more));
            add(line);
        }

        public void progress(long done, long total) { send("progress", "done", done, "total", total > 0 ? total : null); }
    }

    /** Reports a run of a job: its start, its progress, and how it ended. What the work throws carries on up. */
    public static void job(String name, Work work) throws Exception {
        Run run = new Run(name);
        long began = System.nanoTime();
        run.send("start");
        try {
            work.run(run);
            run.send("ok", "exit_code", 0, "duration_ms", (System.nanoTime() - began) / 1_000_000);
        } catch (Exception e) {
            run.send("fail", "exit_code", 1, "duration_ms", (System.nanoTime() - began) / 1_000_000);
            capture(e, false);
            throw e;
        } finally {
            synchronized (gate) { gate.notifyAll(); }
        }
    }

    /** Sends an error: its type and stack, never its message. */
    public static void capture(Throwable error) { capture(error, true); }

    public static void capture(Throwable error, boolean handled) {
        try {
            if (http == null || error == null) return;
            List<Object> frames = new ArrayList<>();
            StackTraceElement[] stack = error.getStackTrace();
            // Innermost last, as the format asks.
            for (int i = stack.length - 1; i >= 0; i--) {
                String type = stack[i].getClassName();
                boolean jdk = type.startsWith("java.") || type.startsWith("javax.") || type.startsWith("jdk.") || type.startsWith("sun.");
                frames.add(pairs("file", type, "function", stack[i].getMethodName(),
                        "line", stack[i].getLineNumber() > 0 ? stack[i].getLineNumber() : null,
                        "own", own.isEmpty() ? !jdk : type.startsWith(own)));
            }
            Map<String, Object> report = pairs("at", Instant.now().toString(), "type", error.getClass().getSimpleName(),
                    "handled", handled, "release", version, "environment", environment, "host", host,
                    "frames", frames, "tags", new LinkedHashMap<String, Object>());
            synchronized (gate) {
                if (errors.size() < 100) errors.add(report);
                gate.notifyAll();
            }
        } catch (Exception e) {
            // Reporting an error never causes one.
        }
    }

    /** Also reports errors nothing caught, then hands them to whatever handled them before. */
    public static void catchUnhandled() {
        Thread.UncaughtExceptionHandler before = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            capture(error, false);
            flush();
            if (before != null) before.uncaughtException(thread, error);
        });
    }

    /** A handler for java.util.logging. Its lines go to the Logs page. */
    public static Handler handler() {
        return new Handler() {
            @Override public void publish(LogRecord r) {
                int n = r.getLevel().intValue();
                log(n >= 1000 ? "error" : n >= 900 ? "warn" : n >= 800 ? "info" : "debug", String.valueOf(r.getMessage()));
            }
            @Override public void flush() {}
            @Override public void close() {}
        };
    }

    /** Sends what is waiting. Called for you when the app exits. */
    public static void flush() {
        try {
            while (http != null) {
                Map<String, Object> error;
                List<Map<String, Object>> batch = new ArrayList<>();
                synchronized (gate) {
                    error = errors.poll();
                    while (error == null && !lines.isEmpty() && batch.size() < 500) batch.add(lines.poll());
                }
                if (error != null) {
                    post("/api/v1/errors", json(error).getBytes(StandardCharsets.UTF_8), "application/json", false);
                } else if (batch.isEmpty()) {
                    return;
                } else {
                    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                    try (GZIPOutputStream z = new GZIPOutputStream(buffer)) {
                        z.write(batch.stream().map(Dokkit::json).collect(Collectors.joining("\n")).getBytes(StandardCharsets.UTF_8));
                    }
                    post("/api/v1/report", buffer.toByteArray(), "application/x-ndjson", true);
                }
            }
        } catch (Exception e) {
            // What could not be sent is dropped. The app is never told.
        }
    }

    private static void post(String path, byte[] body, String kind, boolean gzip) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(url + path)).timeout(Duration.ofSeconds(10))
                .header("Authorization", "Bearer " + key).header("Content-Type", kind)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body));
        if (gzip) request.header("Content-Encoding", "gzip").header("Dokkit-Batch", UUID.randomUUID().toString());
        http.send(request.build(), HttpResponse.BodyHandlers.discarding());
    }

    private static void add(Map<String, Object> line) {
        if (http == null) return;
        line.put("host", host);
        synchronized (gate) {
            if (lines.size() >= QUEUE) { lines.poll(); dropped++; }
            lines.add(line);
        }
    }

    private static Map<String, Object> line(String type, Object... pairs) {
        Map<String, Object> line = new LinkedHashMap<>();
        line.put("type", type);
        line.put("at", Instant.now().toString());
        line.putAll(pairs(pairs));
        return line;
    }

    // Null values are left out.
    private static Map<String, Object> pairs(Object... pairs) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int i = 0; i + 1 < pairs.length; i += 2) if (pairs[i + 1] != null) map.put((String) pairs[i], pairs[i + 1]);
        return map;
    }

    private static final class Raw {
        final String text;
        Raw(String text) { this.text = text; }
    }

    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof Raw) return ((Raw) value).text;
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        if (value instanceof Map) {
            return ((Map<?, ?>) value).entrySet().stream().map(e -> json(e.getKey().toString()) + ":" + json(e.getValue()))
                    .collect(Collectors.joining(",", "{", "}"));
        }
        if (value instanceof List) return ((List<?>) value).stream().map(Dokkit::json).collect(Collectors.joining(",", "[", "]"));
        StringBuilder text = new StringBuilder("\"");
        for (char c : value.toString().toCharArray()) {
            if (c == '"' || c == '\\') text.append('\\').append(c);
            else if (c < ' ') text.append(String.format("\\u%04x", (int) c));
            else text.append(c);
        }
        return text.append('"').toString();
    }
}
