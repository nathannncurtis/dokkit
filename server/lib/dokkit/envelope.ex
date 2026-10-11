defmodule Dokkit.Envelope do
  @moduledoc """
  Reads what Sentry's open-source SDKs send, written from the published protocol.
  Error events become reports in Dokkit's own format. Everything else is dropped.
  """

  @doc "The key named in the envelope's own header, if any, and the error reports inside."
  def read(text) do
    {head, rest} = line(text)

    key =
      with {:ok, %{"dsn" => dsn}} when is_binary(dsn) <- Jason.decode(head),
           %URI{userinfo: user} when is_binary(user) <- URI.parse(dsn) do
        user |> String.split(":") |> hd()
      else
        _ -> nil
      end

    reports =
      for {"event", payload} <- items(rest),
          {:ok, %{} = event} <- [Jason.decode(payload)],
          report = report(event),
          do: report

    {key, reports}
  end

  defp line(text) do
    case :binary.split(text, "\n") do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end

  # An item is a header line and a payload, which is either as long as the header says or one line.
  defp items(""), do: []

  defp items(text) do
    {head, rest} = line(text)

    case Jason.decode(head) do
      {:ok, %{"length" => n} = item} when is_integer(n) and n >= 0 and byte_size(rest) >= n ->
        <<payload::binary-size(^n), rest::binary>> = rest
        [{item["type"], payload} | items(String.replace_prefix(rest, "\n", ""))]

      {:ok, %{} = item} ->
        {payload, rest} = line(rest)
        [{item["type"], payload} | items(rest)]

      _ ->
        []
    end
  end

  defp report(event) do
    case event["exception"] do
      %{"values" => [_ | _] = values} -> report(event, List.last(values))
      [_ | _] = values -> report(event, List.last(values))
      _ -> nil
    end
  end

  defp report(event, %{} = exception) do
    frames =
      for %{} = f <- List.wrap(get_in(exception, ["stacktrace", "frames"])) do
        %{
          "file" => f["filename"] || f["module"] || f["abs_path"],
          "function" => f["function"],
          "line" => f["lineno"],
          "own" => f["in_app"] == true
        }
      end

    %{
      "type" => exception["type"] || "Error",
      "message" => exception["value"],
      "frames" => frames,
      "handled" => get_in(exception, ["mechanism", "handled"]) != false,
      "release" => event["release"],
      "environment" => event["environment"],
      "host" => event["server_name"],
      "tags" => tags(event["tags"]),
      "at" => at(event["timestamp"])
    }
  end

  defp report(_, _), do: nil

  defp tags(%{} = tags), do: tags

  defp tags(pairs) when is_list(pairs),
    do: for([k, v] <- pairs, is_binary(k), into: %{}, do: {k, v})

  defp tags(_), do: %{}

  defp at(seconds) when is_number(seconds) do
    case DateTime.from_unix(trunc(seconds * 1000), :millisecond) do
      {:ok, at} -> DateTime.to_iso8601(at)
      _ -> nil
    end
  end

  defp at(text), do: text
end
