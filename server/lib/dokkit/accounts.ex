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
  rescue
    e ->
      Logger.warning("Could not check for an account: #{Exception.message(e)}")
      Logger.warning("If there is no account yet, the setup code is: #{setup_code()}")
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

  @doc "A fresh secret for the authenticator app. Nothing asks for a code until one confirms it."
  def totp_begin(%User{totp_on: false} = user) do
    secret = Base.encode32(:crypto.strong_rand_bytes(20), padding: false)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [totp_secret: secret])
    secret
  end

  def totp_uri(%User{name: name}, secret) do
    name = URI.encode(name, &URI.char_unreserved?/1)
    "otpauth://totp/Dokkit:#{name}?secret=#{secret}&issuer=Dokkit"
  end

  @doc "Turns two-step on and returns the first set of recovery codes, which exist in the clear only in this return value."
  def totp_confirm(%User{totp_on: false} = user, code) do
    with :ok <- totp_set(user, code, true), do: {:ok, recovery_make(user)}
  end

  def totp_off(%User{totp_on: true} = user, code), do: totp_set(user, code, false)

  defp totp_set(user, code, on) do
    if totp_check(user, code) do
      secret = if on, do: user.totp_secret

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [totp_on: on, totp_secret: secret]
      )

      unless on, do: recovery_delete(user.id)
      :ok
    else
      :error
    end
  end

  @doc ~S"""
  For someone who lost their phone, from the server itself:
  bin/dokkit rpc 'Dokkit.Accounts.totp_reset("name")'
  """
  def totp_reset(name) do
    Repo.update_all(
      from(u in User, where: fragment("lower(?)", u.name) == ^String.downcase(name)),
      set: [totp_on: false, totp_secret: nil]
    )

    Repo.delete_all(
      from r in "recovery_codes",
        where:
          r.user_id in subquery(
            from u in User,
              where: fragment("lower(?)", u.name) == ^String.downcase(name),
              select: u.id
          )
    )
  end

  @doc "Ends the old set and makes ten new codes; they are returned once and only their hashes are kept."
  def recovery_make(%User{id: id} = user) do
    codes = for _ <- 1..10, do: recovery_new()
    now = DateTime.utc_now()

    {:ok, _} =
      Repo.transaction(fn ->
        recovery_delete(id)

        Repo.insert_all(
          "recovery_codes",
          for code <- codes do
            %{
              id: Ecto.UUID.bingenerate(),
              user_id: Ecto.UUID.dump!(id),
              code_hash: recovery_hash(user, code),
              inserted_at: now
            }
          end
        )
      end)

    codes
  end

  def recovery_renew(%User{totp_on: true} = user, code) do
    if totp_check(user, code), do: {:ok, recovery_make(user)}, else: :error
  end

  def recovery_left(%User{id: id}) do
    Repo.aggregate(
      from(r in "recovery_codes",
        where: r.user_id == type(^id, :binary_id) and is_nil(r.used_at)
      ),
      :count
    )
  end

  @doc "True once per code. Every unused hash is compared, so the time does not say which one matched."
  def recovery_use(%User{id: id} = user, code) when is_binary(code) do
    wanted = recovery_hash(user, code)

    rows =
      Repo.all(
        from r in "recovery_codes",
          where: r.user_id == type(^id, :binary_id) and is_nil(r.used_at),
          select: {r.id, r.code_hash}
      )

    hit =
      Enum.reduce(rows, nil, fn {row, stored}, hit ->
        if Plug.Crypto.secure_compare(stored, wanted), do: row, else: hit
      end)

    hit != nil and
      match?(
        {1, _},
        Repo.update_all(
          from(r in "recovery_codes", where: r.id == ^hit and is_nil(r.used_at)),
          set: [used_at: DateTime.utc_now()]
        )
      )
  end

  def recovery_use(_, _), do: false

  defp recovery_delete(id),
    do: Repo.delete_all(from r in "recovery_codes", where: r.user_id == type(^id, :binary_id))

  # A random 59-bit code cannot be searched for offline against a fast hash, so no slow one is needed.
  defp recovery_hash(%User{id: id}, code) do
    code = code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
    :crypto.hash(:sha256, id <> ":" <> code) |> Base.encode16(case: :lower)
  end

  defp recovery_new do
    raw =
      for <<b <- :crypto.strong_rand_bytes(12)>>,
        into: "",
        do: <<Enum.at(@code_letters, rem(b, 30))>>

    String.slice(raw, 0, 6) <> "-" <> String.slice(raw, 6, 6)
  end

  @doc "True once per code: the step it was made in cannot be used again."
  def totp_check(%User{totp_secret: secret} = user, code)
      when is_binary(secret) and is_binary(code) do
    code = String.replace(code, ~r/\s/, "")
    now = totp_step()

    step =
      Enum.find([now, now - 1, now + 1], fn step ->
        step > user.totp_step and Plug.Crypto.secure_compare(totp_code(secret, step), code)
      end)

    step != nil and
      match?(
        {1, _},
        Repo.update_all(from(u in User, where: u.id == ^user.id and u.totp_step < ^step),
          set: [totp_step: step]
        )
      )
  end

  def totp_check(_, _), do: false

  def totp_step, do: div(System.os_time(:second), 30)

  @doc false
  def totp_code(secret, step \\ totp_step()) do
    mac = :crypto.mac(:hmac, :sha, Base.decode32!(secret, padding: false), <<step::64>>)
    skip = rem(:binary.last(mac), 16)
    <<_::binary-size(^skip), _::1, n::31, _::binary>> = mac
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
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
