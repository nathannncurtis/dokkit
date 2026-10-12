defmodule Dokkit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Dokkit.LoginThrottle.init()
    Dokkit.Slots.init()
    Dokkit.Certificate.load()
    watch = Application.get_env(:dokkit, :watch, true)

    children =
      [Dokkit.Repo, Dokkit.RateLimit, {Phoenix.PubSub, name: Dokkit.PubSub}, DokkitWeb.Endpoint] ++
        ipv6_listener(Application.get_env(:dokkit, DokkitWeb.Endpoint, [])) ++
        if watch, do: [Dokkit.Alerts, Dokkit.Watch], else: []

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Dokkit.Supervisor) do
      if watch, do: Dokkit.Accounts.announce()
      if watch, do: Dokkit.Found.stop_watching_own()
      {:ok, pid}
    end
  end

  # An IPv6 socket on Windows takes no IPv4 and rejects ipv6_v6only: false, so IPv6 gets its own listener.
  @doc false
  def ipv6_listener(config) do
    {scheme, opts} = if config[:https], do: {:https, config[:https]}, else: {:http, config[:http]}

    if is_list(opts) and opts[:ip] == {0, 0, 0, 0} do
      opts = Keyword.put(opts, :ip, {0, 0, 0, 0, 0, 0, 0, 0})

      [
        Supervisor.child_spec(
          {Bandit, [plug: DokkitWeb.Endpoint, scheme: scheme, otp_app: :dokkit] ++ opts},
          id: :ipv6_listener
        )
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DokkitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
