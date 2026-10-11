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
    get "/login/code", SessionController, :code
    post "/login/code", SessionController, :check_code
    post "/logout", SessionController, :delete
    get "/setup", SessionController, :setup
    post "/setup", SessionController, :claim
  end

  scope "/", DokkitWeb do
    pipe_through [:browser, :require_user]

    get "/password", SessionController, :password
    post "/password", SessionController, :change_password
    get "/two-step", SessionController, :two_step
    post "/two-step", SessionController, :change_two_step

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
    get "/in/:key/job/:name/:event", IntakeController, :ping, log: false
    post "/in/:key/job/:name/:event", IntakeController, :ping, log: false
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
    get "/update", IntakeController, :update
    post "/update/result", IntakeController, :update_result
    get "/releases", ApiController, :releases
    get "/certificate", ApiController, :certificate
    put "/certificate", ApiController, :put_certificate
    delete "/certificate", ApiController, :delete_certificate
    get "/certificate/settings", ApiController, :get_certificate_settings
    put "/certificate/settings", ApiController, :put_certificate_settings
    post "/certificate/renew", ApiController, :renew
    put "/releases/:version/:file", ReleaseController, :put
    get "/releases/:version/:file", ReleaseController, :show
    delete "/releases/:version", ReleaseController, :delete
    post "/update-all", ApiController, :update_all
    get "/work", IntakeController, :work
    post "/work/:run/output", IntakeController, :work_output
    post "/work/:run/result", IntakeController, :work_result

    get "/inbox", ApiController, :inbox
    get "/day", ApiController, :day
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
    put "/services/:id/messages", ApiController, :keep_messages
    post "/jobs", ApiController, :add_job
    post "/apps", ApiController, :add_app
    put "/jobs/:id/timing", ApiController, :set_job_timing
    post "/tasks/:id/accept", ApiController, :accept_task
    post "/tasks/:id/dismiss", ApiController, :dismiss_task
    post "/machines/:id/update", ApiController, :update_program
    get "/alerts", ApiController, :alert_settings
    put "/alerts", ApiController, :set_alert_settings
    post "/alerts/test", ApiController, :test_alert
    get "/alerts/suggestions", ApiController, :suggestions
    post "/alerts/suggestions/:id/accept", ApiController, :accept_suggestion
    post "/alerts/suggestions/:id/dismiss", ApiController, :dismiss_suggestion
    get "/logs/archives", ApiController, :archives
    post "/logs/archives/:name/restore", ApiController, :restore_archive
  end
end
