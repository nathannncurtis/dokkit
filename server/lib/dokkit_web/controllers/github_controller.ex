defmodule DokkitWeb.GithubController do
  @moduledoc "Receives GitHub webhook deliveries for security alerts. Nothing is read before the signature is checked."
  use DokkitWeb, :controller
  alias Dokkit.GithubAlerts

  @max_body 1024 * 1024

  def hook(conn, _params) do
    with {:ok, body, conn} <- read_body(conn, length: @max_body),
         true <- GithubAlerts.verify(body, header(conn, "x-hub-signature-256")),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      case GithubAlerts.handle(header(conn, "x-github-event"), payload) do
        :pong -> conn |> put_status(200) |> json(%{status: "pong"})
        {:error, _} -> conn |> put_status(502) |> json(%{status: "mail_failed"})
        status -> conn |> put_status(202) |> json(%{status: status})
      end
    else
      {:ok, _} ->
        conn |> put_status(400) |> json(%{error: "The body is not a JSON object."})

      {:error, %Jason.DecodeError{}} ->
        conn |> put_status(400) |> json(%{error: "The body is not JSON."})

      {:more, _, conn} ->
        conn |> put_status(413) |> json(%{error: "The body is too large."})

      _ ->
        conn |> put_status(401) |> json(%{error: "The signature is missing or not valid."})
    end
  end

  defp header(conn, name), do: List.first(get_req_header(conn, name)) || ""
end
