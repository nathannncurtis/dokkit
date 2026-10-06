defmodule DokkitWeb.Router do
  use DokkitWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DokkitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DokkitWeb do
    pipe_through :browser

    live "/", InboxLive
  end

  scope "/api/v1", DokkitWeb do
    pipe_through :api

    post "/report", IntakeController, :report
    get "/in/:key/job/:name/:event", IntakeController, :ping
    post "/in/:key/job/:name/:event", IntakeController, :ping
  end
end
