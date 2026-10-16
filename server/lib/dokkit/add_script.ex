defmodule Dokkit.AddScript do
  @moduledoc "The one script that adds a Windows machine: it fetches and checks the program, enrols, installs the service and the updater."

  @release_key "xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk="

  def release_key, do: @release_key

  @doc "The script's file name and text, or :no_release when the server holds no complete release."
  def windows(name, token, expires_at) do
    case Dokkit.Releases.newest() do
      nil ->
        :no_release

      version ->
        file = "dokkit-add-#{slug(name)}.ps1"

        text =
          Application.app_dir(:dokkit, "priv/add/windows.ps1")
          |> File.read!()
          |> fill(%{
            "SERVER" => Dokkit.Certificate.url(),
            "TOKEN" => token,
            "PIN" => pin(),
            "VERSION" => version,
            "RELEASE_KEY" => @release_key,
            "NAME" => name,
            "FILE" => file,
            "EXPIRES" => Calendar.strftime(expires_at, "%Y-%m-%d %H:%M")
          })
          |> String.replace(
            "@@ED25519@@",
            File.read!(Application.app_dir(:dokkit, "priv/add/ed25519.ps1"))
          )
          |> String.replace(~r/\r?\n/, "\r\n")

        {:ok, file, text}
    end
  end

  @doc "The one line that fetches and runs the script from this server."
  def command(token), do: "irm #{Dokkit.Certificate.url()}/add/#{token} | iex"

  defp fill(text, values) do
    Enum.reduce(values, text, fn {k, v}, acc ->
      String.replace(acc, "@@#{k}@@", String.replace(to_string(v), "'", "''"))
    end)
  end

  defp slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "machine"
      s -> s
    end
  end

  @doc "The fingerprint of the certificate this server serves, when no public authority vouches for it."
  def pin do
    with false <- Dokkit.Certificate.trusted_address?(),
         path when is_binary(path) <- Application.get_env(:dokkit, :cert),
         {:ok, pem} <- File.read(path),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem) do
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower)
    else
      _ -> ""
    end
  end
end
