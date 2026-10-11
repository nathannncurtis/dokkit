defmodule DokkitWeb.SeqController do
  @moduledoc "The door for apps that log to Seq. See spec/log-lines.md."
  use DokkitWeb, :controller
  alias Dokkit.{Intake, Keys, RateLimit}

  @max_body 5 * 1024 * 1024
  @renamed %{"service" => "service_name", "type" => "seq_type", "at" => "seq_at"}

  def raw(conn, _params) do
    conn = fetch_query_params(conn)

    with {:ok, key} <- Keys.verify(api_key(conn), :app),
         {:ok, body, conn} <- read_body(conn, length: @max_body),
         {:ok, lines} <- lines(conn, body),
         :ok <- RateLimit.take(key.id, length(lines)),
         {:ok, %{accepted: accepted}} <- Intake.report(key, nil, encode(lines)) do
      if accepted == 0 and lines != [] do
        error(conn, 400, "No event could be stored.")
      else
        conn |> put_status(201) |> json(%{MinimumLevelAccepted: nil})
      end
    else
      :error ->
        error(conn, 401, "The API key is missing or not valid.")

      :bad ->
        error(conn, 400, "The body is not CLEF or Seq's JSON events.")

      {:wait, seconds} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> error(429, "Too many events from this key.")

      _ ->
        error(conn, 413, "A request is at most 5 MB and 10,000 events.")
    end
  end

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{Error: message})

  defp api_key(conn) do
    List.first(get_req_header(conn, "x-seq-apikey")) || conn.query_params["apiKey"] || ""
  end

  defp lines(conn, body) do
    clef? =
      Map.has_key?(conn.query_params, "clef") or conn.request_path == "/ingest/clef" or
        Enum.any?(get_req_header(conn, "content-type"), &String.contains?(&1, "serilog.clef"))

    with {:ok, events} <- events(body, clef?) do
      if Enum.all?(events, &is_map/1), do: {:ok, Enum.map(events, &line/1)}, else: :bad
    end
  end

  defp events(body, clef?) do
    case not clef? and Jason.decode(body) do
      {:ok, %{"Events" => list}} when is_list(list) -> {:ok, Enum.map(list, &raw_event/1)}
      _ -> ndjson(body)
    end
  end

  defp ndjson(body) do
    decoded =
      for text <- String.split(body, "\n", trim: true), text != "\r", do: Jason.decode(text)

    if Enum.all?(decoded, &match?({:ok, _}, &1)),
      do: {:ok, for({:ok, e} <- decoded, do: e)},
      else: :bad
  end

  defp raw_event(%{} = event) do
    props = (is_map(event["Properties"]) && event["Properties"]) || %{}

    base = %{
      "@t" => event["Timestamp"] || DateTime.to_iso8601(DateTime.utc_now()),
      "@l" => event["Level"],
      "@mt" => event["MessageTemplate"],
      "@m" => event["RenderedMessage"],
      "@x" => event["Exception"]
    }

    Map.merge(props, Map.reject(base, fn {_, v} -> is_nil(v) end))
  end

  defp raw_event(other), do: other

  defp line(event) do
    event
    |> Map.new(fn {k, v} -> {Map.get(@renamed, k, k), v} end)
    |> Map.put("type", "log")
  end

  defp encode(lines), do: Enum.map_join(lines, "\n", &Jason.encode!/1)
end
