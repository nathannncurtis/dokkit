defmodule DokkitTest do
  use ExUnit.Case

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
end
