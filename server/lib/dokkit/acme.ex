defmodule Dokkit.Acme do
  @moduledoc """
  Keeps the uploaded certificate current by itself: an ACME v2 client (RFC 8555) that proves
  the name with a DNS record at Cloudflare. A certificate it obtains goes through the same
  checks and the same saving as an upload.
  """
  require Logger
  alias Dokkit.{Certificate, Cloudflare, Repo, Setting}

  @directory "https://acme-v02.api.letsencrypt.org/directory"
  @settings "certificate"
  @renewal "certificate_renewal"
  @renew_days 30
  @retry_hours 12
  @name ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  ## Settings

  def settings do
    (Repo.get(Setting, @settings) || %Setting{value: %{}}).value
  end

  def directory(s \\ settings()), do: filled(s["acme_directory"]) || @directory

  def view do
    s = settings()

    %{
      "acme_name" => s["acme_name"] || "",
      "acme_directory" => directory(s),
      "acme_cloudflare_token" =>
        if(filled(s["acme_cloudflare_token"]), do: "set", else: "not set")
    }
  end

  @doc "Saves the settings that are sent. A token that is not sent keeps its value; an empty one clears it."
  def save(params) do
    params = Map.take(params, ~w(acme_name acme_cloudflare_token acme_directory))
    name = params["acme_name"] && params["acme_name"] |> String.trim() |> String.downcase()
    dir = params["acme_directory"] && String.trim(params["acme_directory"])

    cond do
      Enum.any?(params, fn {_, v} -> not is_binary(v) end) ->
        {:error, "Every setting is text."}

      name not in [nil, ""] and not Regex.match?(@name, name) ->
        {:error, "acme_name is a DNS name such as example.dokkit.dev, without a wildcard."}

      dir not in [nil, ""] and match?({:error, _}, Dokkit.Alerts.check_url(dir)) ->
        {:error, "acme_directory must be an https address that is not this machine."}

      true ->
        new =
          Enum.reduce(params, settings(), fn
            {"acme_name", _}, acc -> Map.put(acc, "acme_name", name)
            {"acme_directory", _}, acc -> Map.put(acc, "acme_directory", dir)
            {k, v}, acc -> Map.put(acc, k, String.trim(v))
          end)

        put(@settings, new)
        {:ok, view()}
    end
  end

  defp put(key, value) do
    Repo.insert!(%Setting{key: key, value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  defp filled(text), do: if(is_binary(text) and String.trim(text) != "", do: String.trim(text))

  defp complete?(s),
    do: filled(s["acme_name"]) != nil and filled(s["acme_cloudflare_token"]) != nil

  ## The outcome of the last attempt

  def renewal do
    case Repo.get(Setting, @renewal) do
      %Setting{value: %{"at" => at} = v} -> %{at: at, ok: v["ok"], note: v["note"]}
      _ -> nil
    end
  end

  defp record(now, ok, note) do
    at = DateTime.to_iso8601(now)
    put(@renewal, %{"at" => at, "checked" => at, "ok" => ok, "note" => note})
    {if(ok, do: :ok, else: :error), note}
  end

  defp checked(now) do
    old = (Repo.get(Setting, @renewal) || %Setting{value: %{}}).value
    put(@renewal, Map.put(old, "checked", DateTime.to_iso8601(now)))
  end

  ## When it runs

  @doc "The daily check. Renews when it is time, and tries again no sooner than twelve hours after a failure."
  def tick(now) do
    s = settings()

    if complete?(s) and due_for_check?(now) do
      if wanted?(s, now), do: renew(now, false), else: checked(now)
    end

    :ok
  end

  defp due_for_check?(now) do
    last = (Repo.get(Setting, @renewal) || %Setting{value: %{}}).value

    case last["checked"] || last["at"] do
      nil -> true
      at -> hours_since(at, now) >= if(last["ok"] == false, do: @retry_hours, else: 24)
    end
  end

  defp hours_since(iso, now) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.diff(now, at) / 3600
  end

  defp wanted?(s, now) do
    covers = Certificate.covers?(Certificate.uploaded_names(), s["acme_name"])

    case Certificate.days_left(now) do
      nil -> true
      days -> not covers or days <= @renew_days
    end
  end

  ## Getting a certificate

  @doc "Gets a certificate now. `{:ok, note}` or `{:error, sentence}`; the outcome is kept."
  def renew(now \\ DateTime.utc_now(), report_busy \\ true) do
    s = settings()

    cond do
      not complete?(s) ->
        {:error, "Set acme_name and acme_cloudflare_token first."}

      not Certificate.serves_tls?() ->
        {:error, "This server does not serve TLS itself."}

      true ->
        try do
          Process.register(self(), __MODULE__.Running)

          try do
            case run(s) do
              {:ok, until} -> record(now, true, "Renewed, runs out #{until}")
              {:error, why} -> record(now, false, why)
            end
          after
            Process.unregister(__MODULE__.Running)
          end
        rescue
          ArgumentError ->
            if report_busy, do: {:error, "A renewal is already running."}, else: {:error, :busy}
        end
    end
  end

  defp run(s) do
    name = s["acme_name"]
    token = s["acme_cloudflare_token"]

    with {:ok, st} <- start(directory(s)),
         {:ok, st} <- account(st),
         {:ok, order, order_url, st} <- new_order(st, name),
         {:ok, st} <- authorize(st, order["authorizations"], name, token),
         key = :public_key.generate_key({:namedCurve, :secp256r1}),
         {:ok, order, st} <- finalize(st, order, order_url, csr(key, name)),
         {:ok, chain} <- download(st, order["certificate"]),
         {:ok, view} <- Certificate.put(chain, key_pem(key)) do
      {:ok, view.uploaded.not_after |> String.slice(0, 10)}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      _ -> {:error, "The certificate authority gave an answer that could not be used."}
    end
  rescue
    e ->
      Logger.error("Getting a certificate failed: " <> Exception.message(e))
      {:error, "Getting a certificate failed. The server log has the reason."}
  end

  defp key_pem(key),
    do:
      :public_key.pem_encode([
        {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key), :not_encrypted}
      ])

  ## The protocol

  defp start(url) do
    with {:ok, %{status: 200, body: body}} <- http(:get, url),
         {:ok, %{"newNonce" => _, "newAccount" => _, "newOrder" => _} = dir} <- Jason.decode(body),
         {:ok, key} <- account_key() do
      {:ok, %{dir: dir, nonce: nil, key: key, jwk: jwk(key), kid: nil}}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      _ -> {:error, "The certificate authority's directory could not be read."}
    end
  end

  defp account_key do
    path = Path.join(Certificate.dir(), "acme-account.pem")

    with {:ok, pem} <- File.read(path),
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      _ ->
        key = :public_key.generate_key({:namedCurve, :secp256r1})
        File.mkdir_p!(Certificate.dir())
        Certificate.write(path, key_pem(key))
        {:ok, key}
    end
  end

  defp account(st) do
    with {:ok, resp, st} <- post(st, st.dir["newAccount"], %{termsOfServiceAgreed: true}, :jwk) do
      {:ok, %{st | kid: location(resp)}}
    end
  end

  defp new_order(st, name) do
    with {:ok, resp, st} <-
           post(st, st.dir["newOrder"], %{identifiers: [%{type: "dns", value: name}]}) do
      {:ok, Jason.decode!(resp.body), location(resp), st}
    end
  end

  defp authorize(st, urls, name, token) do
    Enum.reduce_while(urls, {:ok, st}, fn url, {:ok, st} ->
      case prove(st, url, name, token) do
        {:ok, st} -> {:cont, {:ok, st}}
        error -> {:halt, error}
      end
    end)
  end

  defp prove(st, url, name, token) do
    with {:ok, resp, st} <- post(st, url, ""),
         authz = Jason.decode!(resp.body),
         {:ok, challenge} <- dns_challenge(authz) do
      if authz["status"] == "valid" do
        {:ok, st}
      else
        value = txt_value(challenge["token"], st.jwk)

        with {:ok, handle} <- Cloudflare.add_txt(token, name, value) do
          try do
            with :ok <- Cloudflare.wait(name, value),
                 {:ok, _, st} <- post(st, challenge["url"], %{}) do
              poll(st, url, ["valid"])
            end
          after
            Cloudflare.delete(token, handle)
          end
        end
      end
    end
  end

  defp dns_challenge(authz) do
    case Enum.find(authz["challenges"] || [], &(&1["type"] == "dns-01")) do
      nil -> {:error, "The certificate authority offered no DNS challenge."}
      challenge -> {:ok, challenge}
    end
  end

  defp finalize(st, order, order_url, csr) do
    with {:ok, resp, st} <- post(st, order["finalize"], %{csr: b64(csr)}),
         body = Jason.decode!(resp.body) do
      if body["status"] == "valid" and body["certificate"],
        do: {:ok, body, st},
        else: poll_order(st, order_url)
    end
  end

  defp poll_order(st, url) do
    with {:ok, st, body} <- poll(st, url, ["valid"], true) do
      if body["certificate"],
        do: {:ok, body, st},
        else: {:error, "The order finished without a certificate."}
    end
  end

  defp download(st, url) do
    with {:ok, resp, _} <-
           post(st, url, "", :kid, [{"accept", "application/pem-certificate-chain"}]) do
      {:ok, resp.body}
    end
  end

  defp poll(st, url, done, with_body \\ false) do
    {interval, tries} = Application.get_env(:dokkit, :acme_poll, {2_000, 30})
    poll(st, url, done, with_body, interval, tries)
  end

  defp poll(_, _, _, _, _, 0), do: {:error, "The certificate authority did not finish in time."}

  defp poll(st, url, done, with_body, interval, tries) do
    with {:ok, resp, st} <- post(st, url, "") do
      body = Jason.decode!(resp.body)

      cond do
        body["status"] in done ->
          if with_body, do: {:ok, st, body}, else: {:ok, st}

        body["status"] == "invalid" ->
          {:error, invalid(body)}

        true ->
          Process.sleep(interval)
          poll(st, url, done, with_body, interval, tries - 1)
      end
    end
  end

  defp invalid(body) do
    detail =
      get_in(body, ["error", "detail"]) ||
        Enum.find_value(body["challenges"] || [], &get_in(&1, ["error", "detail"]))

    "The certificate authority did not accept the challenge" <>
      if(detail, do: ": #{detail}", else: ".")
  end

  ## Signed requests

  defp post(st, url, payload, auth \\ :kid, headers \\ []) do
    post(st, url, payload, auth, headers, true)
  end

  defp post(st, url, payload, auth, headers, retry?) do
    with {:ok, st} <- nonce(st) do
      body = jws(st.key, %{url: url, nonce: st.nonce} |> Map.merge(identity(st, auth)), payload)
      st = %{st | nonce: nil}

      case http(:post, url,
             body: body,
             headers: [{"content-type", "application/jose+json"} | headers]
           ) do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          {:ok, resp, take_nonce(st, resp)}

        {:ok, resp} ->
          st = take_nonce(st, resp)

          if retry? and problem(resp)["type"] == "urn:ietf:params:acme:error:badNonce",
            do: post(st, url, payload, auth, headers, false),
            else: {:error, "The certificate authority refused: " <> detail(resp)}

        {:error, e} ->
          {:error, "The certificate authority could not be reached: #{String.slice(Exception.message(e), 0, 200)}"}
      end
    end
  end

  defp identity(st, :jwk), do: %{jwk: st.jwk}
  defp identity(st, :kid), do: %{kid: st.kid}

  defp nonce(%{nonce: nil} = st) do
    case http(:head, st.dir["newNonce"]) do
      {:ok, resp} ->
        case take_nonce(st, resp) do
          %{nonce: nil} -> {:error, "The certificate authority sent no nonce."}
          st -> {:ok, st}
        end

      {:error, e} ->
        {:error, "The certificate authority could not be reached: #{String.slice(Exception.message(e), 0, 200)}"}
    end
  end

  defp nonce(st), do: {:ok, st}

  defp take_nonce(st, resp),
    do: %{st | nonce: List.first(Req.Response.get_header(resp, "replay-nonce"))}

  defp location(resp), do: List.first(Req.Response.get_header(resp, "location"))

  defp problem(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp problem(_), do: %{}

  defp detail(resp), do: problem(resp)["detail"] || "answered #{resp.status}."

  defp http(method, url, opts \\ []) do
    Req.request(
      [
        method: method,
        url: url,
        decode_body: false,
        retry: false,
        redirect: false,
        receive_timeout: 30_000
      ] ++
        opts ++ Application.get_env(:dokkit, :req_options, [])
    )
  end

  ## JOSE

  @doc false
  def b64(data), do: Base.url_encode64(data, padding: false)

  @doc false
  def jwk({:ECPrivateKey, _, _, _, <<4, x::binary-32, y::binary-32>>, _}),
    do: %{"crv" => "P-256", "kty" => "EC", "x" => b64(x), "y" => b64(y)}

  @doc "RFC 7638: the SHA-256 of the key's required members, sorted by name, without spaces."
  def thumbprint(jwk) do
    json =
      jwk
      |> Enum.sort()
      |> Enum.map_join(",", fn {k, v} -> "#{Jason.encode!(k)}:#{Jason.encode!(v)}" end)

    b64(:crypto.hash(:sha256, "{" <> json <> "}"))
  end

  @doc "The value of the TXT record at _acme-challenge for a dns-01 challenge."
  def txt_value(token, jwk), do: b64(:crypto.hash(:sha256, token <> "." <> thumbprint(jwk)))

  @doc false
  def jws(key, header, payload) do
    protected = b64(Jason.encode!(Map.put(header, :alg, "ES256")))
    body = if payload == "", do: "", else: b64(Jason.encode!(payload))
    signing = protected <> "." <> body

    {:"ECDSA-Sig-Value", r, s} =
      :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(signing, :sha256, key))

    Jason.encode!(%{protected: protected, payload: body, signature: b64(<<r::256, s::256>>)})
  end

  ## The request for a certificate, written out by hand: a name in subjectAltName and nothing else

  @ec <<6, 7, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 2, 1>>
  @p256 <<6, 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 3, 1, 7>>
  @ecdsa_sha256 <<6, 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 4, 3, 2>>
  @extension_request <<6, 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 9, 14>>
  @subject_alt_name <<6, 3, 0x55, 0x1D, 0x11>>

  @doc false
  def csr({:ECPrivateKey, _, _, _, point, _} = key, name) do
    spki = der(0x30, der(0x30, @ec <> @p256) <> der(0x03, <<0>> <> point))
    names = der(0x30, der(0x82, name))
    extensions = der(0x30, der(0x30, @subject_alt_name <> der(0x04, names)))
    attributes = der(0xA0, der(0x30, @extension_request <> der(0x31, extensions)))
    info = der(0x30, <<2, 1, 0>> <> <<0x30, 0>> <> spki <> attributes)
    signature = :public_key.sign(info, :sha256, key)
    der(0x30, info <> der(0x30, @ecdsa_sha256) <> der(0x03, <<0>> <> signature))
  end

  defp der(tag, content), do: <<tag>> <> der_length(byte_size(content)) <> content
  defp der_length(n) when n < 128, do: <<n>>
  defp der_length(n) when n < 256, do: <<0x81, n>>
  defp der_length(n), do: <<0x82, n::16>>
end
