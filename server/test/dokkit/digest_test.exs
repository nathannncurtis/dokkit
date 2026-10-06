defmodule Dokkit.DigestTest do
  use Dokkit.DataCase, async: false
  alias Dokkit.{Alert, Digest, Issue, Machine, Repo, Setting}

  setup do
    Application.put_env(:dokkit, :mail, :real)
    on_exit(fn -> Application.put_env(:dokkit, :mail, :test) end)
  end

  defp issue(machine, title, since) do
    Repo.insert!(%Issue{
      machine_id: machine.id,
      kind: "machine",
      state: :down,
      title: title,
      since: since
    })
  end

  test "a digest that fails stays pending, and one that goes out marks what it carried" do
    machine = Repo.insert!(%Machine{name: "digest-tick-box"})
    old = issue(machine, "digest-tick-old", DateTime.add(DateTime.utc_now(), -3 * 86_400))
    alert = Repo.insert!(%Alert{issue_id: old.id, channel: "digest"})
    config = %{"email_to" => "ops@example.test", "digest_at" => "00:00", "smtp_host" => ""}
    now = DateTime.utc_now()

    assert {:error, _} = Digest.tick(now, config)
    assert Repo.reload!(alert).status == :pending
    refute Repo.get(Setting, "digest")

    Application.put_env(:dokkit, :mail, :test)
    assert Digest.tick(now, config) == :sent
    assert Repo.reload!(alert).status == :sent
    assert Repo.get(Setting, "digest").value["sent"] == Date.to_iso8601(DateTime.to_date(now))
  end
end
