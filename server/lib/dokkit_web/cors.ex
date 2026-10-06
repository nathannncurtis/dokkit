defmodule DokkitWeb.Cors do
  @moduledoc "Lets a browser page call the write-only app key endpoints from any origin."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, content-encoding, dokkit-batch"
      )
      |> put_resp_header("access-control-max-age", "86400")

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end
end
