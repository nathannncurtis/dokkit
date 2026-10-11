defmodule DokkitTest do
  use ExUnit.Case

  setup do
    stop()
    on_exit(&stop/0)
  end

  defp stop do
    if pid = GenServer.whereis(Dokkit), do: GenServer.stop(pid)
  end

  defp mock do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    spawn_link(fn -> serve(listen, test) end)
    "http://127.0.0.1:#{port}/"
  end

  defp received(acc) do
    receive do
      {:got, path, _, body} -> received([{path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A server that hands every request to the test and answers 200.
  defp serve(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, _, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    headers = headers(socket, %{})
    :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
    body = if headers["content-encoding"] == "gzip", do: :zlib.gunzip(body), else: body
    send(test, {:got, path, headers["authorization"], body})
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
    :gen_tcp.close(socket)
    serve(listen, test)
  end

  defp headers(socket, got) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(got, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        got
    end
  end

  test "everything is off until started, then sends" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    spawn_link(fn -> serve(listen, test) end)

    Dokkit.beat("ignored")
    Dokkit.start(version: "2.3.0", url: "http://127.0.0.1:#{port}/", key: "dka_test")
    Dokkit.beat("worker", 30)
    Dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old")
    Dokkit.log(%{level: :error, msg: {:string, "Upload failed"}}, %{})

    assert_raise ArgumentError, fn ->
      Dokkit.job("nightly-purge", fn progress ->
        progress.(4000, 9000)
        raise ArgumentError, "patient 4411"
      end)
    end

    Dokkit.flush()

    got =
      Stream.repeatedly(fn ->
        receive do
          {:got, path, auth, body} -> {path, auth, body}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert Enum.all?(got, fn {_, auth, _} -> auth == "Bearer dka_test" end)
    all = Enum.map_join(got, fn {_, _, body} -> body end)
    refute all =~ "4411"
    refute all =~ "ignored"

    lines =
      for {"/api/v1/report", _, body} <- got, l <- String.split(body, "\n"), do: JSON.decode!(l)

    assert Enum.map(lines, & &1["type"]) == ~w(deploy beat custom log job job job)
    assert Enum.at(lines, 1)["every_seconds"] == 30
    assert lines |> Enum.drop(4) |> Enum.map(& &1["event"]) == ~w(start progress fail)

    [error] = for {"/api/v1/errors", _, body} <- got, do: JSON.decode!(body)
    assert error["type"] == "ArgumentError"
    assert error["handled"] == false
    assert List.last(error["frames"])["own"]
  end

  test "a value that cannot be encoded is dropped and the library carries on" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    Dokkit.metric("x", self())
    Dokkit.log("info", <<255>>)
    Dokkit.capture(:oops, [], tags: %{"k" => %{}})
    Dokkit.beat("worker")
    state = :sys.get_state(Dokkit)
    assert state.count == 1 and state.dropped == 2 and state.errors == []
  end

  test "what the sender logs about our own requests is not queued, and an app's own TLS record is" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    window = :persistent_term.get({Dokkit, :window})
    :atomics.put(window, 1, System.monotonic_time(:millisecond) - 1)
    event = fn meta -> %{level: :notice, msg: {:string, "x"}, meta: meta} end
    count = fn -> :sys.get_state(Dokkit).count end

    # From the sender process, or carrying the library's own metadata: dropped, whatever the module.
    Task.async(fn -> Process.put(:dokkit_sending, true) && Dokkit.log(event.(%{}), %{}) end) |> Task.await()
    Dokkit.log(event.(%{domain: [:otp, :ssl, :handshake], dokkit: true}), %{})
    assert count.() == 0

    # The app's own failed handshake or HTTP call, from another process while nothing of ours is sending: kept.
    Dokkit.log(event.(%{domain: [:otp, :ssl, :handshake]}), %{})
    Dokkit.log(event.(%{mfa: {:httpc_handler, :init, 1}}), %{})
    Dokkit.log(event.(%{mfa: {:tls_connection, :init, 1}}), %{})
    assert count.() == 3

    # While a send of ours is running those modules are our own client's: dropped. Other records are not.
    :atomics.put(window, 1, System.monotonic_time(:millisecond) + 10_000)
    Dokkit.log(event.(%{domain: [:otp, :ssl, :handshake]}), %{})
    Dokkit.log(event.(%{mfa: {:httpc_handler, :init, 1}}), %{})
    assert count.() == 3
    Dokkit.log(event.(%{mfa: {MyApp, :run, 0}}), %{})
    assert count.() == 4
    :atomics.put(window, 1, System.monotonic_time(:millisecond) - 1)
  end

  test "a throw or an exit in a job is a failure" do
    Dokkit.start(url: mock(), key: "dka_test")
    assert catch_throw(Dokkit.job("t", fn _ -> throw(:oops) end)) == :oops
    assert catch_exit(Dokkit.job("e", fn _ -> exit(:bye) end)) == :bye
    Dokkit.flush()
    got = received([])
    assert Enum.count(got, fn {_, body} -> body =~ ~s("event":"fail") end) == 2
    assert for({"/api/v1/errors", body} <- got, do: JSON.decode!(body)["type"]) == ["throw", "exit"]
  end

  test "a failed batch is tried once more and then counted as dropped" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    Dokkit.beat("worker")
    Dokkit.flush()
    assert Dokkit.dropped() == 0
    Dokkit.flush()
    assert Dokkit.dropped() == 1, inspect(:sys.get_state(Dokkit))
  end

  test "the queue is bounded by bytes" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    for _ <- 1..200, do: Dokkit.log("info", String.duplicate("x", 60 * 1024))
    state = :sys.get_state(Dokkit)
    assert state.bytes <= 8 * 1024 * 1024 and state.dropped > 0
  end

  test "http to another machine keeps it off, and https checks the certificate" do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> Dokkit.start(url: "http://example.com", key: "k") end)
    assert GenServer.whereis(Dokkit) == nil
    assert [ssl: ssl] = Dokkit.ssl_options("https://example.com")
    assert ssl[:verify] == :verify_peer
    assert Dokkit.ssl_options("http://127.0.0.1") == []
    assert [ssl: _] = Dokkit.ssl_options("HTTPS://example.com")
  end

  test "a clean exit from a job is a success" do
    Dokkit.start(url: mock(), key: "dka_test")
    assert catch_exit(Dokkit.job("c", fn _ -> exit(:shutdown) end)) == :shutdown
    assert catch_exit(Dokkit.job("d", fn _ -> exit({:shutdown, 1}) end)) == {:shutdown, 1}
    Dokkit.flush()
    got = received([])
    assert Enum.count(got, fn {_, body} -> body =~ ~s("event":"ok") end) == 2
    assert for({"/api/v1/errors", _} <- got, do: 1) == []
  end

  # Answers every request with the status chosen for its path, and hands it to the test.
  defp status_server(statuses) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    spawn_link(fn -> serve_status(listen, test, statuses) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve_status(listen, test, statuses) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, _, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    headers = headers(socket, %{})
    :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
    body = if headers["content-encoding"] == "gzip", do: :zlib.gunzip(body), else: body
    send(test, {:got, path, headers["authorization"], body})
    status = Agent.get(statuses, & &1[path])
    :gen_tcp.send(socket, "HTTP/1.1 #{status} Status\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
    :gen_tcp.close(socket)
    serve_status(listen, test, statuses)
  end

  defp statuses(map), do: elem(Agent.start_link(fn -> map end), 1)

  defp error_posts(got), do: for({"/api/v1/errors", _} <- got, do: 1)

  test "a refused batch or error post is counted at once" do
    statuses = statuses(%{"/api/v1/report" => 401, "/api/v1/errors" => 400})
    Dokkit.start(url: status_server(statuses), key: "dka_test")
    Dokkit.beat("worker")
    Dokkit.flush()
    assert Dokkit.dropped() == 1

    Dokkit.capture(%RuntimeError{}, [])
    Dokkit.flush()
    assert Dokkit.dropped() == 2
    assert length(error_posts(received([]))) == 1
  end

  test "a failed error post is kept and tried again, and never stops the log lines" do
    for status <- [500, 429] do
      stop()
      statuses = statuses(%{"/api/v1/report" => 200, "/api/v1/errors" => status})
      Dokkit.start(url: status_server(statuses), key: "dka_test")
      Dokkit.capture(%RuntimeError{}, [])
      Dokkit.log("info", "beside the error")
      Dokkit.flush()
      got = received([])
      assert Enum.any?(got, fn {path, body} -> path == "/api/v1/report" and body =~ "beside the error" end)
      assert length(error_posts(got)) == 1
      assert Dokkit.dropped() == 0

      Agent.update(statuses, &Map.put(&1, "/api/v1/errors", 200))
      Dokkit.flush()
      assert length(error_posts(received([]))) == 1
      assert Dokkit.dropped() == 0
    end
  end

  test "an error post that fails twice is counted as dropped" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    Dokkit.capture(%RuntimeError{}, [])
    Dokkit.flush()
    assert Dokkit.dropped() == 0
    Dokkit.flush()
    assert Dokkit.dropped() == 1
  end

  test "a log line over 64 KB is cut with a marker" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    Dokkit.log("info", String.duplicate("é", 40_000))
    Dokkit.log("info", "x")
    [cut, small] = :sys.get_state(Dokkit).lines |> :queue.to_list()
    assert byte_size(cut) <= 65_536
    assert JSON.decode!(cut)["msg"] |> String.ends_with?(" [cut]")
    assert JSON.decode!(small)["msg"] == "x"
  end

  test "a start with announce_version false sends no deploy line" do
    Dokkit.start(version: "2.3.0", announce_version: false, url: "http://127.0.0.1:1", key: "dka_test")
    assert :sys.get_state(Dokkit).count == 0
  end

  test "an environment other than production is on every line" do
    for {env, want} <- [{"dev", "dev"}, {"production", nil}] do
      stop()
      Dokkit.start(url: mock(), key: "dka_test", environment: env)
      Dokkit.beat("b")
      Dokkit.log("info", "l")
      Dokkit.job("j", fn _ -> 1 end)
      Dokkit.flush()
      lines = for {"/api/v1/report", body} <- received([]), l <- String.split(body, "\n"), do: JSON.decode!(l)
      assert length(lines) == 4
      assert Enum.all?(lines, &(&1["environment"] == want))
    end
  end

  test "a stack path is relative to the app folder, and a file outside it is only a name" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    root = File.cwd!()

    Dokkit.capture(%RuntimeError{}, [
      {A, :a, 0, [file: String.to_charlist(Path.join(root, "lib/a.ex")), line: 1]},
      {B, :b, 0, [file: ~c"/opt/otp/lib/gen_server.erl", line: 2]},
      {C, :c, 0, [file: ~c"/home/u/app/deps/plug/lib/plug.ex", line: 3]},
      {D, :d, 0, [file: ~c"lib/d.ex", line: 4]}
    ])

    [report] = :sys.get_state(Dokkit).errors
    files = JSON.decode!(report)["frames"] |> Enum.map(& &1["file"]) |> Enum.reverse()
    assert files == ["lib/a.ex", "gen_server.erl", "deps/plug/lib/plug.ex", "lib/d.ex"]
  end

  test "a frame is the app's own unless it belongs to another app" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test", app: :mine)

    Dokkit.capture(%RuntimeError{}, [
      {Enum, :map, 2, [file: ~c"enum.ex", line: 1]},
      {DokkitTest, :x, 0, [file: ~c"x.ex", line: 2]}
    ])

    [report] = :sys.get_state(Dokkit).errors
    assert [%{"own" => true}, %{"own" => false}] = JSON.decode!(report)["frames"]
  end
end
