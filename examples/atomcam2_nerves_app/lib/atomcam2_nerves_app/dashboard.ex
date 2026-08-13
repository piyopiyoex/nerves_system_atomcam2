defmodule Atomcam2NervesApp.Dashboard do
  @moduledoc """
  Facade for the status dashboard (see docs/worklog/20260803-状態画面の設計.md).

  The dashboard is on by default; `enable(true)` starts the `:inets`
  httpd (default port 80) serving:

    * `GET /status.json`  — the canonical machine-readable state
    * `GET /`             — the same data rendered as HTML
    * `GET /healthz`      — liveness check
    * `POST /announce`    — play the boot announcement (auth required)
    * `POST /reboot`      — reboot the device (auth required)

  `enable(false)` terminates the whole server: the port closes and no
  dashboard code runs at all. The choice persists across reboots.

  Reads stay anonymous; the POST operations require HTTP Basic auth
  (user `admin`) with the password set here. Until a password is set,
  the operations are rejected.
  """

  alias Atomcam2NervesApp.Dashboard.Server

  @doc "Enable or disable the dashboard. Persists across reboots."
  @spec enable(boolean()) :: :ok | {:error, term()}
  defdelegate enable(enable), to: Server

  @doc "Whether the dashboard HTTP server is currently running."
  @spec enabled?() :: boolean()
  defdelegate enabled?(), to: Server

  @doc """
  Set the password for the POST operations (HTTP Basic auth, user
  `admin`). Persists across reboots. Pass `nil` to remove the password,
  which disables the operations again.
  """
  @spec set_password(String.t() | nil) :: :ok | {:error, term()}
  defdelegate set_password(password), to: Server
end
