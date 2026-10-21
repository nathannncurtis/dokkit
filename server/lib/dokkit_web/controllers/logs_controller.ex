defmodule DokkitWeb.LogsController do
  @moduledoc "The Logs page's lines as a CSV file: every line its filter matches, newest first."
  use DokkitWeb, :controller
  alias Dokkit.Logs

  def csv(conn, params) do
    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="dokkit-logs.csv"))
      |> send_chunked(200)

    # The mark tells Excel the file is UTF-8.
    case chunk(conn, "\uFEFFtime,level,machine,service,message\r\n") do
      {:ok, conn} -> rows(conn, params)
      {:error, _} -> conn
    end
  end

  defp rows(conn, params) do
    try do
      params
      |> DokkitWeb.LogsLive.options()
      |> Keyword.delete(:order)
      |> Logs.stream()
      |> Stream.chunk_every(500)
      |> Enum.reduce_while(conn, fn lines, conn ->
        case chunk(conn, Enum.map(lines, &row/1)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    rescue
      e ->
        # The status line has already gone, so the file itself says it is incomplete.
        case chunk(conn, ",,,,EXPORT STOPPED EARLY: #{cell(Exception.message(e))}\r\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    end
  end

  defp row(l) do
    [DateTime.to_iso8601(l.at), l.level, l.machine.name, l.service && l.service.name, l.msg]
    |> Enum.map_join(",", &cell/1)
    |> Kernel.<>("\r\n")
  end

  defp cell(nil), do: ""

  defp cell(text) do
    # A spreadsheet runs a cell that starts with one of these as a formula.
    text =
      if String.starts_with?(text, ["=", "+", "-", "@", "\t", "\r"]), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\r", "\n"]),
      do: ~s(") <> String.replace(text, ~s("), ~s("")) <> ~s("),
      else: text
  end
end
