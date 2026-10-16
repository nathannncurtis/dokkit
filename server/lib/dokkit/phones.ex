defmodule Dokkit.Phones do
  @moduledoc "Phones that read this server through a relay: pairing, sealing a snapshot to each, and uploading it."
  import Ecto.Query
  require Logger
  alias Dokkit.{Alerts, Keys, Phone, Repo, Setting}

  @aad "dokkit-phone-v1"
  @id ~r/\A[0-9a-f]{32}\z/
  @pair_life 120
  @failing_after 300

  def pair_life, do: @pair_life

  def list, do: Repo.all(from p in Phone, order_by: [p.inserted_at, p.id])

  def relay, do: Map.merge(%{"address" => "", "mailbox" => "", "key" => ""}, get("phone_relay"))

  def ready?, do: Enum.all?(~w(address mailbox key), &(relay()[&1] != ""))

  @doc "The relay as the API and the page show it: the upload key only as set or not set."
  def relay_view do
    r = relay()
    state = get("phone_state")

    %{
      address: r["address"],
      mailbox: r["mailbox"],
      key: if(r["key"] == "", do: "not set", else: "set"),
      last_good_upload: state["ok_at"],
      last_error: state["error"]
    }
  end

  @doc "Saves the relay. A key left blank stays. With a different address or mailbox the phones are removed, and the old mailbox is told."
  def save_relay(params) do
    old = relay()
    address = text(params["address"])
    mailbox = text(params["mailbox"])

    {address, mailbox} =
      case Regex.run(~r/\A(.*)\/m\/([0-9a-f]{32})\z/, address) do
        [_, base, id] -> {base, if(mailbox == "", do: id, else: mailbox)}
        _ -> {address, mailbox}
      end

    address = String.trim_trailing(address, "/")
    key = if text(params["key"]) == "", do: old["key"], else: text(params["key"])

    with :ok <- if(address == "", do: {:error, "Say where the relay is."}, else: :ok),
         :ok <- Alerts.check_url(address),
         :ok <-
           if(Regex.match?(@id, mailbox),
             do: :ok,
             else:
               {:error,
                "The mailbox is the 32 characters after /m/ in the address dokkit relay add printed."}
           ),
         :ok <-
           if(Keys.kind(key) == {:ok, :upload},
             do: :ok,
             else: {:error, "The upload key is the dkr_ key dokkit relay add printed."}
           ) do
      if (address != old["address"] or mailbox != old["mailbox"]) and
           Repo.delete_all(Phone) |> elem(0) > 0,
         do: upload(force: true)

      put("phone_relay", %{"address" => address, "mailbox" => mailbox, "key" => key})
      {:ok, relay_view()}
    end
  end

  defp text(value), do: if(is_binary(value), do: String.trim(value), else: "")

  @doc "Pairs a phone. `{:ok, phone, code}`: the code holds the fetch token and the phone's key and is not kept."
  def add(name) do
    name = text(name)

    cond do
      name == "" or String.length(name) > 60 ->
        {:error, "A phone needs a name of up to 60 characters."}

      not ready?() ->
        {:error, "Set the relay first."}

      true ->
        r = relay()
        token = Keys.generate(:fetch)
        key = :crypto.strong_rand_bytes(32)
        slot = hex(:crypto.strong_rand_bytes(16))

        phone =
          Repo.insert!(%Phone{
            name: name,
            slot: slot,
            token_hash: :crypto.hash(:sha256, token),
            key: key
          })

        pairing = %{
          relay: r["address"],
          mailbox: r["mailbox"],
          slot: slot,
          token: token,
          key: Base.encode64(key),
          name: server_name()
        }

        upload()

        {:ok, phone,
         "dokkit-phone:1:" <> Base.url_encode64(Jason.encode!(pairing), padding: false)}
    end
  end

  def remove(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, _} <- Repo.delete_all(from p in Phone, where: p.id == ^id) do
      upload(force: true)
      :ok
    else
      _ -> :not_found
    end
  end

  def view(%Phone{} = p),
    do: %{id: p.id, name: p.name, added_at: p.inserted_at, last_fetch_at: p.last_fetch_at}

  def server_name, do: Dokkit.Certificate.address()

  @doc "A snapshot sealed for each phone. `phones` carry slot, token_hash and key."
  def seal(json, mailbox, counter, made_at, phones) do
    content_key = :crypto.strong_rand_bytes(32)
    {nonce, body} = encrypt(content_key, :zlib.gzip(json), aad(mailbox, "body", counter))

    slots =
      for p <- phones, into: %{} do
        {slot_nonce, wrapped} = encrypt(p.key, content_key, aad(mailbox, p.slot, counter))

        {p.slot,
         %{
           token_sha256: hex(p.token_hash),
           nonce: Base.encode64(slot_nonce),
           key: Base.encode64(wrapped)
         }}
      end

    %{
      schema: 1,
      counter: counter,
      made_at: made_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      slots: slots,
      nonce: Base.encode64(nonce),
      body: Base.encode64(body)
    }
  end

  def aad(mailbox, part, counter), do: "#{@aad}|#{mailbox}|#{part}|#{counter}"

  defp encrypt(key, plain, aad) do
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, aad, 16, true)
    {iv, cipher <> tag}
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "Uploads when a relay is set and a phone exists (`force: true` skips the second test). `:skipped`, `:ok` or `{:error, why}`."
  def upload(opts \\ []) do
    :global.trans({:phone_upload, self()}, fn -> send_snapshot(opts) end, [node()])
  end

  defp send_snapshot(opts) do
    phones = list()

    if ready?() and (phones != [] or opts[:force]) do
      r = relay()
      now = DateTime.utc_now()
      state = get("phone_state")

      counter =
        max((state["counter"] || 0) + 1 + (state["skip"] || 0), DateTime.to_unix(now))

      put("phone_state", Map.put(state, "counter", counter))

      json =
        if opts[:doc],
          do: Dokkit.Phones.Snapshot.stamp(opts[:doc], counter, now),
          else: Dokkit.Phones.Snapshot.json(counter, now)

      envelope = seal(json, r["mailbox"], counter, now, phones)
      result = put_envelope(r, envelope)
      settle(result, now)
    else
      :skipped
    end
  rescue
    e -> settle({:error, "The upload failed: " <> Exception.message(e)}, DateTime.utc_now())
  end

  defp put_envelope(r, envelope) do
    options =
      [
        body: Jason.encode!(envelope),
        headers: [{"authorization", "Bearer " <> r["key"]}, {"content-type", "application/json"}],
        retry: false,
        redirect: false,
        receive_timeout: 10_000
      ] ++ Application.get_env(:dokkit, :req_options, [])

    with :ok <- Alerts.check_url(r["address"]) do
      case Req.put("#{r["address"]}/m/#{r["mailbox"]}", options) do
        {:ok, %{status: 200, body: %{"ok" => true} = body}} ->
          {:ok, body["slots"] || %{}}

        {:ok, %{status: 409}} ->
          :stale

        {:ok, %{status: s, body: %{"error" => %{"message" => why}}}} ->
          {:error, "The relay answered #{s}: #{why}"}

        {:ok, %{status: s}} ->
          {:error, "The relay answered #{s}."}

        {:error, e} ->
          {:error, "The relay did not answer: " <> Exception.message(e)}
      end
    end
  end

  defp settle({:ok, slots}, now) do
    for {slot, at} <- slots, is_binary(at), {:ok, at, _} <- [DateTime.from_iso8601(at)] do
      Repo.update_all(from(p in Phone, where: p.slot == ^slot), set: [last_fetch_at: at])
    end

    state = get("phone_state")
    log_change(state, nil, "The relay took the snapshot again.")

    put(
      "phone_state",
      Map.merge(state, %{
        "ok_at" => DateTime.to_iso8601(now),
        "failing_since" => nil,
        "error" => nil,
        "skip" => 0,
        "logged" => nil
      })
    )

    :ok
  end

  defp settle(:stale, now) do
    skip = max((get("phone_state")["skip"] || 0) * 2, 1)
    fail("The relay holds a newer snapshot; the next try uses a higher counter.", now, skip)
  end

  defp settle({:error, why}, now), do: fail(why, now, nil)

  defp fail(why, now, skip) do
    state = get("phone_state")
    log_change(state, why, nil)

    put(
      "phone_state",
      state
      |> Map.merge(%{
        "failing_since" => state["failing_since"] || DateTime.to_iso8601(now),
        "error" => why,
        "logged" => why
      })
      |> then(&if(skip, do: Map.put(&1, "skip", skip), else: &1))
    )

    {:error, why}
  end

  defp log_change(state, why, recovered) do
    cond do
      why && state["logged"] != why -> Logger.warning("Uploading to the relay failed: " <> why)
      recovered && state["logged"] -> Logger.warning(recovered)
      true -> :ok
    end
  end

  @doc "The words that tell a person what an upload did."
  def words(:ok), do: "The relay took the snapshot."
  def words(:skipped), do: "Saved. No phone is paired, so nothing was uploaded."
  def words({:error, why}), do: "Saved, but the relay did not take it. " <> why

  @doc "The relay's answer when uploads have failed for five minutes and a phone is waiting on them, else nil."
  def trouble(now) do
    state = get("phone_state")

    with true <- ready?() and list() != [],
         since when is_binary(since) <- state["failing_since"],
         {:ok, since, _} <- DateTime.from_iso8601(since),
         true <- DateTime.diff(now, since) >= @failing_after do
      state["error"]
    else
      _ -> nil
    end
  end

  defp get(key), do: Setting.get(key)
  defp put(key, value), do: Setting.put(key, value)
end
