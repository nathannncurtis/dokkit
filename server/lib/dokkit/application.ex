defmodule Dokkit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DokkitWeb.Telemetry,
      Dokkit.Repo,
      {DNSCluster, query: Application.get_env(:dokkit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dokkit.PubSub},
      DokkitWeb.Endpoint
    ]

    children =
      children ++ if Application.get_env(:dokkit, :watch, true), do: [Dokkit.Watch], else: []

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Dokkit.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if Application.get_env(:dokkit, :watch, true), do: Dokkit.Accounts.announce()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DokkitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
