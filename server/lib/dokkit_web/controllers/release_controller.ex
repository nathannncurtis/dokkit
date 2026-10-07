defmodule DokkitWeb.ReleaseController do
  @moduledoc "The releases the server holds. People put them here; machines fetch them. See spec/updates.md."
  use DokkitWeb, :controller
  alias Dokkit.{Keys, Releases}

  @max 200 * 1024 * 1024
  @chunk 4 * 1024 * 1024

  plug :auth

  def show(conn, %{"version" => version, "file" => file}) do
    path = Releases.path(version, file)

    if path && File.regular?(path) do
      conn |> put_resp_content_type("application/octet-stream") |> send_file(200, path)
    else
      fail(conn, 404, "not_found", "No such thing.")
    end
  end

  def put(conn, %{"version" => version, "file" => file}) do
    if Releases.name?(version) and Releases.name?(file) do
      tmp = Releases.incoming()
      {:ok, io} = File.open(tmp, [:write, :binary, :raw])

      result = receive_body(conn, io, 0)
      File.close(io)

      case result do
        {:ok, conn} ->
          Releases.commit(tmp, version, file)
          json(conn, %{ok: true})

        {:error, conn, status, code, message} ->
          File.rm(tmp)
          fail(conn, status, code, message)
      end
    else
      bad_name(conn)
    end
  end

  def delete(conn, %{"version" => version}) do
    if Releases.name?(version) do
      if Releases.delete(version),
        do: json(conn, %{ok: true}),
        else: fail(conn, 404, "not_found", "No such thing.")
    else
      bad_name(conn)
    end
  end

  defp receive_body(conn, io, size) do
    case read_body(conn, length: @chunk) do
      {status, data, conn} when status in [:ok, :more] ->
        size = size + byte_size(data)

        if size > Application.get_env(:dokkit, :release_max, @max) do
          {:error, conn, 413, "too_large", "A release file is at most 200 MB."}
        else
          :ok = IO.binwrite(io, data)
          if status == :ok, do: {:ok, conn}, else: receive_body(conn, io, size)
        end

      _ ->
        {:error, conn, 400, "bad_body", "The body could not be read."}
    end
  end

  defp bad_name(conn),
    do:
      fail(conn, 422, "bad_name", "A name is letters, digits, dots, dashes and underscores only.")

  # A machine key fetches a file; everything else is a user token with the scope the call needs.
  defp auth(%{private: %{phoenix_action: :show}} = conn, _) do
    with ["Bearer " <> text] <- get_req_header(conn, "authorization"),
         {:ok, _} <- Keys.verify(text, :machine) do
      conn
    else
      _ -> conn |> fail(401, "bad_key", "Needs a machine key.") |> halt()
    end
  end

  defp auth(conn, _) do
    conn = DokkitWeb.ApiController.token(conn, [])

    if conn.halted do
      conn
    else
      scope = DokkitWeb.ApiController.needs(conn.method, conn.path_info)

      if scope in conn.assigns.key.scopes,
        do: conn,
        else: conn |> fail(403, "no_scope", "This token may not #{scope}.") |> halt()
    end
  end
end
