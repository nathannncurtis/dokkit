defmodule Dokkit.Mail do
  @moduledoc "Sends one mail through the mail server in the alert settings. HTML that reads like plain text."

  def send(to, subject, lines, config) when is_binary(to) and to != "" do
    # Several addresses are written with commas between them.
    to = String.split(to, ~r/[,;\s]+/, trim: true)
    text = Enum.join(lines, "\n")

    html =
      ~s(<div style="font-family: system-ui, 'Hanken Grotesk', sans-serif; font-size: 15px; line-height: 1.5">) <>
        Enum.map_join(lines, "<br>", &(&1 |> Plug.HTML.html_escape() |> to_string())) <> "</div>"

    case Application.get_env(:dokkit, :mail) do
      :test ->
        Kernel.send(self(), {:mail, Enum.join(to, ", "), subject, text})
        :ok

      _ ->
        smtp(to, subject, text, html, config)
    end
  end

  def send(_, _, _, _), do: {:error, "There is no address to send to yet."}

  defp smtp(to, subject, text, html, %{"smtp_host" => host} = config)
       when host not in [nil, ""] do
    from = config["mail_from"] || "dokkit@#{host}"
    utf8 = %{content_type_params: [{"charset", "utf-8"}]}

    mail =
      :mimemail.encode(
        {"multipart", "alternative",
         [{"From", from}, {"To", Enum.join(to, ", ")}, {"Subject", subject}], %{},
         [{"text", "plain", [], utf8, text}, {"text", "html", [], utf8, html}]}
      )

    with :ok <- allowed_port(config["smtp_port"] || "587"),
         {:ok, ips} <- Dokkit.Alerts.resolve(host) do
      case :gen_smtp_client.send_blocking({from, to, mail}, smtp_options(host, config, ips)) do
        receipt when is_binary(receipt) -> :ok
        error -> Dokkit.Alerts.failed(host, inspect(error) |> String.slice(0, 300))
      end
    end
  rescue
    e -> Dokkit.Alerts.failed(host, Exception.message(e))
  end

  defp smtp(_, _, _, _, _), do: {:error, "The mail server has no address yet."}

  defp allowed_port(port) do
    if port in Enum.map(Dokkit.Alerts.smtp_ports(), &to_string/1),
      do: :ok,
      else:
        {:error, "The mail server port is one of #{Enum.join(Dokkit.Alerts.smtp_ports(), ", ")}."}
  end

  @doc false
  # Port 465 is TLS from the first byte; any other port must upgrade with STARTTLS or fail.
  # `ips` is what the host resolved to when it was checked; the connection goes to that address.
  def smtp_options(host, config, ips \\ []) do
    user = config["smtp_user"]
    port = String.to_integer(config["smtp_port"] || "587")

    relay =
      case Enum.sort_by(ips, &tuple_size/1) do
        [ip | _] -> :inet.ntoa(ip)
        [] -> String.to_charlist(host)
      end

    tls = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 99
    ]

    [
      relay: relay,
      # The host was checked, so no other host is looked up for it.
      no_mx_lookups: true,
      port: port,
      auth: if(user in [nil, ""], do: :never, else: :always),
      username: user || "",
      password: config["smtp_password"] || ""
    ] ++
      if(port == 465,
        do: [ssl: true, tls: :never, sockopts: tls],
        else: [tls: :always, tls_options: tls]
      )
  end
end
