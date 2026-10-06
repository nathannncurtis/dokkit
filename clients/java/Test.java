// Runs the library against a small local server and exits 1 when something is wrong.
//     javac -d out Dokkit.java Test.java && java -cp out Test

import com.sun.net.httpserver.HttpServer;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.GZIPInputStream;

public class Test {
    public static void main(String[] args) throws Exception {
        List<String> got = new ArrayList<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            InputStream body = exchange.getRequestBody();
            if ("gzip".equals(exchange.getRequestHeaders().getFirst("Content-Encoding"))) body = new GZIPInputStream(body);
            String text = new String(body.readAllBytes(), StandardCharsets.UTF_8);
            if (!"Bearer dka_test".equals(exchange.getRequestHeaders().getFirst("Authorization"))) text = "BAD KEY";
            synchronized (got) {
                for (String line : text.split("\n")) got.add(exchange.getRequestURI().getPath() + " " + line);
            }
            exchange.sendResponseHeaders(200, -1);
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
        Dokkit.flush();
        server.stop(0);

        String all = String.join("\n", got);
        String[] want = {
            "/api/v1/report {\"type\":\"deploy\"", "\"type\":\"beat\"", "\"every_seconds\":30", "\"state\":\"degraded\",\"value\":14.0",
            "oldest item is \\\"14\\\" minutes old", "\"level\":\"error\",\"msg\":\"Upload failed\"", "\"event\":\"start\"",
            "\"event\":\"progress\",\"done\":4000,\"total\":9000", "\"event\":\"fail\",\"exit_code\":1", "/api/v1/errors {",
            "\"type\":\"IllegalStateException\"", "\"handled\":false", "\"file\":\"Test\"", "\"own\":true",
        };
        List<String> missing = new ArrayList<>();
        for (String w : want) if (!all.contains(w)) missing.add(w);
        if (!missing.isEmpty() || all.contains("4411") || all.contains("BAD KEY") || all.contains("ignored")) {
            System.out.println("FAIL\nmissing: " + missing + "\n" + all);
            System.exit(1);
        }
        System.out.println("ok: " + got.size() + " lines");
    }
}
