defmodule Dokkit.Certificate do
  @moduledoc """
  The second certificate: one for a real name, put in place through the API. The listener
  picks it by the name the client asks for and falls back to the installed one, which
  machines have pinned. What to serve is kept in :persistent_term, so a new upload is served to
  the next connection without a restart.
  """
  require Record

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @term {__MODULE__, :uploaded}
  @san {2, 5, 29, 17}
  @no_tls "This server does not serve TLS itself, so it holds no certificate."

  def dir, do: Application.fetch_env!(:dokkit, :tls)
  defp cert_path, do: Path.join(dir(), "cert.pem")
  defp key_path, do: Path.join(dir(), "key.pem")

  @doc "Both certificates, as the API shows them. Never a key."
  def view, do: %{installed: installed(), uploaded: uploaded_info()}

  defp installed do
    with path when is_binary(path) <- Application.get_env(:dokkit, :cert),
         {:ok, pem} <- File.read(path),
         [_ | _] = chain <- chain(pem) do
      info(chain)
    else
      _ -> nil
    end
  end

  defp uploaded_info do
    case :persistent_term.get(@term, nil) do
      nil -> nil
      %{chain: chain} -> info(chain)
    end
  end

  defp body(der), do: der |> :public_key.pkix_decode_cert(:otp) |> elem(1)

  defp chain(pem),
    do: for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der)

  defp info([leaf | _]) do
    t = body(leaf)

    %{
      names: names(t),
      issuer: issuer(tbs(t, :issuer)),
      not_after: not_after(t) |> DateTime.to_iso8601(),
      self_signed: :public_key.pkix_is_self_signed(leaf),
      sha256: Base.encode16(:crypto.hash(:sha256, leaf), case: :lower)
    }
  end

  defp names(t) do
    for {:Extension, @san, _, values} <- List.wrap(tbs(t, :extensions)),
        {:dNSName, name} <- values,
        do: to_string(name)
  end

  defp issuer({:rdnSequence, rdns}) do
    attrs = for rdn <- rdns, {:AttributeTypeAndValue, oid, value} <- rdn, do: {oid, value}
    value = List.keyfind(attrs, {2, 5, 4, 3}, 0) || List.keyfind(attrs, {2, 5, 4, 10}, 0)

    case value do
      {_, {_, text}} -> to_string(text)
      {_, text} when is_list(text) or is_binary(text) -> to_string(text)
      _ -> ""
    end
  end

  defp not_after(t), do: t |> tbs(:validity) |> elem(2) |> time()
  defp not_before(t), do: t |> tbs(:validity) |> elem(1) |> time()

  defp time({_, text}) do
    text = to_string(text)

    {year, rest} =
      case text do
        <<yy::binary-2, rest::binary>> when byte_size(text) == 13 ->
          y = String.to_integer(yy)
          {if(y >= 50, do: 1900 + y, else: 2000 + y), rest}

        <<yyyy::binary-4, rest::binary>> ->
          {String.to_integer(yyyy), rest}
      end

    <<mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, _::binary>> = rest

    DateTime.new!(
      Date.new!(year, String.to_integer(mo), String.to_integer(d)),
      Time.new!(String.to_integer(h), String.to_integer(mi), String.to_integer(s))
    )
  end

  @doc "Checks a certificate with its chain and a key, saves them and starts serving them."
  def put(cert, key) when is_binary(cert) and is_binary(key) do
    with :ok <- serves_tls(),
         {:ok, _} <- parse(cert, key),
         :ok <- save(cert, key) do
      load()
      {:ok, view()}
    end
  end

  def put(_, _), do: {:error, "Needs cert and key, as text."}

  def delete do
    with :ok <- serves_tls() do
      File.rm(cert_path())
      File.rm(key_path())
      :persistent_term.erase(@term)
      {:ok, view()}
    end
  end

  defp serves_tls do
    if Application.get_env(:dokkit, :cert), do: :ok, else: {:error, @no_tls}
  end

  defp parse(cert, key) do
    with [leaf | _] = chain <- chain(cert),
         {:ok, private} <- private_key(key) do
      t = body(leaf)
      now = DateTime.utc_now()

      cond do
        not matches?(t, private) ->
          {:error, "The key does not belong to the certificate."}

        DateTime.compare(not_after(t), now) != :gt ->
          {:error, "The certificate has expired."}

        DateTime.compare(not_before(t), now) == :gt ->
          {:error, "The certificate is not valid yet."}

        names(t) == [] ->
          {:error, "The certificate names no DNS name."}

        true ->
          {:ok, %{chain: chain, key: key_entry(key)}}
      end
    else
      [] -> {:error, "No certificate could be read from cert."}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, "No certificate could be read from cert."}
  end

  defp private_key(pem) do
    case :public_key.pem_decode(pem) do
      [{_, _, :not_encrypted} = entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      _ -> {:error, "No unencrypted private key could be read from key."}
    end
  rescue
    _ -> {:error, "No unencrypted private key could be read from key."}
  end

  defp matches?(t, private) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, _, params}, public} =
      tbs(t, :subjectPublicKeyInfo)

    public = if match?({:ECPoint, _}, public), do: {public, params}, else: public
    sig = :public_key.sign("dokkit", :sha256, private)
    :public_key.verify("dokkit", :sha256, sig, public)
  rescue
    _ -> false
  end

  defp key_entry(pem) do
    [{type, der, :not_encrypted} | _] = :public_key.pem_decode(pem)
    {type, der}
  end

  defp save(cert, key) do
    File.mkdir_p!(dir())
    write(key_path(), key)
    write(cert_path(), cert)
    :ok
  rescue
    e in File.Error ->
      {:error, "The certificate could not be saved: #{:file.format_error(e.reason)}"}
  end

  defp write(path, text) do
    tmp = path <> ".new"
    File.write!(tmp, text)
    File.rename!(tmp, path)
  end

  @doc "Reads the saved certificate into memory. Called at boot and after each change."
  def load do
    with {:ok, cert} <- File.read(cert_path()),
         {:ok, key} <- File.read(key_path()),
         {:ok, %{chain: chain, key: key}} <- parse_loose(cert, key) do
      leaf = hd(chain)
      t = body(leaf)

      :persistent_term.put(@term, %{
        chain: chain,
        key: key,
        names: for(n <- names(t), do: String.downcase(n))
      })
    else
      _ -> :persistent_term.erase(@term)
    end

    :ok
  end

  defp parse_loose(cert, key) do
    case chain(cert) do
      [_ | _] = chain -> {:ok, %{chain: chain, key: key_entry(key)}}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "The options for a connection that asked for this name: the uploaded certificate, or nothing."
  def sni(host) do
    with %{names: names, chain: chain, key: key} <- :persistent_term.get(@term, nil),
         true <- covers?(names, to_string(host)) do
      [certs_keys: [%{cert: chain, key: key}]]
    else
      _ -> :undefined
    end
  end

  @doc "True when one of the names is the host, or a `*.` name with the host one label below it."
  def covers?(names, host) do
    host = String.downcase(host)

    Enum.any?(names, fn
      "*." <> rest ->
        case String.split(host, ".", parts: 2) do
          [label, ^rest] -> label != ""
          _ -> false
        end

      name ->
        name == host
    end)
  end

  def uploaded_names, do: (:persistent_term.get(@term, nil) || %{names: []}).names

  @doc "Every name this server answers to: the configured host and the uploaded certificate's names."
  def mine?(host) when is_binary(host) do
    host = String.downcase(host)
    host == configured_host() or covers?(uploaded_names(), host)
  end

  def mine?(_), do: false

  def origin?(%URI{host: host}), do: mine?(host)

  def configured_host, do: String.downcase(DokkitWeb.Endpoint.host())

  @doc "The name people should use to reach this server: the uploaded certificate's first name, else the configured host."
  def address do
    Enum.find(uploaded_names(), &(not String.starts_with?(&1, "*."))) || DokkitWeb.Endpoint.host()
  end

  def url, do: %{URI.parse(DokkitWeb.Endpoint.url()) | host: address()} |> URI.to_string()

  @doc "True when the address shown is covered by a certificate that is not self-signed."
  def trusted_address? do
    case :persistent_term.get(@term, nil) do
      %{chain: [leaf | _], names: names} ->
        covers?(names, address()) and not :public_key.pkix_is_self_signed(leaf)

      _ ->
        false
    end
  end

  @doc "Days until the uploaded certificate runs out, or nil when there is none."
  def days_left(now \\ DateTime.utc_now()) do
    with %{chain: [leaf | _]} <- :persistent_term.get(@term, nil) do
      t = body(leaf)
      DateTime.diff(not_after(t), now, :second) / 86_400
    end
  end
end
