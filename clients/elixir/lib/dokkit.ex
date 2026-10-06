defmodule Dokkit do
  @moduledoc """
  The Dokkit client library for Elixir. One file, no packages. Elixir 1.18 or later.

      Dokkit.start(version: "2.3.0", app: :my_app)   # reads DOKKIT_URL and DOKKIT_KEY; blank means off
      Dokkit.beat("worker")                          # from the main loop
      Dokkit.job("nightly-purge", fn progress -> progress.(4000, 9000) end)
      Dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old")
      Dokkit.capture(error, __STACKTRACE__)
      :logger.add_handler(:dokkit, Dokkit, %{level: :info})

  Nothing here raises into the app or waits on the network. Lines wait in a queue of fixed
  size and one process sends them. Error message text is never sent.
  """
  use GenServer

  @queue 1000

  @doc "Turns the library on. With no address or key it stays off and every call does nothing."
  def start(opts \\ []) do
    url = opts[:url] || System.get_env("DOKKIT_URL", "")
    key = opts[:key] || System.get_env("DOKKIT_KEY", "")

    if url != "" and key != "" and GenServer.whereis(__MODULE__) == nil do
      {:ok, host} = :inet.gethostname()
      Application.ensure_all_started([:inets, :ssl])

      GenServer.start(
        __MODULE__,
        %{
          url: String.trim_trailing(url, "/"),
          key: key,
          version: opts[:version],
          app: opts[:app],
          environment: opts[:environment] || System.get_env("DOKKIT_ENV"),
          host: to_string(host),
          lines: [],
          errors: [],
          dropped: 0
        },
        name: __MODULE__
      )

      if opts[:version], do: add(%{type: "deploy", version: to_string(opts[:version])})
    end

    :ok
  end

  def beat(name, every_seconds \\ 60),
    do: add(%{type: "beat", name: name, every_seconds: every_seconds})

  @doc ~s(state is "ok", "degraded" or "down".)
  def check(name, state, value \\ nil, note \\ nil),
    do: add(%{type: "custom", check: name, state: state, value: value, note: note})

  def metric(name, value, unit \\ nil),
    do: add(%{type: "metric", name: name, value: value, unit: unit})

  @doc "Sends a stats document, for an app dokkit cannot reach."
  def stats(document), do: add(%{type: "stats", document: document})

  @doc "Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns."
  def job(name, work) do
    run = id()
    began = System.monotonic_time(:millisecond)
    send = fn event, more -> add(Map.merge(%{type: "job", name: name, run: run, event: event}, more)) end
    took = fn -> System.monotonic_time(:millisecond) - began end
    send.("start", %{})

    try do
      result = work.(fn done, total -> send.("progress", %{done: done, total: total}) end)
      send.("ok", %{exit_code: 0, duration_ms: took.()})
      result
    rescue
      error ->
        send.("fail", %{exit_code: 1, duration_ms: took.()})
        capture(error, __STACKTRACE__, handled: false)
        reraise error, __STACKTRACE__
    after
      cast(:flush)
    end
  end

  @doc "Sends an error: its type and stack, never its message."
  def capture(error, stacktrace, opts \\ []) do
    type = if is_exception(error), do: inspect(error.__struct__), else: "throw"
    cast({:error, type, stacktrace, Keyword.get(opts, :handled, true), Map.new(opts[:tags] || %{})})
  end

  @doc "How many lines were dropped because the queue was full."
  def dropped, do: if(GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :dropped), else: 0)

  @doc "Sends what is waiting. Call it before the app stops."
  def flush do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :flush, 30_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "level is trace, debug, info, warn, error or fatal."
  def log(level, msg) when is_binary(level), do: add(%{type: "log", t: now(), level: level, msg: msg})

  # The :logger handler. Its lines go to the Logs page.
  def log(%{level: level, msg: msg}, _config) do
    text =
      case msg do
        {:string, s} -> IO.chardata_to_string(s)
        {:report, r} -> inspect(r)
        {format, args} -> format |> :io_lib.format(args) |> IO.chardata_to_string()
      end

    level =
      case level do
        :debug -> "debug"
        l when l in [:info, :notice] -> "info"
        :warning -> "warn"
        :error -> "error"
        _ -> "fatal"
      end

    add(%{type: "log", t: now(), level: level, msg: text})
  rescue
    _ -> :ok
  end

  defp add(line), do: cast({:line, Map.put_new(line, :at, now())})
  defp cast(what), do: if(GenServer.whereis(__MODULE__), do: GenServer.cast(__MODULE__, what), else: :ok)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp id do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary>> =
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  @impl true
  def init(state) do
    :timer.send_interval(2000, :tick)
    {:ok, state}
  end

  @impl true
  def handle_cast({:line, line}, s) do
    line = line |> Map.put(:host, s.host) |> Map.reject(fn {_, v} -> is_nil(v) end)

    if length(s.lines) >= @queue,
      do: {:noreply, %{s | lines: [line | Enum.drop(s.lines, -1)], dropped: s.dropped + 1}},
      else: {:noreply, %{s | lines: [line | s.lines]}}
  end

  def handle_cast({:error, type, stacktrace, handled, tags}, s) do
    # Innermost last, as the format asks.
    frames =
      for {module, function, arity, where} <- Enum.reverse(stacktrace) do
        %{
          file: to_string(where[:file] || inspect(module)),
          function: "#{inspect(module)}.#{function}/#{if is_list(arity), do: length(arity), else: arity}",
          line: where[:line],
          own: Application.get_application(module) in [nil, s.app]
        }
      end

    report = %{
      at: now(),
      type: type,
      handled: handled,
      release: s.version,
      environment: s.environment,
      host: s.host,
      frames: frames,
      tags: Map.new(tags, fn {k, v} -> {to_string(k), to_string(v)} end)
    }

    {:noreply, if(length(s.errors) < 100, do: %{s | errors: [report | s.errors]}, else: s)}
  end

  def handle_cast(:flush, s), do: {:noreply, send_all(s)}

  @impl true
  def handle_call(:flush, _from, s), do: {:reply, :ok, send_all(s)}
  def handle_call(:dropped, _from, s), do: {:reply, s.dropped, s}

  @impl true
  def handle_info(:tick, s), do: {:noreply, send_all(s)}
  def handle_info(_, s), do: {:noreply, s}

  # What cannot be sent is dropped. The app is never told.
  defp send_all(s) do
    for error <- Enum.reverse(s.errors),
        do: post(s, "/api/v1/errors", JSON.encode!(error), "application/json", [])

    for batch <- s.lines |> Enum.reverse() |> Enum.chunk_every(500) do
      body = batch |> Enum.map_join("\n", &JSON.encode!/1) |> :zlib.gzip()

      post(s, "/api/v1/report", body, "application/x-ndjson", [
        {~c"content-encoding", ~c"gzip"},
        {~c"dokkit-batch", to_charlist(id())}
      ])
    end

    %{s | lines: [], errors: []}
  end

  defp post(s, path, body, kind, headers) do
    headers = [{~c"authorization", to_charlist("Bearer " <> s.key)} | headers]
    request = {to_charlist(s.url <> path), headers, to_charlist(kind), body}
    :httpc.request(:post, request, [timeout: 10_000], [])
  catch
    _, _ -> :error
  end
end
