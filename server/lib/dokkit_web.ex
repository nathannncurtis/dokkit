defmodule DokkitWeb do
  @moduledoc "What every controller, page and component starts from: `use DokkitWeb, :live_view`."

  def static_paths, do: ~w(assets css js vendor favicon.svg robots.txt)

  @doc "The error answer of the API."
  def fail(conn, status, code, message) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.json(%{error: %{code: code, message: message}})
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
      import DokkitWeb, only: [fail: 4]

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import DokkitWeb.Show

      alias DokkitWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DokkitWeb.Endpoint,
        router: DokkitWeb.Router,
        statics: DokkitWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
