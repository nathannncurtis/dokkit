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
      live "/machines/new", EnrolLive
      live "/deploys", DeploysLive
      live "/found", TasksLive, :found
      live "/tasks", TasksLive, :tasks
      live "/alerts", AlertsLive
      live "/settings", SettingsLive
    end
  end

  scope "/mcp", DokkitWeb do
    pipe_through :api

    post "/", McpController, :rpc
    get "/", McpController, :other
  end

  scope "/api/v1", DokkitWeb do
    pipe_through :api

    post "/report", IntakeController, :report
    post "/enrol", IntakeController, :enrol
    put "/declare", IntakeController, :declare
    get "/ping", IntakeController, :hello
    post "/proposals", IntakeController, :propose
    post "/deploys", IntakeController, :deploy
    get "/checks", IntakeController, :checks
    get "/work", IntakeController, :work
    post "/work/:run/output", IntakeController, :work_output
    post "/work/:run/result", IntakeController, :work_result

    get "/inbox", ApiController, :inbox
    get "/issues", ApiController, :issues
    get "/machines", ApiController, :machines
    get "/services", ApiController, :services
    get "/services/:id", ApiController, :service
    get "/jobs", ApiController, :jobs
    get "/jobs/:id/runs", ApiController, :runs
    get "/logs", ApiController, :logs
    get "/deploys", ApiController, :deploys
    get "/tasks", ApiController, :tasks
    get "/task-runs", ApiController, :task_runs
    post "/tasks/:id/run", ApiController, :run_task
    post "/issues/:id/snooze", ApiController, :snooze
    post "/issues/:id/unsnooze", ApiController, :unsnooze
    post "/issues/:id/acknowledge", ApiController, :acknowledge
    get "/in/:key/job/:name/:event", IntakeController, :ping
    post "/in/:key/job/:name/:event", IntakeController, :ping
  end
end
