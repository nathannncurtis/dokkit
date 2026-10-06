defmodule Dokkit.Accounts do
  @moduledoc "People who can sign in, and the code that lets the first one claim a new server."
  import Ecto.Query
  require Logger
  alias Dokkit.{Repo, User}

  @rounds 600_000
  @min_password 12
  @code_letters ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"

  def min_password, do: @min_password
  def any?, do: Repo.exists?(User)
  def get(id), do: Repo.get(User, id)

  @doc "Made once per start. It only matters while nobody has an account."
  def setup_code do
    case :persistent_term.get({__MODULE__, :code}, nil) do
      nil ->
        code =
          for <<b <- :crypto.strong_rand_bytes(8)>>,
            into: "",
            do: <<Enum.at(@code_letters, rem(b, 30))>>

        code = String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
        :persistent_term.put({__MODULE__, :code}, code)
        code

      code ->
        code
    end
  end

  def announce do
    unless any?(), do: Logger.warning("No account yet. Setup code: #{setup_code()}")
  end

  def create_owner(code, name, password) do
    name = String.trim(name || "")

    cond do
      any?() ->
        {:error, "This server already has an owner."}

      not Plug.Crypto.secure_compare(normal(code), setup_code()) ->
        {:error, "That is not the setup code the server printed when it started."}

      name == "" ->
        {:error, "Choose a name to sign in with."}

      String.length(password || "") < @min_password ->
        {:error, "Use a password of at least #{@min_password} characters."}

      true ->
        {:ok, Repo.insert!(%User{name: name, password_hash: hash(password), role: :owner})}
    end
  end

  def list, do: Repo.all(from u in User, order_by: u.name)

  def add(name, role, password) do
    name = String.trim(name || "")

    cond do
      name == "" ->
        {:error, "Choose a name to sign in with."}

      role not in ~w(owner member viewer) ->
        {:error, "A person is an owner, a member or a viewer."}

      String.length(password || "") < @min_password ->
        {:error, "Use a password of at least #{@min_password} characters."}

      Repo.exists?(from u in User, where: fragment("lower(?)", u.name) == ^String.downcase(name)) ->
        {:error, "There is already someone called #{name}."}

      true ->
        {:ok,
         Repo.insert!(%User{
           name: name,
           password_hash: hash(password),
           role: String.to_existing_atom(role)
         })}
    end
  end

  @doc "Removing someone signs them out everywhere."
  def remove(id, %User{id: by}) do
    case Ecto.UUID.cast(id) do
      {:ok, ^by} ->
        {:error, "You cannot remove yourself."}

      {:ok, id} ->
        owners = Repo.all(from u in User, where: u.role == :owner, select: u.id)

        if owners == [id] do
          {:error, "Someone has to be an owner."}
        else
          Repo.update_all(from(k in Dokkit.Key, where: k.user_id == ^id and is_nil(k.revoked_at)),
            set: [revoked_at: DateTime.utc_now()]
          )

          Repo.delete_all(from u in User, where: u.id == ^id)
          DokkitWeb.Endpoint.broadcast("user:#{id}", "disconnect", %{})
          :ok
        end

      :error ->
        {:error, "No such person."}
    end
  end

  def authenticate(name, password) when is_binary(name) and is_binary(password) do
    name = String.downcase(String.trim(name))
    user = Repo.one(from u in User, where: fragment("lower(?)", u.name) == ^name)
    # Hash even when there is no such user, so the answer takes as long either way.
    stored = (user && user.password_hash) || "#{@rounds}$AAAAAAAAAAAAAAAAAAAAAA$AAAA"

    if check(password, stored) and user != nil, do: {:ok, user}, else: :error
  end

  def authenticate(_, _), do: :error

  @doc "Ends every session this person has, on every device."
  def sign_out_everywhere(%User{id: id}) do
    Repo.update_all(from(u in User, where: u.id == ^id), set: [sessions_after: stamp()])
    DokkitWeb.Endpoint.broadcast("user:#{id}", "disconnect", %{})
    :ok
  end

  @doc "Microseconds, the time a session carries and is compared by."
  def stamp, do: System.os_time(:microsecond)

  def change_password(%User{} = user, old, new) do
    cond do
      not is_binary(old) or not is_binary(new) or not check(old, user.password_hash) ->
        {:error, :wrong, "That is not your current password."}

      String.length(new) < @min_password ->
        {:error, "Use a password of at least #{@min_password} characters."}

      true ->
        {1, _} =
          Repo.update_all(from(u in User, where: u.id == ^user.id),
            set: [password_hash: hash(new), sessions_after: stamp()]
          )

        DokkitWeb.Endpoint.broadcast("user:#{user.id}", "disconnect", %{})
        {:ok, get(user.id)}
    end
  end

  defp normal(code), do: (code || "") |> String.trim() |> String.upcase()

  defp hash(password, salt \\ :crypto.strong_rand_bytes(16), rounds \\ @rounds) do
    key = :crypto.pbkdf2_hmac(:sha256, password, salt, rounds, 32)
    "#{rounds}$#{Base.encode64(salt, padding: false)}$#{Base.encode64(key, padding: false)}"
  end

  defp check(password, stored) do
    with [rounds, salt, _] <- String.split(stored, "$"),
         {:ok, salt} <- Base.decode64(salt, padding: false) do
      Plug.Crypto.secure_compare(hash(password, salt, String.to_integer(rounds)), stored)
    else
      _ -> false
    end
  end
end
