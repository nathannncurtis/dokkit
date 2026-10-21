defmodule Dokkit.Keys do
  @moduledoc "Keys are shown once; only a hash is stored."
  import Ecto.Query
  alias Dokkit.{Key, Machine, Repo}

  @prefixes %{
    enrol: "dke_",
    machine: "dkm_",
    app: "dka_",
    user: "dku_",
    fetch: "dkf_",
    upload: "dkr_"
  }
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  def mint(kind, attrs \\ %{}) do
    text = generate(kind)

    key =
      Repo.insert!(
        struct!(Key, Map.merge(attrs, %{kind: kind, hash: hash(text), hint: hint(text)}))
      )

    {text, key}
  end

  def enrol_life, do: Dokkit.Values.get("enrol_hours") * 3600
  def enrol_most_hours, do: Dokkit.Values.get("enrol_max_hours")

  @doc "An enrolment token for one machine name (or none), good for `seconds`."
  def mint_enrol(label, seconds \\ nil)
  def mint_enrol(label, nil), do: mint_enrol(label, enrol_life())

  def mint_enrol(label, seconds) when is_integer(seconds) and seconds > 0 do
    seconds = min(seconds, enrol_most_hours() * 3600)
    mint(:enrol, %{expires_at: DateTime.add(DateTime.utc_now(), seconds), label: label})
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

  @doc "Enrolment tokens that are made, not yet used and not run out."
  def waiting, do: Enum.filter(list(), &(&1.kind == :enrol and is_nil(&1.used_at)))

  @doc "The time a token has left, as words; nil when it has none or never runs out."
  def left(%Key{expires_at: nil}, _now), do: nil

  def left(%Key{expires_at: at}, now) do
    s = DateTime.diff(at, now)

    cond do
      s <= 0 -> nil
      s >= 3600 -> "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"
      true -> "#{div(s, 60) + 1} min"
    end
  end

  @doc "The machine a spent token became: the one it records, else the one named as its label, else the latest enrolled."
  def arrived(%Key{id: id}) do
    with %Key{used_at: %DateTime{} = used} = key <- Repo.get(Key, id) do
      (key.machine_id && Repo.get(Machine, key.machine_id)) ||
        (key.label &&
           Repo.one(
             from m in Machine,
               where: m.name == ^key.label and m.kind == :enrolled and m.updated_at >= ^used
           )) ||
        Repo.one(
          from m in Machine,
            where: m.kind == :enrolled and m.updated_at >= ^used,
            order_by: [desc: m.updated_at],
            limit: 1
        )
    else
      _ -> nil
    end
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
