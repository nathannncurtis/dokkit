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
  size and one process sends them. Error message text is never sent. An http address to
  another machine keeps the library off unless DOKKIT_INSECURE=1.
  """
  use GenServer

  @queue 1000
  @max_bytes 8 * 1024 * 1024
  @max_line 1024 * 1024
  @max_batch 4 * 1024 * 1024

  @doc "Turns the library on. With no address or key it stays off and every call does nothing."
  def start(opts \\ []) do
    url = opts[:url] || System.get_env("DOKKIT_URL", "")
    key = opts[:key] || System.get_env("DOKKIT_KEY", "")

    if url != "" and key != "" and secure?(url) and GenServer.whereis(__MODULE__) == nil do
      {:ok, host} = :inet.gethostname()
      Application.ensure_all_started([:inets, :ssl])

      GenServer.start(
        __MODULE__,
        %{
          url: String.trim_trailing(url, "/"),
          key: key,
          version: opts[:version],
          app: opts[:app] || own_app(),
          environment: opts[:environment] || System.get_env("DOKKIT_ENV"),
          host: to_string(host),
          lines: :queue.new(),
          count: 0,
          bytes: 0,
          errors: [],
          held: [],
          sender: nil,
          waiters: [],
          dropped: 0
        },
        name: __MODULE__
      )

      if opts[:version], do: add(%{type: "deploy", version: to_string(opts[:version])})
    end

    :ok
  end

  # The app of the process that starts the library, so its frames count as the app's own.
  defp own_app do
    case :application.get_application() do
      {:ok, app} -> app
      _ -> nil
    end
  end

  defp secure?(url) do
    %URI{scheme: scheme, host: host} = URI.parse(url)

    ok =
      scheme != "http" or System.get_env("DOKKIT_INSECURE") == "1" or
        host == "localhost" or
        match?({:ok, {127, _, _, _}}, :inet.parse_address(to_charlist(host || ""))) or
        host == "::1"

    unless ok,
      do:
        IO.puts(
          :stderr,
          "dokkit: off, the address is http and not this machine; use https or set DOKKIT_INSECURE=1"
        )

    ok
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
    catch
      :exit, reason
      when reason in [:normal, :shutdown] or (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
        send.("ok", %{exit_code: 0, duration_ms: took.()})
        :erlang.raise(:exit, reason, __STACKTRACE__)

      kind, reason ->
        stacktrace = __STACKTRACE__
        send.("fail", %{exit_code: 1, duration_ms: took.()})
        error = if kind == :error, do: Exception.normalize(:error, reason, stacktrace), else: reason
        capture(error, stacktrace, handled: false, type: if(kind == :exit, do: "exit"))
        :erlang.raise(kind, reason, stacktrace)
    after
      cast(:flush)
    end
  end

  @doc "Sends an error: its type and stack, never its message."
  def capture(error, stacktrace, opts \\ []) do
    type = opts[:type] || if(is_exception(error), do: inspect(error.__struct__), else: "throw")
    cast({:error, type, stacktrace, Keyword.get(opts, :handled, true), Map.new(opts[:tags] || %{})})
  end

  @doc "How many lines were dropped: the queue was full, or they could not be sent."
  def dropped do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :dropped), else: 0
  catch
    :exit, _ -> 0
  end

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
  def log(%{level: level, msg: msg} = event, _config) do
    if GenServer.whereis(__MODULE__) == nil or from_sending?(event), do: throw(:skip)

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
  catch
    :skip -> :ok
  end

  # What the sender, the HTTP client and the TLS library log about our own requests is never fed back in.
  defp from_sending?(event) do
    meta = Map.get(event, :meta, %{})
    prefixes = ["httpc", "http_", "inets", "ssl", "tls_", "dtls_"]

    Process.get(:dokkit_sending) == true or meta[:pid] == Process.whereis(__MODULE__) or
      match?([:otp, d | _] when d in [:ssl, :inets], meta[:domain]) or
      match?({m, _, _} when is_atom(m), meta[:mfa]) and
        String.starts_with?(Atom.to_string(elem(meta[:mfa], 0)), prefixes)
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

    case encode(line) do
      body when is_binary(body) and byte_size(body) <= @max_line -> {:noreply, enqueue(s, body)}
      _ -> {:noreply, %{s | dropped: s.dropped + 1}}
    end
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

    case encode(report) do
      body when is_binary(body) and length(s.errors) < 100 -> {:noreply, %{s | errors: [body | s.errors]}}
      _ -> {:noreply, s}
    end
  rescue
    _ -> {:noreply, s}
  end

  def handle_cast(:flush, s), do: {:noreply, start_send(s)}

  @impl true
  def handle_call(:flush, from, s) do
    s = start_send(s)
    if s.sender == nil, do: {:reply, :ok, s}, else: {:noreply, %{s | waiters: [from | s.waiters]}}
  end

  def handle_call(:dropped, _from, s), do: {:reply, s.dropped, s}

  @impl true
  def handle_info(:tick, s), do: {:noreply, start_send(s)}

  def handle_info({:DOWN, ref, :process, _, reason}, %{sender: {_, ref, batches}} = s) do
    failed =
      case reason do
        {:sent, failed} -> failed
        _ -> Enum.map(batches, &{:failed, &1})
      end

    s = Enum.reduce(failed, %{s | sender: nil}, &retry_or_drop/2)
    s = if s.waiters != [] and (s.count > 0 or s.errors != []), do: start_send(s), else: s

    if s.sender == nil do
      Enum.each(s.waiters, &GenServer.reply(&1, :ok))
      {:noreply, %{s | waiters: []}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # A batch that failed is kept for one more try, then counted as dropped.
  # A refusal is counted at once, and so is an error post, which the server would count twice.
  defp retry_or_drop({:refused, batch}, s), do: %{s | dropped: s.dropped + batch.n}
  defp retry_or_drop({_, %{tried: true} = batch}, s), do: %{s | dropped: s.dropped + batch.n}
  defp retry_or_drop({_, %{path: "/api/v1/errors"} = batch}, s), do: %{s | dropped: s.dropped + batch.n}
  defp retry_or_drop({_, batch}, s), do: %{s | held: s.held ++ [%{batch | tried: true}]}

  # One that cannot be encoded is dropped.
  defp encode(term) do
    JSON.encode!(term)
  rescue
    _ -> nil
  end

  defp enqueue(s, body) do
    s = trim(s, byte_size(body))
    %{s | lines: :queue.in(body, s.lines), count: s.count + 1, bytes: s.bytes + byte_size(body)}
  end

  defp trim(s, size) do
    if s.count > 0 and (s.count >= @queue or s.bytes + size > @max_bytes) do
      {{:value, old}, rest} = :queue.out(s.lines)

      trim(
        %{s | lines: rest, count: s.count - 1, bytes: s.bytes - byte_size(old), dropped: s.dropped + 1},
        size
      )
    else
      s
    end
  end

  # Sending is done by another process, so the library never waits on the network.
  defp start_send(%{sender: nil} = s) do
    errors =
      for e <- Enum.reverse(s.errors), do: %{path: "/api/v1/errors", items: [e], n: 1, id: id(), tried: false}

    {reports, s} = take_reports(s, [])
    batches = s.held ++ errors ++ reports
    s = %{s | held: [], errors: []}

    if batches == [] do
      s
    else
      conf = %{url: s.url, key: s.key}

      {pid, ref} =
        spawn_monitor(fn ->
          Process.put(:dokkit_sending, true)
          exit({:sent, for(b <- batches, (r = post(conf, b)) != :ok, do: {r, b})})
        end)

      %{s | sender: {pid, ref, batches}}
    end
  end

  defp start_send(s), do: s

  defp take_reports(%{count: 0} = s, acc), do: {Enum.reverse(acc), s}

  defp take_reports(s, acc) do
    {items, s} = pull(s, [], 0)
    batch = %{path: "/api/v1/report", items: items, n: length(items), id: id(), tried: false}
    take_reports(s, [batch | acc])
  end

  defp pull(s, items, size) do
    case :queue.peek(s.lines) do
      {:value, line} when length(items) < 500 and (items == [] or size + byte_size(line) <= @max_batch) ->
        {_, rest} = :queue.out(s.lines)
        s = %{s | lines: rest, count: s.count - 1, bytes: s.bytes - byte_size(line)}
        pull(s, [line | items], size + byte_size(line))

      _ ->
        {Enum.reverse(items), s}
    end
  end

  # :ok, :refused (not tried again) or :failed (no answer, or a server error).
  defp post(conf, batch) do
    {kind, body, headers} =
      case batch.path do
        "/api/v1/errors" ->
          {"application/json", hd(batch.items), []}

        _ ->
          {"application/x-ndjson", :zlib.gzip(Enum.join(batch.items, "\n")),
           [{~c"content-encoding", ~c"gzip"}, {~c"dokkit-batch", to_charlist(batch.id)}]}
      end

    headers = [{~c"authorization", to_charlist("Bearer " <> conf.key)} | headers]
    request = {to_charlist(conf.url <> batch.path), headers, to_charlist(kind), body}

    case :httpc.request(:post, request, [timeout: 10_000] ++ ssl_options(conf.url), []) do
      {:ok, {{_, status, _}, _, _}} when status < 400 -> :ok
      {:ok, {{_, status, _}, _, _}} when status < 500 -> :refused
      _ -> :failed
    end
  catch
    _, _ -> :failed
  end

  @doc false
  def ssl_options(url) do
    if URI.parse(url).scheme == "https", do: https_options(), else: []
  end

  defp https_options do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end
end
