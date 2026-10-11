defmodule Dokkit.TestCerts do
  @moduledoc "Certificates for tests: a self-signed one, and one issued through a throwaway root and intermediate."

  defp san(names),
    do:
      {:Extension, {2, 5, 29, 17}, false, for(n <- names, do: {:dNSName, String.to_charlist(n)})}

  defp rsa, do: :public_key.generate_key({:rsa, 2048, 65537})

  defp pem(type, der), do: :public_key.pem_encode([{type, der, :not_encrypted}])

  defp key_pem({type, der}), do: pem(type, der)

  @doc "A self-signed certificate for the names, with its key. Writes both PEM files into dir."
  def self_signed(names, dir) do
    key = :public_key.generate_key({:rsa, 2048, 65537})

    config =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: key, digest: :sha256, extensions: [san(names)]], peer: []},
        client_chain: %{root: [], peer: []}
      })

    root = Enum.find(config.server_config[:cacerts], &(:binary.match(&1, hd(names)) != :nomatch))
    cert = pem(:Certificate, root)
    key = pem(:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "installed.pem"), cert)
    File.write!(Path.join(dir, "installed-key.pem"), key)
    %{cert: cert, key: key, der: root, path: Path.join(dir, "installed.pem")}
  end

  @doc "A certificate for the names signed by an intermediate of a throwaway root. cert holds the leaf then the intermediate."
  def issued(names, opts \\ []) do
    peer =
      [key: rsa(), digest: :sha256, extensions: [san(names)]] ++ Keyword.take(opts, [:validity])

    config =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: rsa(), digest: :sha256],
          intermediates: [[key: rsa(), digest: :sha256]],
          peer: peer
        },
        client_chain: %{root: [], peer: []}
      })

    der = config.server_config[:cert]

    intermediate =
      Enum.find(config.server_config[:cacerts], &(not :public_key.pkix_is_self_signed(&1)))

    %{
      cert: pem(:Certificate, der) <> pem(:Certificate, intermediate),
      key: key_pem(config.server_config[:key]),
      der: der,
      chain: [der, intermediate]
    }
  end

  def days_from_now(days), do: Date.utc_today() |> Date.add(days) |> Date.to_erl()

  def validity(from_days, to_days), do: {days_from_now(from_days), days_from_now(to_days)}

  def fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)
end
