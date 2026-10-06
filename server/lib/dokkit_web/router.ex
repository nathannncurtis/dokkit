defmodule DokkitWeb.Router do
  use DokkitWeb, :router
  import DokkitWeb.Auth, only: [fetch_user: 2, require_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DokkitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DokkitWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
    get "/setup", SessionController, :setup
    post "/setup", SessionController, :claim
  end

  scope "/", DokkitWeb do
    pipe_through [:browser, :require_user]

    live_session :user, on_mount: {DokkitWeb.Auth, :user} do
      live "/", InboxLive
      live "/all", EverythingLive
      live "/jobs", JobsLive, :index
      live "/jobs/new", JobsLive, :new
      live "/s/:id", ServiceLive
      live "/logs", LogsLive
      live "/alerts", AlertsLive
    end
  end

  scope "/api/v1", DokkitWeb do
    pipe_through :api

    post "/report", IntakeController, :report
    get "/ping", IntakeController, :hello
    get "/in/:key/job/:name/:event", IntakeController, :ping
    post "/in/:key/job/:name/:event", IntakeController, :ping
  end
end
