defmodule Dokkit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Dokkit.LoginThrottle.init()
    watch = Application.get_env(:dokkit, :watch, true)

    children =
      [Dokkit.Repo, {Phoenix.PubSub, name: Dokkit.PubSub}, DokkitWeb.Endpoint] ++
        if watch, do: [Dokkit.Alerts, Dokkit.Watch], else: []

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Dokkit.Supervisor) do
      if watch, do: Dokkit.Accounts.announce()
      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DokkitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
