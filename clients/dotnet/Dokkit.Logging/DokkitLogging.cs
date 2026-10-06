// Sends what an app logs through Microsoft.Extensions.Logging to Dokkit's Logs page.
//
//     builder.Logging.AddDokkit();                      // after Dokkit.Client.Start(...)
//     builder.Logging.AddDokkit(LogLevel.Warning);      // only warnings and worse
//
// It is its own project so the library itself needs no packages.
using System;
using System.Threading;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Dokkit
{
    public static class DokkitLogging
    {
        public static ILoggingBuilder AddDokkit(this ILoggingBuilder builder, LogLevel from = LogLevel.Information)
        {
            builder.Services.AddSingleton<ILoggerProvider>(new Provider(from));
            return builder;
        }

        sealed class Provider : ILoggerProvider
        {
            readonly LogLevel from;
            public Provider(LogLevel from) { this.from = from; }
            public ILogger CreateLogger(string category) => new Logger(from);
            public void Dispose() { }
        }

        sealed class Logger : ILogger
        {
            readonly LogLevel from;
            public Logger(LogLevel from) { this.from = from; }

            public IDisposable BeginScope<TState>(TState state) => null;
            public bool IsEnabled(LogLevel level) => level >= from && level != LogLevel.None;

            public void Log<TState>(LogLevel level, EventId id, TState state, Exception error, Func<TState, Exception, string> format)
            {
                if (!IsEnabled(level)) return;
                // The app's own formatter can throw; that never reaches the app through here.
                try { Client.Log(Name(level), format(state, error)); } catch { }
                // The error goes to the Errors page by its type and stack. Its message stays here.
                // Reading symbols can touch slow disks, so it happens off the logging thread.
                if (error != null) ThreadPool.QueueUserWorkItem(_ => Client.Capture(error));
            }

            static string Name(LogLevel level)
            {
                switch (level)
                {
                    case LogLevel.Trace: return "trace";
                    case LogLevel.Debug: return "debug";
                    case LogLevel.Warning: return "warn";
                    case LogLevel.Error: return "error";
                    case LogLevel.Critical: return "fatal";
                    default: return "info";
                }
            }
        }
    }
}
