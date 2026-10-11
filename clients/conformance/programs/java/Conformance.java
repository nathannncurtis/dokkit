import dev.dokkit.Dokkit;

public class Conformance {
    static class ConformanceError extends RuntimeException {}

    public static void main(String[] args) throws Exception {
        Dokkit.start("9.9.9");
        Dokkit.beat("conf-beat", 60);
        Dokkit.job("conf-job", run -> {});
        Dokkit.check("conf-check", "ok", 1.0, null);
        Dokkit.metric("conf.metric", 5, "n");
        Dokkit.log("info", "conformance " + args[0]);
        try { throw new ConformanceError(); } catch (ConformanceError e) { Dokkit.capture(e); }
        Dokkit.flush();
    }
}
