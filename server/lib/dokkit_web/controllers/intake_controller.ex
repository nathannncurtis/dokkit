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
      :bad_gzip -> fail(conn, 422, "bad_gzip", "The body is not valid gzip.")
      _ -> fail(conn, 413, "too_large", "A batch is at most 5 MB compressed and 10,000 lines.")
    end
  end

  def enrol(conn, %{"token" => token} = params) when is_binary(token) do
    case Intake.enrol(token, params) do
      {:ok, answer} ->
        Dokkit.Issues.changed(false)
        json(conn, answer)

      {:error, :taken} ->
        fail(
          conn,
          409,
          "already_enrolled",
          "That machine name is already enrolled. Ask for an enrolment token made for that machine."
        )

      _ ->
        fail(conn, 401, "bad_token", "That token is not known, was already used, or has run out.")
    end
  end

  def enrol(conn, _), do: fail(conn, 422, "bad_body", "Needs a token and a hostname.")

  def declare(conn, params) do
    with {:ok, key} <- bearer(conn),
         {:ok, owner} <- owner(key),
         {:ok, service} <- Dokkit.Estate.declare(owner, Map.drop(params, ["_format"])) do
      Dokkit.Issues.changed(false)
      json(conn, %{service: service.id})
    else
      :forbidden -> fail(conn, 403, "not_allowed", "This key belongs to no service.")
      {:error, message} when is_binary(message) -> fail(conn, 422, "bad_declaration", message)
      _ -> fail(conn, 401, "bad_key", "Missing or bad key.")
    end
  end

  defp owner(%{kind: :machine, machine_id: id}), do: {:ok, id}
  defp owner(%{service_id: nil}), do: :forbidden
  defp owner(%{service_id: id}), do: {:ok, Dokkit.Repo.get!(Dokkit.Service, id)}

  @doc "Holds the request until there is a run for this machine, or the wait runs out."
  def work(conn, params) do
    with {:ok, machine} <- machine(conn) do
      wait =
        case Integer.parse(params["wait"] || "") do
          {seconds, ""} when seconds in 0..50 -> seconds
          _ -> 50
        end

      case Dokkit.Work.take(machine, wait * 1000) do
        nil ->
          send_resp(conn, 204, "")

        run ->
          json(
            conn,
            Map.merge(
              %{run: run.id, task: run.name},
              Dokkit.Work.extras(run)
            )
          )
      end
    end
  end

  def work_output(conn, %{"run" => run}) do
    with {:ok, machine} <- machine(conn),
         {:ok, run} <- Ecto.UUID.cast(run),
         {:ok, chunk, conn} <- body(conn),
         :ok <- Dokkit.Work.output(machine, run, chunk) do
      json(conn, %{ok: true})
    else
      %Plug.Conn{} = conn -> conn
      _ -> fail(conn, 404, "not_found", "This machine is not running that.")
    end
  end

  def work_result(conn, %{"run" => run} = params) do
    with {:ok, machine} <- machine(conn),
         {:ok, run} <- Ecto.UUID.cast(run),
         :ok <- Dokkit.Work.result(machine, run, params) do
      json(conn, %{ok: true})
    else
      %Plug.Conn{} = conn -> conn
      _ -> fail(conn, 404, "not_found", "This machine is not running that.")
    end
  end

  def deploy(conn, params) do
    with {:ok, key} <- bearer(conn),
         :ok <- Intake.deploy(key, params) do
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

  @doc "The door for Sentry's SDKs."
  def envelope(conn, params) do
    with {:ok, body, conn} <- body(conn),
         {:ok, key} <- Keys.verify(sentry_key(conn, params) || head_key(conn, body) || "", :app),
         {:ok, text} <- plain(conn, body),
         {_, reports} = Dokkit.Envelope.read(text) do
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
      :bad_gzip -> fail(conn, 422, "bad_gzip", "The body is not valid gzip.")
      _ -> fail(conn, 413, "too_large", "Too large.")
    end
  end

  # The key named in the envelope's first line, read from the first stretch of a gzip body only.
  defp head_key(conn, body) do
    z = :zlib.open()

    try do
      text =
        if get_req_header(conn, "content-encoding") == ["gzip"] do
          :zlib.inflateInit(z, 31)
          {_, out} = :zlib.safeInflate(z, body)
          IO.iodata_to_binary(out)
        else
          body
        end

      text |> :binary.split("\n") |> hd() |> Dokkit.Envelope.read() |> elem(0)
    rescue
      _ -> nil
    after
      :zlib.close(z)
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

  @doc "A machine says it is going down on purpose for a while, or that the wait is over."
  def quiet(conn, params) do
    with {:ok, machine} <- machine(conn) do
      case Dokkit.Quiet.start(machine, params, "machine") do
        {:ok, window} ->
          json(conn, %{ok: true, until: window && window.until})

        {:error, code, message} ->
          fail(conn, 422, code, message)
      end
    end
  end

  @doc "The checks added in the interface, for the program on that machine to run."
  def checks(conn, _params) do
    with {:ok, machine} <- machine(conn),
         do:
           json(conn, %{
             items: Dokkit.Found.checks(machine),
             settings: Dokkit.Values.for_program(machine)
           })
  end

  @doc "The found jobs whose runs the program reads from the machine's own record."
  def records(conn, _params) do
    with {:ok, machine} <- machine(conn), do: json(conn, %{items: Dokkit.Found.records(machine)})
  end

  @doc "The newer program, for a machine asked to fetch it."
  def program(conn, %{"target" => target}) do
    with {:ok, _machine} <- machine(conn) do
      case Dokkit.Work.program(target) do
        nil ->
          fail(conn, 404, "not_found", "This server holds no program for that kind of machine.")

        path ->
          send_file(conn, 200, path)
      end
    end
  end

  @doc "What the updater on a machine reports, and the version it should move to, if any."
  def update(conn, params) do
    with {:ok, machine} <- machine(conn) do
      case Dokkit.Releases.ask(machine, params) do
        nil ->
          send_resp(conn, 204, "")

        version ->
          json(conn, %{version: version, limit_seconds: Dokkit.Values.get("updater_minutes") * 60})
      end
    end
  end

  def update_result(conn, params) do
    with {:ok, machine} <- machine(conn) do
      case Dokkit.Releases.result(machine, params) do
        :ok ->
          json(conn, %{ok: true})

        :error ->
          fail(conn, 422, "bad_result", "Needs version, ok and at most 2000 characters of note.")
      end
    end
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
    with {:ok, key} <- Keys.verify(text, :app),
         {:ok, tail, conn} <- body(conn) do
      case Intake.ping(key, name, event, params["run"], tail) do
        {:error, code, message} -> fail(conn, 422, code, message)
        _ -> json(conn, %{ok: true})
      end
    else
      :error -> fail(conn, 401, "bad_key", "Missing or bad key.")
      _ -> fail(conn, 413, "too_large", "Too large.")
    end
  end

  def ping(conn, _), do: fail(conn, 404, "not_found", "No such address.")

  # Its own name so a GET is never mistaken for the POST by CSRF checks; the key in the path is the only credential.
  def ping_get(conn, params), do: ping(conn, params)

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
