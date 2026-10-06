defmodule DokkitWeb.IntakeController do
  use DokkitWeb, :controller
  alias Dokkit.{Intake, Keys}

  @max_body 5 * 1024 * 1024
  @max_plain 100 * 1024 * 1024

  # Keeps the raw body for the ping URLs, whatever content type the caller sent.
  def read_body(conn, opts) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, opts) do
      {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}
    end
  end

  def report(conn, _params) do
    with {:ok, key} <- bearer(conn),
         {:ok, body, conn} <- body(conn),
         {:ok, text} <- plain(conn, body),
         {:ok, batch} <- batch(conn),
         {:ok, answer} <- Intake.report(key, batch, text) do
      json(conn, answer)
    else
      :unauthorized -> fail(conn, 401, "bad_key", "Missing or bad key.")
      :bad_batch -> fail(conn, 422, "bad_batch", "Dokkit-Batch must be a UUID.")
      _ -> fail(conn, 413, "too_large", "A batch is at most 5 MB compressed and 10,000 lines.")
    end
  end

  def ping(conn, %{"key" => text, "name" => name, "event" => event} = params)
      when event in ~w(start ok fail) do
    with {:ok, key} <- Keys.verify(text, :app), {:ok, tail, conn} <- body(conn) do
      Intake.ping(key, name, event, params["run"], tail)
      json(conn, %{ok: true})
    else
      :error -> fail(conn, 401, "bad_key", "Missing or bad key.")
      _ -> fail(conn, 413, "too_large", "Too large.")
    end
  end

  def ping(conn, _), do: fail(conn, 404, "not_found", "No such address.")

  defp bearer(conn) do
    with ["Bearer " <> text] <- get_req_header(conn, "authorization"),
         {:ok, key} <- Keys.verify(text, [:machine, :app]) do
      {:ok, key}
    else
      _ -> :unauthorized
    end
  end

  defp body(%{private: %{raw_body: body}} = conn), do: {:ok, body, conn}

  defp body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} -> {:ok, body, conn}
      _ -> :too_large
    end
  end

  defp plain(conn, body) do
    if get_req_header(conn, "content-encoding") == ["gzip"], do: gunzip(body), else: {:ok, body}
  end

  defp gunzip(body) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, body), [], 0)
    rescue
      _ -> :bad_gzip
    after
      :zlib.close(z)
    end
  end

  defp inflate(_, _, _, size) when size > @max_plain, do: :too_large
  defp inflate(_, {:finished, out}, acc, _), do: {:ok, IO.iodata_to_binary([acc, out])}

  defp inflate(z, {:continue, out}, acc, size),
    do: inflate(z, :zlib.safeInflate(z, []), [acc, out], size + IO.iodata_length(out))

  defp batch(conn) do
    case get_req_header(conn, "dokkit-batch") do
      [] -> {:ok, nil}
      [id] -> with :error <- Ecto.UUID.cast(id), do: :bad_batch
      _ -> :bad_batch
    end
  end

  defp fail(conn, status, code, message) do
    conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
  end
end
