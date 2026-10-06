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

  pipeline :cors do
    plug DokkitWeb.Cors
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

    get "/password", SessionController, :password
    post "/password", SessionController, :change_password

    live_session :user, on_mount: {DokkitWeb.Auth, :user} do
      live "/", InboxLive
      live "/all", EverythingLive
      live "/jobs", JobsLive, :index
      live "/jobs/new", JobsLive, :new
      live "/s/:id", ServiceLive
      live "/logs", LogsLive
      live "/machines/new", EnrolLive
      live "/errors", ErrorsLive
      live "/errors/:id", ErrorsLive
      live "/deploys", DeploysLive, :deploys
      live "/versions", DeploysLive, :versions
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

  scope "/api", DokkitWeb do
    pipe_through [:api, :cors]

    post "/:project/envelope", IntakeController, :envelope
    options "/:project/envelope", IntakeController, :envelope
  end

  # App keys are write-only and ship inside browser pages, so these answer any origin.
  scope "/api/v1", DokkitWeb do
    pipe_through [:api, :cors]

    post "/report", IntakeController, :report
    post "/errors", IntakeController, :error
    get "/in/:key/job/:name/:event", IntakeController, :ping
    post "/in/:key/job/:name/:event", IntakeController, :ping
    options "/report", IntakeController, :report
    options "/errors", IntakeController, :error
    options "/in/:key/job/:name/:event", IntakeController, :ping
  end

  scope "/api/v1", DokkitWeb do
    pipe_through :api

    post "/enrol", IntakeController, :enrol
    put "/declare", IntakeController, :declare
    get "/ping", IntakeController, :hello
    post "/proposals", IntakeController, :propose
    post "/deploys", IntakeController, :deploy
    get "/checks", IntakeController, :checks
    get "/tasks/accepted", IntakeController, :accepted
    get "/program/:target", IntakeController, :program
    get "/work", IntakeController, :work
    post "/work/:run/output", IntakeController, :work_output
    post "/work/:run/result", IntakeController, :work_result

    get "/inbox", ApiController, :inbox
    get "/issues", ApiController, :issues
    get "/machines", ApiController, :machines
    get "/services", ApiController, :services
    get "/services/:id", ApiController, :service
    get "/services/:id/series", ApiController, :series
    get "/jobs", ApiController, :jobs
    get "/jobs/:id/runs", ApiController, :runs
    get "/logs", ApiController, :logs
    get "/deploys", ApiController, :deploys
    get "/errors", ApiController, :errors
    get "/errors/:id", ApiController, :error
    get "/rules", ApiController, :rules
    get "/tasks", ApiController, :tasks
    get "/task-runs", ApiController, :task_runs
    post "/tasks/:id/run", ApiController, :run_task
    get "/keys", ApiController, :keys
    post "/keys", ApiController, :add_key
    delete "/keys/:id", ApiController, :revoke_key
    get "/users", ApiController, :users
    post "/users", ApiController, :add_user
    delete "/users/:id", ApiController, :remove_user
    get "/machines/:id", ApiController, :machine
    get "/versions", ApiController, :versions
    get "/proposals", ApiController, :proposals
    post "/proposals/:id/accept", ApiController, :accept
    post "/proposals/:id/dismiss", ApiController, :dismiss
    post "/rules", ApiController, :add_rule
    put "/rules/:id", ApiController, :update_rule
    delete "/rules/:id", ApiController, :delete_rule
    put "/services/:id/routing", ApiController, :routing
    post "/services/:id/watch", ApiController, :watch
    post "/services/:id/unwatch", ApiController, :unwatch
    put "/services/:id/checks", ApiController, :checks
    put "/services/:id/hold", ApiController, :hold
    put "/services/:id/restart", ApiController, :restart
    post "/issues/bulk", ApiController, :bulk
    get "/issues/:id", ApiController, :issue
    post "/issues/:id/notes", ApiController, :note
    post "/issues/:id/snooze", ApiController, :snooze
    post "/issues/:id/unsnooze", ApiController, :unsnooze
    post "/issues/:id/acknowledge", ApiController, :acknowledge
  end
end
