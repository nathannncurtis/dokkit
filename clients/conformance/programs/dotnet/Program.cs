using System;
using Dokkit;

class ConformanceError : Exception { }

static class Program
{
    static void Main(string[] args)
    {
        Client.Start(version: "9.9.9");
        Client.Beat("conf-beat", 60);
        var run = Client.Job("conf-job");
        run.Done();
        Client.Check("conf-check", "ok", 1);
        Client.Metric("conf.metric", 5, "n");
        Client.Log("info", "conformance " + args[0]);
        try { throw new ConformanceError(); }
        catch (Exception e) { Client.Capture(e); }
        Client.Flush();
    }
}
