// Runs the library against a small local server and exits 1 when something is wrong.
//     javac -d out src/main/java/dev/dokkit/Dokkit.java src/test/java/dev/dokkit/Test.java && java -cp out dev.dokkit.Test

package dev.dokkit;

import com.sun.net.httpserver.HttpServer;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.GZIPInputStream;

public class Test {
    public static void main(String[] args) throws Exception {
        List<String> got = new ArrayList<>();
        AtomicBoolean refused = new AtomicBoolean();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            InputStream body = exchange.getRequestBody();
            if ("gzip".equals(exchange.getRequestHeaders().getFirst("Content-Encoding"))) body = new GZIPInputStream(body);
            String text = new String(body.readAllBytes(), StandardCharsets.UTF_8);
            if (!"Bearer dka_test".equals(exchange.getRequestHeaders().getFirst("Authorization"))) text = "BAD KEY";
            // The first report is refused once; the library has to send it again.
            boolean refuse = exchange.getRequestURI().getPath().equals("/api/v1/report") && refused.compareAndSet(false, true);
            synchronized (got) {
                if (!refuse) for (String line : text.split("\n")) got.add(exchange.getRequestURI().getPath() + " " + line);
            }
            exchange.sendResponseHeaders(refuse ? 503 : 200, -1);
            exchange.close();
        });
        server.start();

        Dokkit.beat("ignored: not started");
        Dokkit.start("2.3.0", "http://127.0.0.1:" + server.getAddress().getPort() + "/", "dka_test");
        Dokkit.beat("worker", 30);
        Dokkit.check("queue-age", "degraded", 14.0, "oldest item is \"14\" minutes old");
        Dokkit.handler().publish(new java.util.logging.LogRecord(java.util.logging.Level.SEVERE, "Upload failed"));
        try {
            Dokkit.job("nightly-purge", run -> {
                run.progress(4000, 9000);
                throw new IllegalStateException("patient 4411");
            });
        } catch (IllegalStateException expected) {
        }
        Dokkit.own = "dev.dokkit.Test";
        try { Integer.parseInt("x"); } catch (NumberFormatException e) { Dokkit.capture(e); }
        Dokkit.own = "";
        // Whatever is logged on a thread that is sending is not queued.
        java.lang.reflect.Field flag = Dokkit.class.getDeclaredField("sendingNow");
        flag.setAccessible(true);
        @SuppressWarnings("unchecked") ThreadLocal<Boolean> sendingNow = (ThreadLocal<Boolean>) flag.get(null);
        sendingNow.set(true);
        Dokkit.handler().publish(new java.util.logging.LogRecord(java.util.logging.Level.SEVERE, "from the sender"));
        sendingNow.set(false);

        Dokkit.stats("{\n  \"stat\": 7\n}");
        Dokkit.flush();
        Dokkit.flush();
        server.stop(0);

        java.lang.reflect.Method safe = Dokkit.class.getDeclaredMethod("safe", String.class);
        safe.setAccessible(true);
        boolean guarded = (boolean) safe.invoke(null, "https://dokkit.example") && (boolean) safe.invoke(null, "http://localhost:80")
                && !(boolean) safe.invoke(null, "http://dokkit.example") && !(boolean) safe.invoke(null, "http://127.evil.example");

        String all = String.join("\n", got);
        String[] want = {
            "/api/v1/report {\"type\":\"deploy\"", "\"type\":\"beat\"", "\"every_seconds\":30", "\"state\":\"degraded\",\"value\":14.0",
            "oldest item is \\\"14\\\" minutes old", "\"level\":\"error\",\"msg\":\"Upload failed\"", "\"event\":\"start\"",
            "\"event\":\"progress\",\"done\":4000,\"total\":9000", "\"event\":\"fail\",\"exit_code\":1", "/api/v1/errors {",
            "\"type\":\"IllegalStateException\"", "\"handled\":false", "\"file\":\"dev.dokkit.Test\"", "\"own\":true",
        };
        List<String> missing = new ArrayList<>();
        for (String w : want) if (!all.contains(w)) missing.add(w);
        if (!all.contains("\"document\":{   \"stat\": 7 }")) missing.add("stats on one line");
        if (!java.util.regex.Pattern.compile("\"java.lang.Integer\"[^}]*\"own\":false").matcher(all).find()) missing.add("jdk frame not own");
        if (!guarded) missing.add("http to another machine refused");
        if (Dokkit.dropped() != 0) missing.add("nothing dropped, got " + Dokkit.dropped());
        if (!missing.isEmpty() || all.contains("4411") || all.contains("BAD KEY") || all.contains("ignored") || all.contains("from the sender")) {
            System.out.println("FAIL\nmissing: " + missing + "\n" + all);
            System.exit(1);
        }
        System.out.println("ok: " + got.size() + " lines");
    }
}
