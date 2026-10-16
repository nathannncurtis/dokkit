defmodule DokkitWeb.AddController do
  @moduledoc "Hands out the add-a-machine script for `irm <server>/add/<token> | iex`, while its enrolment token is unused."
  use DokkitWeb, :controller

  def show(conn, %{"token" => token}) do
    with {:ok, %{used_at: nil} = key} <- Dokkit.Keys.verify(token, :enrol),
         {:ok, _file, text} <-
           Dokkit.AddScript.windows(key.label || "machine", token, key.expires_at) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, text)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          404,
          "This link is used, revoked or out of date. Make a new one on the Add a machine page.\n"
        )
    end
  end
end
