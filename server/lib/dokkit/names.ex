defmodule Dokkit.Names do
  @moduledoc "A name on dokkit.dev from the claim service, which writes its DNS records for this server."
  require Logger
  alias Dokkit.{Acme, Certificate, Setting}

  @setting "dokkit_name"
  @service "https://names.dokkit.dev"
  @code ~r/\A[a-z0-9]{8,64}\z/

  def service, do: Application.get_env(:dokkit, :names_service, @service)
  defp key_path, do: Path.join(Certificate.dir(), "dokkit-name.pem")

  def settings, do: Setting.get(@setting)

  def name, do: settings()["name"]

  def ours?(name), do: is_binary(name) and name != "" and name == name()

  def view do
    s = settings()

    %{
      "name" => s["name"] || "",
      "address" => s["address"] || "",
      "sent" => s["sent"],
      "ok" => s["ok"],
      "note" => s["note"]
    }
  end

  @doc "Registers a new key with a claim code; without a code, changes only the address."
  def claim(code, address) do
    code = code |> to_string() |> String.trim() |> String.downcase()
    address = address |> to_string() |> String.trim()

    cond do
      address != "" and not ipv4?(address) ->
        {:error,
         "The address is an IPv4 address such as 192.168.1.20, or blank for this machine's own."}

      code == "" and name() == nil ->
        {:error, "Paste the claim code from #{service()} first."}

      code == "" ->
        Setting.put(@setting, Map.merge(settings(), %{"address" => address, "sent" => nil}))
        push(DateTime.utc_now())

      not Regex.match?(@code, code) ->
        {:error, "A claim code is the letters and digits shown at #{service()}."}

      true ->
        register(code, address)
    end
  end

  defp register(code, address) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})

    case call("/v1/register", key, %{jwk: Acme.jwk(key)}, %{code: code}) do
      {:ok, %{"name" => name}} when is_binary(name) ->
        File.mkdir_p!(Certificate.dir())
        Certificate.write(key_path(), Acme.key_pem(key))
        Setting.put(@setting, %{"name" => name, "address" => address})
        {:ok, _} = Acme.save(%{"acme_name" => name})

        case push(DateTime.utc_now()) do
          {:ok, _} -> {:ok, "#{name} now points at this server."}
          {:error, why} -> {:error, "#{name} is claimed, but its address was not set: #{why}"}
        end

      {:ok, _} ->
        {:error, "The claim service gave an answer that could not be used."}

      error ->
        error
    end
  end

  # Sending the address is also the renewal that keeps the name from lapsing.
  @doc "Sends the address once a day, at once when it changes, and an hour after a failure."
  def tick(now) do
    s = settings()

    with name when is_binary(name) <- s["name"],
         addr when is_binary(addr) <- address(s) do
      due =
        case s["at"] do
          nil -> true
          at -> hours_since(at, now) >= if(s["ok"] == false, do: 1, else: 24)
        end

      if due or (s["ok"] != false and addr != s["sent"]), do: push(now)
    end

    :ok
  end

  defp hours_since(iso, now) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.diff(now, at) / 3600
  end

  defp address(s), do: if(s["address"] in [nil, ""], do: own_address(), else: s["address"])

  # Connecting a UDP socket picks the outgoing interface without sending anything.
  def own_address do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    try do
      with :ok <- :gen_udp.connect(socket, {192, 0, 2, 1}, 53),
           {:ok, {ip, _}} <- :inet.sockname(socket) do
        ip |> :inet.ntoa() |> to_string()
      else
        _ -> nil
      end
    after
      :gen_udp.close(socket)
    end
  end

  defp push(now) do
    s = settings()
    addr = address(s)

    result =
      if addr,
        do: signed("/v1/address", %{a: addr}),
        else: {:error, "This machine has no IPv4 address to send."}

    note =
      case result do
        {:ok, _} -> "#{s["name"]} points at #{addr}"
        {:error, why} -> why
      end

    Setting.put(
      @setting,
      Map.merge(s, %{
        "at" => DateTime.to_iso8601(now),
        "sent" => if(match?({:ok, _}, result), do: addr, else: s["sent"]),
        "ok" => match?({:ok, _}, result),
        "note" => note
      })
    )

    if match?({:ok, _}, result), do: {:ok, note}, else: {:error, note}
  end

  defp ipv4?(text), do: match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(text)))

  def add_txt(_token, _name, value) do
    with {:ok, _} <- signed("/v1/txt", %{value: value}), do: {:ok, :names}
  end

  def delete(_token, _handle) do
    case signed("/v1/txt/clear", %{}) do
      {:ok, _} -> :ok
      {:error, why} -> Logger.warning("The challenge record was not removed: #{why}")
    end
  end

  defp signed(path, payload) do
    with {:ok, pem} <- File.read(key_path()),
         [entry | _] <- :public_key.pem_decode(pem) do
      call(path, :public_key.pem_entry_decode(entry), %{kid: name()}, payload)
    else
      _ -> {:error, "This server holds no key for its name. Paste a new claim code."}
    end
  end

  defp call(path, key, identity, payload) do
    url = service() <> path
    header = Map.merge(identity, %{url: url, iat: System.os_time(:second)})

    request =
      [
        method: :post,
        url: url,
        body: Acme.jws(key, header, payload),
        headers: [{"content-type", "application/jose+json"}],
        retry: false,
        redirect: false,
        receive_timeout: 30_000
      ] ++ Application.get_env(:dokkit, :req_options, [])

    case Req.request(request) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{body: %{"error" => why}}} when is_binary(why) ->
        {:error, "The claim service refused: " <> String.slice(why, 0, 300)}

      {:ok, %{status: status}} ->
        {:error, "The claim service answered #{status}."}

      {:error, e} ->
        {:error,
         "The claim service could not be reached: #{String.slice(Exception.message(e), 0, 200)}"}
    end
  end
end
