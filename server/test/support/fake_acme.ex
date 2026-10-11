defmodule Dokkit.FakeAcme do
  @moduledoc """
  An ACME server, Cloudflare's API and Cloudflare's DNS-over-HTTPS in one Req.Test stub. It
  checks every signed request, issues a real certificate for the request's key from a
  throwaway root, and sends {:call, ...} messages to the test for what happened.
  """
  import Plug.Conn

  @host "acme.test"

  def directory, do: "https://#{@host}/directory"

  def start(test, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{nonces: MapSet.new(), jwks: %{}, txt: nil, authz: :pending, posts: 0}
      end)

    ca_key = :public_key.generate_key({:rsa, 2048, 65537})

    root =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [
            key: ca_key,
            digest: :sha256,
            extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"fake-ca.test"]}]
          ],
          peer: []
        },
        client_chain: %{root: [], peer: []}
      }).server_config[:cacerts]
      |> Enum.find(&(:binary.match(&1, "fake-ca.test") != :nomatch))

    state = %{agent: agent, test: test, ca_key: ca_key, root: root, mode: opts[:mode] || :ok}
    Req.Test.stub(Dokkit.Alerts, &handle(&1, state))
    state
  end

  defp call(state, what), do: send(state.test, {:call, what})

  defp handle(conn, state) do
    {:ok, body, conn} = read_body(conn)
    route(conn.method, conn.host, conn.request_path, conn.query_string, body, conn, state)
  end

  ## Cloudflare

  defp route("GET", "api.cloudflare.com", "/client/v4/zones", query, _, conn, state) do
    %{"name" => zone} = URI.decode_query(query)
    call(state, {:zone, zone})
    result = if zone == "dokkit.dev", do: [%{id: "zone1"}], else: []
    cf(conn, 200, %{success: true, result: result})
  end

  defp route(
         "POST",
         "api.cloudflare.com",
         "/client/v4/zones/zone1/dns_records",
         _,
         body,
         conn,
         state
       ) do
    if state.mode == :cloudflare_refuses do
      cf(conn, 403, %{success: false, errors: [%{message: "Authentication error"}]})
    else
      record = Jason.decode!(body)
      call(state, {:txt_created, record["name"], record["content"], record["ttl"]})
      Agent.update(state.agent, &%{&1 | txt: record["content"]})
      cf(conn, 200, %{success: true, result: %{id: "rec1"}})
    end
  end

  defp route(
         "DELETE",
         "api.cloudflare.com",
         "/client/v4/zones/zone1/dns_records/rec1",
         _,
         _,
         conn,
         state
       ) do
    call(state, :txt_deleted)
    Agent.update(state.agent, &%{&1 | txt: nil})
    cf(conn, 200, %{success: true, result: %{id: "rec1"}})
  end

  defp route("GET", "cloudflare-dns.com", "/dns-query", _, _, conn, state) do
    txt = Agent.get(state.agent, & &1.txt)
    visible = txt && state.mode != :never_visible
    answer = if visible, do: %{"Answer" => [%{"data" => "\"#{txt}\""}]}, else: %{"Status" => 0}

    conn
    |> put_resp_content_type("application/dns-json")
    |> send_resp(200, Jason.encode!(answer))
  end

  defp route("GET", @host, "/directory", _, _, conn, _) do
    json(conn, 200, %{
      newNonce: "https://#{@host}/nonce",
      newAccount: "https://#{@host}/acct",
      newOrder: "https://#{@host}/order"
    })
  end

  defp route("HEAD", @host, "/nonce", _, _, conn, state), do: reply(conn, state, 200, nil)

  defp route("POST", @host, path, _, body, conn, state) do
    url = "https://#{@host}#{path}"
    n = Agent.get_and_update(state.agent, &{&1.posts + 1, %{&1 | posts: &1.posts + 1}})
    call(state, {:post, path})

    cond do
      state.mode == :bad_nonce_once and n == 1 ->
        reply(conn, state, 400, %{
          type: "urn:ietf:params:acme:error:badNonce",
          detail: "Stale nonce."
        })

      true ->
        case verify(body, url, state) do
          :ok ->
            post(path, body, conn, state)

          {:error, why} ->
            reply(conn, state, 400, %{type: "urn:ietf:params:acme:error:malformed", detail: why})
        end
    end
  end

  ## ACME

  defp post("/acct", _, conn, state),
    do: reply(conn, state, 201, %{status: "valid"}, [{"location", "https://#{@host}/acct/1"}])

  defp post("/order", _, conn, state) do
    reply(
      conn,
      state,
      201,
      %{
        status: "pending",
        authorizations: ["https://#{@host}/authz/1"],
        finalize: "https://#{@host}/finalize/1"
      },
      [{"location", "https://#{@host}/order/1"}]
    )
  end

  defp post("/authz/1", _, conn, state) do
    status = Agent.get(state.agent, & &1.authz)

    challenge = %{
      type: "dns-01",
      url: "https://#{@host}/chall/1",
      token: "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA",
      status: to_string(status)
    }

    challenge =
      if status == :invalid,
        do:
          Map.put(challenge, :error, %{
            detail: "Incorrect TXT record found at _acme-challenge.example.dokkit.dev"
          }),
        else: challenge

    reply(conn, state, 200, %{status: to_string(status), challenges: [challenge]})
  end

  defp post("/chall/1", _, conn, state) do
    outcome = if state.mode == :invalid, do: :invalid, else: :valid
    Agent.update(state.agent, &%{&1 | authz: outcome})
    reply(conn, state, 200, %{status: "processing"})
  end

  defp post("/finalize/1", body, conn, state) do
    %{"payload" => payload} = Jason.decode!(body)
    %{"csr" => csr} = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    csr = Base.url_decode64!(csr, padding: false)
    call(state, {:csr, csr})
    Agent.update(state.agent, &Map.put(&1, :issued, issue(state, csr)))
    reply(conn, state, 200, %{status: "processing"})
  end

  defp post("/order/1", _, conn, state) do
    reply(conn, state, 200, %{status: "valid", certificate: "https://#{@host}/cert/1"})
  end

  defp post("/cert/1", _, conn, state) do
    pem = Agent.get(state.agent, & &1.issued)

    conn
    |> put_resp_header("replay-nonce", nonce(state))
    |> put_resp_content_type("application/pem-certificate-chain")
    |> send_resp(200, pem)
  end

  defp cf(conn, status, map) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))
  end

  defp json(conn, status, map),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))

  defp reply(conn, state, status, map, headers \\ []) do
    conn = put_resp_header(conn, "replay-nonce", nonce(state))
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

    if map,
      do:
        conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map)),
      else: send_resp(conn, status, "")
  end

  defp nonce(state) do
    n = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Agent.update(state.agent, &%{&1 | nonces: MapSet.put(&1.nonces, n)})
    n
  end

  ## Checking what the client signed

  defp verify(body, url, state) do
    with {:ok, %{"protected" => p, "payload" => payload, "signature" => sig}} <-
           Jason.decode(body),
         {:ok, header} <- p |> Base.url_decode64!(padding: false) |> Jason.decode(),
         true <- header["alg"] == "ES256" or {:error, "alg"},
         true <- header["url"] == url or {:error, "url"},
         true <-
           Agent.get_and_update(state.agent, &take(&1, header["nonce"])) or {:error, "badNonce"},
         {:ok, jwk} <- identity(header, state),
         true <- check(p <> "." <> payload, sig, jwk) or {:error, "signature"} do
      if header["jwk"],
        do: Agent.update(state.agent, &put_in(&1.jwks["https://#{@host}/acct/1"], jwk))

      :ok
    else
      {:error, why} -> {:error, "bad request: #{inspect(why)}"}
      other -> {:error, "bad request: #{inspect(other)}"}
    end
  end

  defp take(s, nonce) do
    if MapSet.member?(s.nonces, nonce),
      do: {true, %{s | nonces: MapSet.delete(s.nonces, nonce)}},
      else: {false, s}
  end

  defp identity(%{"jwk" => jwk}, _), do: {:ok, jwk}

  defp identity(%{"kid" => kid}, state) do
    case Agent.get(state.agent, & &1.jwks[kid]) do
      nil -> {:error, "unknown kid"}
      jwk -> {:ok, jwk}
    end
  end

  defp identity(_, _), do: {:error, "no key"}

  defp check(signing, sig, %{"x" => x, "y" => y}) do
    <<r::256, s::256>> = Base.url_decode64!(sig, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    point =
      <<4>> <> Base.url_decode64!(x, padding: false) <> Base.url_decode64!(y, padding: false)

    :public_key.verify(signing, :sha256, der, {{:ECPoint, point}, {:namedCurve, :secp256r1}})
  end

  ## The certificate

  defp issue(state, csr) do
    {pos, _} = :binary.match(csr, <<3, 66, 0, 4>>)
    point = binary_part(csr, pos + 3, 65)
    {pos, _} = :binary.match(csr, <<6, 3, 0x55, 0x1D, 0x11, 4>>)
    rest = binary_part(csr, pos + 6, byte_size(csr) - pos - 6)
    <<_, 0x30, _, 0x82, len, name::binary-size(len), _::binary>> = rest

    spki =
      {:OTPSubjectPublicKeyInfo,
       {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1},
        {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}}, {:ECPoint, point}}

    root = state.root |> :public_key.pkix_decode_cert(:otp) |> elem(1)

    day = fn offset ->
      Date.utc_today()
      |> Date.add(offset)
      |> Calendar.strftime("%y%m%d000000Z")
      |> String.to_charlist()
    end

    tbs =
      {:OTPTBSCertificate, :v3, :rand.uniform(1_000_000), elem(root, 3), elem(root, 6),
       {:Validity, {:utcTime, day.(-1)}, {:utcTime, day.(90)}}, {:rdnSequence, []}, spki,
       :asn1_NOVALUE, :asn1_NOVALUE,
       [{:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(name)]}]}

    leaf = :public_key.pkix_sign(tbs, state.ca_key)

    :public_key.pem_encode([
      {:Certificate, leaf, :not_encrypted},
      {:Certificate, state.root, :not_encrypted}
    ])
  end
end
