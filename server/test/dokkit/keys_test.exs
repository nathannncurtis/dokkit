defmodule Dokkit.KeysTest do
  use Dokkit.DataCase, async: true
  alias Dokkit.Keys

  test "a generated key carries its kind and a checksum" do
    text = Keys.generate(:app)
    assert String.starts_with?(text, "dka_")
    assert Keys.kind(text) == {:ok, :app}
    <<head::binary-39, last>> = text
    refute Keys.kind(head <> <<if(last == ?a, do: ?b, else: ?a)>>) == {:ok, :app}
  end

  test "verify finds a live key of the right kind only" do
    {text, key} = Keys.mint(:user, %{scopes: ["read"]})
    assert {:ok, %{id: id}} = Keys.verify(text, :user)
    assert id == key.id
    assert Keys.verify(text, :machine) == :error
    Dokkit.Repo.update!(Ecto.Changeset.change(key, revoked_at: DateTime.utc_now()))
    assert Keys.verify(text, :user) == :error
  end
end
