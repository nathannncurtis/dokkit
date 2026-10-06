defmodule Dokkit.Keys do
  @moduledoc "Keys are shown once; only a hash is stored."
  import Ecto.Query
  alias Dokkit.{Key, Repo}

  @prefixes %{enrol: "dke_", machine: "dkm_", app: "dka_", user: "dku_"}
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  def mint(kind, attrs \\ %{}) do
    text = generate(kind)

    key =
      Repo.insert!(
        struct!(Key, Map.merge(attrs, %{kind: kind, hash: hash(text), hint: hint(text)}))
      )

    {text, key}
  end

  def generate(kind) do
    body =
      for <<b <- :crypto.strong_rand_bytes(30)>>, into: "", do: <<Enum.at(@alphabet, rem(b, 62))>>

    @prefixes[kind] <> body <> checksum(body)
  end

  @doc "Kind of a well-formed key, without a lookup."
  def kind(<<prefix::binary-4, body::binary-30, sum::binary-6>>) do
    with {kind, _} <- Enum.find(@prefixes, fn {_, p} -> p == prefix end),
         true <- checksum(body) == sum do
      {:ok, kind}
    else
      _ -> :error
    end
  end

  def kind(_), do: :error

  def verify(text, kinds) do
    now = DateTime.utc_now()

    with {:ok, kind} <- kind(text),
         true <- kind in List.wrap(kinds),
         %Key{} = key <-
           Repo.one(
             from k in Key,
               where: k.hash == ^hash(text) and is_nil(k.revoked_at),
               where: is_nil(k.expires_at) or k.expires_at > ^now
           ) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  @doc "Every key that still works, newest first."
  def list do
    now = DateTime.utc_now()

    Repo.all(
      from k in Key,
        where: is_nil(k.revoked_at) and (is_nil(k.expires_at) or k.expires_at > ^now),
        order_by: [desc: k.inserted_at],
        preload: [:machine, :service]
    )
  end

  def used(%Key{id: id}) do
    Repo.update_all(from(k in Key, where: k.id == ^id), set: [used_at: DateTime.utc_now()])
  end

  def revoke(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.update_all(from(k in Key, where: k.id == ^id), set: [revoked_at: DateTime.utc_now()])
    end

    :ok
  end

  def hint(text), do: String.slice(text, 0, 8) <> "…"

  defp hash(text), do: :crypto.hash(:sha256, text)

  defp checksum(body) do
    body
    |> :erlang.crc32()
    |> Integer.digits(62)
    |> Enum.map(&Enum.at(@alphabet, &1))
    |> to_string()
    |> String.pad_leading(6, "0")
  end
end
