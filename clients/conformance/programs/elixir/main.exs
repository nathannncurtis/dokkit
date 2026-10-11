defmodule ConformanceError do
  defexception message: "x"
end

Code.require_file(Path.join([__DIR__, "..", "..", "..", "elixir", "lib", "dokkit.ex"]))

[tag] = System.argv()
Dokkit.start(version: "9.9.9")
Dokkit.beat("conf-beat", 60)
Dokkit.job("conf-job", fn _progress -> :ok end)
Dokkit.check("conf-check", "ok", 1)
Dokkit.metric("conf.metric", 5, "n")
Dokkit.log("info", "conformance " <> tag)

try do
  raise ConformanceError
rescue
  e -> Dokkit.capture(e, __STACKTRACE__)
end

Dokkit.flush()
