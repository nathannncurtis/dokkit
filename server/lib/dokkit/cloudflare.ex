defmodule Dokkit.Cloudflare do
  @moduledoc "The one DNS record a certificate request needs: a TXT record at Cloudflare, shown to the world before it is used."
  require Logger

  @api "https://api.cloudflare.com/client/v4"
  @doh "https://cloudflare-dns.com/dns-query"

  def record_name(name), do: "_acme-challenge." <> name

  @doc "The name, then each parent domain, longest first, stopping before the top-level domain."
  def candidates(name) do
    labels = String.split(name, ".")
    for n <- 0..(length(labels) - 2)//1, do: labels |> Enum.drop(n) |> Enum.join(".")
  end

  @doc "Puts the TXT record in the name's zone. `{:ok, handle}` for `delete/2`."
  def add_txt(token, name, value) do
    with {:ok, zone} <- zone(token, name),
         {:ok, body} <-
           call(token, :post, "/zones/#{zone}/dns_records",
             json: %{type: "TXT", name: record_name(name), content: value, ttl: 60}
           ) do
      {:ok, %{zone: zone, id: get_in(body, ["result", "id"])}}
    end
  end

  def delete(token, %{zone: zone, id: id}) do
    case call(token, :delete, "/zones/#{zone}/dns_records/#{id}") do
      {:ok, _} -> :ok
      {:error, why} -> Logger.warning("The challenge record #{id} was not removed: #{why}")
    end
  end

  defp zone(token, name) do
    Enum.reduce_while(candidates(name), {:error, "Cloudflare has no zone for #{name}."}, fn z,
                                                                                            acc ->
      case call(token, :get, "/zones", params: [name: z]) do
        {:ok, %{"result" => [%{"id" => id} | _]}} -> {:halt, {:ok, id}}
        {:ok, _} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp call(token, method, path, opts \\ []) do
    request =
      [method: method, url: @api <> path, auth: {:bearer, token}] ++ http_options() ++ opts

    case Req.request(request) do
      {:ok, %{status: status, body: %{"success" => true} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"errors" => [%{"message" => message} | _]}}} ->
        {:error, "Cloudflare refused: #{message}"}

      {:ok, %{status: status}} ->
        {:error, "Cloudflare answered #{status}."}

      {:error, e} ->
        {:error, "Cloudflare could not be reached: #{String.slice(Exception.message(e), 0, 200)}"}
    end
  end

  @doc "Waits until Cloudflare's own resolver shows the TXT value, up to the configured tries."
  def wait(name, value) do
    {interval, tries} = Application.get_env(:dokkit, :acme_wait, {5_000, 24})
    wait(name, value, interval, tries)
  end

  defp wait(name, _value, _interval, 0),
    do: {:error, "The challenge record for #{name} did not show in DNS within two minutes."}

  defp wait(name, value, interval, tries) do
    if visible?(name, value) do
      :ok
    else
      Process.sleep(interval)
      wait(name, value, interval, tries - 1)
    end
  end

  # A resolver that caches would keep answering "no such name" from a look made too early,
  # so the zone's own name servers are asked. Only where they cannot be reached is a resolver used.
  defp visible?(name, value) do
    case Application.get_env(:dokkit, :acme_authoritative, true) && authoritative(name, value) do
      :yes -> true
      :no -> false
      _ -> resolver?(name, value)
    end
  end

  defp authoritative(name, value) do
    record = String.to_charlist(record_name(name))

    look = [timeout: 3_000] ++ resolvers()

    servers =
      for zone <- candidates(name),
          host <- :inet_res.lookup(String.to_charlist(zone), :in, :ns, look),
          ip <- :inet_res.lookup(host, :in, :a, look),
          do: {ip, 53}

    answers =
      for server <- Enum.take(servers, 2) do
        case :inet_res.resolve(record, :in, :txt,
               nameservers: [server],
               recurse: false,
               timeout: 3_000
             ) do
          {:ok, message} ->
            texts =
              for {:dns_rr, _, :txt, _, _, _, parts, _, _, _} <- :inet_dns.msg(message, :anlist),
                  do: IO.iodata_to_binary(parts)

            if value in texts, do: :yes, else: :no

          {:error, {:nxdomain, _}} ->
            :no

          {:error, :nxdomain} ->
            :no

          {:error, _} ->
            :unreachable
        end
      end

    cond do
      :yes in answers -> :yes
      :no in answers -> :no
      true -> :unreachable
    end
  end

  # Erlang on Windows reads no name servers from the system, so public ones find the zone's own.
  defp resolvers do
    if :inet_db.res_option(:nameservers) == [],
      do: [nameservers: [{{1, 1, 1, 1}, 53}, {{8, 8, 8, 8}, 53}]],
      else: []
  end

  defp resolver?(name, value) do
    request =
      [
        method: :get,
        url: @doh,
        params: [name: record_name(name), type: "TXT"],
        headers: [{"accept", "application/dns-json"}],
        decode_body: false
      ] ++ http_options()

    with {:ok, %{status: 200, body: body}} <- Req.request(request),
         {:ok, %{"Answer" => answers}} when is_list(answers) <- Jason.decode(body) do
      Enum.any?(answers, &(String.trim(&1["data"] || "", "\"") == value))
    else
      _ -> false
    end
  end

  defp http_options do
    [retry: false, redirect: false, receive_timeout: 15_000] ++
      Application.get_env(:dokkit, :req_options, [])
  end
end
