defmodule Dokkit.SharedBeat do
  @moduledoc """
  dokkit.dev as the outside heartbeat: this server asks it for a heartbeat address, with no
  account, and dokkit.dev tells this server's ntfy topic or webhook when the calls stop.
  """
  require Logger
  alias Dokkit.{Alerts, Setting}

  @setting "shared_heartbeat"

  def service, do: Application.get_env(:dokkit, :shared_heartbeat) |> String.trim_trailing("/")

  @doc "The heartbeat in use, or nil: its url and where dokkit.dev sends."
  def current do
    s = Setting.get(@setting)
    if s["url"] && s["url"] == Alerts.config()["heartbeat_url"], do: s
  end

  @doc "Where dokkit.dev should send, taken from this page's own ntfy or webhook."
  def target(config \\ Alerts.config()) do
    cond do
      filled(config["ntfy_url"]) and not filled(config["ntfy_token"]) ->
        {:ok, "ntfy", config["ntfy_url"]}

      filled(config["webhook_url"]) ->
        {:ok, "webhook", config["webhook_url"]}

      true ->
        {:error,
         "Set an ntfy topic without a token, or a webhook, on this page first. dokkit.dev sends there when this server stops calling."}
    end
  end

  def label do
    case Dokkit.Names.name() do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        {:ok, host} = :inet.gethostname()
        to_string(host)
    end
  end

  @doc "Gets a heartbeat from dokkit.dev, or points the one in use at the current target, and saves it as the outside heartbeat."
  def use do
    with {:ok, kind, notify} <- target(),
         body = %{label: label(), kind: kind, notify: notify},
         {:ok, saved} <- make_or_change(Setting.get(@setting), body) do
      Setting.put(@setting, saved)

      with {:ok, _, _} <- Alerts.update(%{"heartbeat_url" => saved["url"]}), do: {:ok, saved}
    end
  end

  defp make_or_change(%{"url" => url, "token" => token, "key" => key} = old, body) do
    case call(:put, "/v1/beats/" <> token, body, key) do
      {:ok, %{status: 204}} ->
        {:ok, Map.merge(old, %{"url" => url, "kind" => body.kind, "notify" => body.notify})}

      {:ok, %{status: 404}} ->
        make_or_change(nil, body)

      other ->
        failed(other)
    end
  end

  defp make_or_change(_, body) do
    case call(:post, "/v1/beats", body, nil) do
      {:ok, %{status: 201, body: %{"url" => url, "token" => token, "key" => key}}} ->
        {:ok,
         %{
           "url" => url,
           "token" => token,
           "key" => key,
           "kind" => body.kind,
           "notify" => body.notify
         }}

      other ->
        failed(other)
    end
  end

  @doc "Stops using dokkit.dev: removes the heartbeat there and clears the outside heartbeat here."
  def stop do
    with %{"token" => token, "key" => key} <- Setting.get(@setting) do
      call(:delete, "/v1/beats/" <> token, nil, key)
    end

    Setting.put(@setting, %{})

    if Alerts.config()["heartbeat_url"] |> to_string() |> String.starts_with?(service()),
      do: Alerts.update(%{"heartbeat_url" => ""})

    :ok
  end

  @doc "After the alert settings change: a heartbeat in use follows the new ntfy or webhook, and one replaced by another address is removed."
  def follow(config) do
    case Setting.get(@setting) do
      %{"url" => url} = s ->
        cond do
          config["heartbeat_url"] != url ->
            stop()

          match?({:ok, _, _}, target(config)) and target(config) != {:ok, s["kind"], s["notify"]} ->
            with {:error, why} <- use(),
                 do: Logger.warning("The dokkit.dev heartbeat was not updated: #{why}")

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp call(method, path, body, key) do
    options =
      [
        method: method,
        url: service() <> path,
        retry: false,
        redirect: false,
        receive_timeout: 10_000
      ] ++
        if(body, do: [json: body], else: []) ++
        if(key, do: [headers: [{"authorization", "Bearer " <> key}]], else: []) ++
        Application.get_env(:dokkit, :req_options, [])

    with :ok <- Alerts.check_url(service()), do: Req.request(options)
  rescue
    e -> {:error, e}
  end

  defp failed({:ok, %{status: s, body: %{"error" => why}}}),
    do: {:error, "dokkit.dev answered #{s}: #{why}"}

  defp failed({:ok, %{status: s}}), do: {:error, "dokkit.dev answered #{s}."}
  defp failed({:error, why}) when is_binary(why), do: {:error, why}
  defp failed({:error, e}), do: {:error, "dokkit.dev did not answer: " <> Exception.message(e)}

  defp filled(v), do: is_binary(v) and String.trim(v) != ""
end
