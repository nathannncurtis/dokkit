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

  def enrol(conn, %{"token" => token} = params) when is_binary(token) do
    case Intake.enrol(token, params) do
      {:ok, answer} ->
        Dokkit.Issues.changed(false)
        json(conn, answer)

      _ ->
        fail(conn, 401, "bad_token", "That token is not known, was already used, or has run out.")
    end
  end

  def enrol(conn, _), do: fail(conn, 422, "bad_body", "Needs a token and a hostname.")

  def declare(conn, params) do
    with {:ok, %{kind: :machine, machine_id: machine}} <- bearer(conn),
         {:ok, service} <- Dokkit.Estate.declare(machine, Map.drop(params, ["_format"])) do
      Dokkit.Issues.changed(false)
      json(conn, %{service: service.id})
    else
      {:error, message} when is_binary(message) -> fail(conn, 422, "bad_declaration", message)
      {:ok, _} -> fail(conn, 403, "not_allowed", "A declaration needs a machine key.")
      _ -> fail(conn, 401, "bad_key", "Missing or bad key.")
    end
  end

  @doc "Holds the request until there is a task run for this machine, or the wait runs out."
  def work(conn, params) do
    with {:ok, machine} <- machine(conn) do
      wait =
        case Integer.parse(params["wait"] || "") do
          {seconds, ""} when seconds in 0..50 -> seconds
          _ -> 50
        end

      case Dokkit.Tasks.take(machine, wait * 1000) do
        nil ->
          send_resp(conn, 204, "")

        run ->
          json(conn, %{
            run: run.id,
            task: run.task.name,
            command_sha256: Dokkit.Tasks.sha256(run.task.command)
          })
      end
    end
  end

  def work_output(conn, %{"run" => run}) do
    with {:ok, machine} <- machine(conn),
         {:ok, run} <- Ecto.UUID.cast(run),
         {:ok, chunk, conn} <- body(conn),
         :ok <- Dokkit.Tasks.output(machine, run, chunk) do
      json(conn, %{ok: true})
    else
      %Plug.Conn{} = conn -> conn
      _ -> fail(conn, 404, "not_found", "This machine is not running that.")
    end
  end

  def work_result(conn, %{"run" => run} = params) do
    with {:ok, machine} <- machine(conn),
         {:ok, run} <- Ecto.UUID.cast(run),
         :ok <- Dokkit.Tasks.result(machine, run, params) do
      json(conn, %{ok: true})
    else
      %Plug.Conn{} = conn -> conn
      _ -> fail(conn, 404, "not_found", "This machine is not running that.")
    end
  end

  def deploy(conn, params) do
    with {:ok, key} <- bearer(conn), :ok <- Intake.deploy(key, params) do
      Dokkit.Issues.changed(false)
      json(conn, %{ok: true})
    else
      {:error, code, message} -> fail(conn, 422, code, message)
      _ -> fail(conn, 401, "bad_key", "Missing or bad key.")
    end
  end

  def error(conn, params) do
    with {:ok, key} <- bearer(conn), :ok <- Intake.error(key, params) do
      json(conn, %{ok: true})
    else
      {:error, code, message} -> fail(conn, 422, code, message)
      _ -> fail(conn, 401, "bad_key", "Missing or bad key.")
    end
  end

  @doc "The door for Sentry's SDKs. See spec/errors.md."
  def envelope(conn, params) do
    with {:ok, body, conn} <- body(conn),
         {:ok, text} <- plain(conn, body),
         {named, reports} = Dokkit.Envelope.read(text),
         {:ok, key} <- Keys.verify(sentry_key(conn, params) || named || "", :app) do
      for report <- reports, do: Intake.error(key, report)

      conn
      # Tells the SDK to keep the kinds Dokkit drops to itself for a day.
      |> put_resp_header(
        "x-sentry-rate-limits",
        "86400:transaction;span;session;attachment;profile;replay;monitor;feedback:organization"
      )
      |> json(%{})
    else
      :error -> fail(conn, 401, "bad_key", "Missing or bad key.")
      _ -> fail(conn, 413, "too_large", "Too large, or not readable.")
    end
  end

  defp sentry_key(conn, params) do
    auth = conn |> get_req_header("x-sentry-auth") |> List.first() || ""

    case Regex.run(~r/sentry_key=([^,\s]+)/, auth) do
      [_, key] -> key
      _ -> params["sentry_key"]
    end
  end

  def propose(conn, params) do
    with {:ok, machine} <- machine(conn),
         {:ok, kept} <- Dokkit.Found.propose(machine, params) do
      json(conn, %{waiting: kept})
    else
      %Plug.Conn{} = conn -> conn
      _ -> fail(conn, 422, "bad_proposal", "Needs what dokkit scan wrote.")
    end
  end

  @doc "The checks added in the interface, for the program on that machine to run."
  def checks(conn, _params) do
    with {:ok, machine} <- machine(conn), do: json(conn, %{items: Dokkit.Found.checks(machine)})
  end

  @doc "The tasks accepted for this machine, so `dokkit task list` can say which they are."
  def accepted(conn, _params) do
    with {:ok, machine} <- machine(conn),
         do: json(conn, %{items: Dokkit.Tasks.accepted_for(machine)})
  end

  defp machine(conn) do
    case bearer(conn) do
      {:ok, %{kind: :machine, machine_id: machine}} -> {:ok, machine}
      _ -> fail(conn, 401, "bad_key", "Needs a machine key.")
    end
  end

  @doc "Lets a machine check its address, its key and its clock."
  def hello(conn, _params) do
    case bearer(conn) do
      {:ok, _} -> json(conn, %{ok: true, time: DateTime.utc_now()})
      _ -> fail(conn, 401, "bad_key", "Missing or bad key.")
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
end
