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
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.GZIPInputStream;

public class Test {
    static boolean anyHas(List<String> got, String... parts) {
        synchronized (got) {
            for (String g : got) {
                boolean all = true;
                for (String p : parts) all &= g.contains(p);
                if (all) return true;
            }
        }
        return false;
    }

    public static void main(String[] args) throws Exception {
        // The JDK client's own request logging, which is what fed the handler back before.
        System.setProperty("jdk.httpclient.HttpClient.log", "requests,errors");
        List<String> got = new ArrayList<>();
        AtomicInteger posts = new AtomicInteger();
        AtomicBoolean refused = new AtomicBoolean();
        AtomicBoolean errorsDown = new AtomicBoolean();
        AtomicBoolean reportsDownOnce = new AtomicBoolean();
        List<String> hits = new ArrayList<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            posts.incrementAndGet();
            InputStream body = exchange.getRequestBody();
            if ("gzip".equals(exchange.getRequestHeaders().getFirst("Content-Encoding"))) body = new GZIPInputStream(body);
            String text = new String(body.readAllBytes(), StandardCharsets.UTF_8);
            if (!"Bearer dka_test".equals(exchange.getRequestHeaders().getFirst("Authorization"))) text = "BAD KEY";
            // The first report is refused once; the library has to send it again.
            boolean refuse = exchange.getRequestURI().getPath().equals("/api/v1/report") && refused.compareAndSet(false, true);
            String path = exchange.getRequestURI().getPath();
            if (path.equals("/api/v1/errors") && errorsDown.get()) refuse = true;
            if (path.equals("/api/v1/report") && reportsDownOnce.compareAndSet(true, false)) refuse = true;
            synchronized (got) {
                hits.add(path + (refuse ? " 503" : " 200"));
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

        errorsDown.set(true);
        Dokkit.log("info", "line while errors are down");
        Dokkit.capture(new IllegalArgumentException("kept"));
        Dokkit.flush();
        boolean keptWhileDown = anyHas(got, "line while errors are down") && !anyHas(got, "IllegalArgumentException");
        errorsDown.set(false);
        Dokkit.flush();

        reportsDownOnce.set(true);
        Dokkit.log("info", "line retried");
        Dokkit.capture(new ArithmeticException("independent"));
        Dokkit.flush();
        Dokkit.flush();
        boolean independent = false;
        synchronized (got) {
            for (int i = 0; i + 1 < hits.size(); i++) if (hits.get(i).equals("/api/v1/report 503") && hits.get(i + 1).startsWith("/api/v1/errors")) independent = true;
        }

        Dokkit.log("info", "é".repeat(50000));
        Dokkit.log("info", "a".repeat(70000));
        Dokkit.flush();
        int cut = 0;
        boolean cutOk = true;
        synchronized (got) {
            for (String g : got) if (g.contains(" [cut]\",")) { cut++; if (g.getBytes(StandardCharsets.UTF_8).length > 65536 + 20) cutOk = false; }
        }
        cutOk = cutOk && cut == 2;

        java.lang.reflect.Field httpField = Dokkit.class.getDeclaredField("http");
        httpField.setAccessible(true);
        String address = "http://127.0.0.1:" + server.getAddress().getPort() + "/";
        Dokkit.start("9.9.9", address, "dka_test");
        Dokkit.flush();
        boolean announcedOnce = !anyHas(got, "9.9.9");
        httpField.set(null, null);
        java.lang.reflect.Field env = Dokkit.class.getDeclaredField("environment");
        env.setAccessible(true);
        env.set(null, "dev");
        Dokkit.start("8.8.8", address, "dka_test", false);
        env.set(null, "dev");
        Dokkit.beat("after quiet start");
        Dokkit.log("info", "dev log");
        Dokkit.job("dev-job", run -> { });
        Dokkit.flush();
        boolean quiet = anyHas(got, "after quiet start") && !anyHas(got, "8.8.8");
        boolean devOk = true;
        for (String w : new String[] {"after quiet start", "dev log", "dev-job"}) devOk &= anyHas(got, w, "\"environment\":\"dev\"");
        env.set(null, "production");
        Dokkit.beat("production beat");
        Dokkit.flush();
        boolean prodOk = anyHas(got, "production beat") && !anyHas(got, "production beat", "\"environment\"");

        // With the JDK client's request logging on, one app line is one small, bounded number of posts.
        int before = posts.get();
        java.util.logging.Logger root = java.util.logging.Logger.getLogger("");
        for (java.util.logging.Handler h : root.getHandlers()) root.removeHandler(h);
        java.util.logging.Handler handler = Dokkit.handler();
        root.addHandler(handler);
        java.util.logging.Logger.getLogger("app").info("one app line");
        for (int i = 0; i < 6; i++) { Thread.sleep(400); Dokkit.flush(); }
        root.removeHandler(handler);
        int fed = posts.get() - before;
        server.stop(0);

        java.lang.reflect.Method safe = Dokkit.class.getDeclaredMethod("safe", String.class);
        safe.setAccessible(true);
        boolean guarded = (boolean) safe.invoke(null, "https://dokkit.example") && (boolean) safe.invoke(null, "http://localhost:80")
                && !(boolean) safe.invoke(null, "http://dokkit.example") && !(boolean) safe.invoke(null, "http://127.evil.example");

        long droppedBefore = Dokkit.dropped();
        java.net.ServerSocket silent = new java.net.ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"));
        httpField.set(null, null);
        Dokkit.start("7.7.7", "http://127.0.0.1:" + silent.getLocalPort() + "/", "dka_test", false);
        Dokkit.log("info", "to a server that never answers");
        java.lang.reflect.Method exitFlush = Dokkit.class.getDeclaredMethod("exitFlush");
        exitFlush.setAccessible(true);
        long began = System.nanoTime();
        exitFlush.invoke(null);
        double exitSeconds = (System.nanoTime() - began) / 1e9;

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
        if (!keptWhileDown) missing.add("a line is sent while error posts fail, and the error is kept");
        if (!anyHas(got, "/api/v1/errors", "IllegalArgumentException")) missing.add("kept error sent later");
        if (!anyHas(got, "ArithmeticException") || !anyHas(got, "line retried")) missing.add("failed batch retried");
        if (!independent) missing.add("a failed log batch does not skip error reports");
        if (!cutOk) missing.add("long lines cut under 64 KB with the marker, got " + cut);
        if (!announcedOnce) missing.add("second start announces nothing");
        if (!quiet) missing.add("announceVersion false sends no deploy line");
        if (!devOk) missing.add("dev environment on log, beat and job lines");
        if (!prodOk) missing.add("production adds no environment");
        if (!guarded) missing.add("http to another machine refused");
        if (fed < 1 || fed > 3) missing.add("one app line is one to three posts, got " + fed);
        if (all.split("one app line", -1).length != 2) missing.add("the app line once");
        if (droppedBefore != 0) missing.add("nothing dropped, got " + droppedBefore);
        if (exitSeconds > 6) missing.add("the exit flush waits at most 5 seconds, took " + exitSeconds);
        if (!missing.isEmpty() || all.contains("4411") || all.contains("BAD KEY") || all.contains("ignored") || all.contains("from the sender")) {
            System.out.println("FAIL\nmissing: " + missing + "\n" + all);
            System.exit(1);
        }
        System.out.println("ok: " + got.size() + " lines");
    }
}
