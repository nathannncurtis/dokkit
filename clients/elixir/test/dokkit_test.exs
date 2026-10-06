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
    assert Dokkit.dropped() == 1
  end

  test "the queue is bounded by bytes" do
    Dokkit.start(url: "http://127.0.0.1:1", key: "dka_test")
    for _ <- 1..12, do: Dokkit.log("info", String.duplicate("x", 900 * 1024))
    state = :sys.get_state(Dokkit)
    assert state.bytes <= 8 * 1024 * 1024 and state.dropped > 0
  end

  test "http to another machine keeps it off, and https checks the certificate" do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> Dokkit.start(url: "http://example.com", key: "k") end)
    assert GenServer.whereis(Dokkit) == nil
    assert [ssl: ssl] = Dokkit.ssl_options("https://example.com")
    assert ssl[:verify] == :verify_peer
    assert Dokkit.ssl_options("http://127.0.0.1") == []
  end
end
