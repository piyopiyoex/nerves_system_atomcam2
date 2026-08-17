defmodule Atomcam2NervesApp.Dashboard.Router do
  @moduledoc """
  httpd callback module routing the dashboard's three read-only routes.

  `GET /status.json` is the canonical API: the Collector's internal map
  encoded as JSON (OTP's `:json`). `GET /` renders the same map as HTML.

  Reads are anonymous. The POST operations (`/announce`, `/reboot`)
  require HTTP Basic auth — user `admin`, password set via
  `Dashboard.set_password/1` — and are rejected while no password is
  configured. CSRF protection is intentionally absent: reads have no
  side effects and writes are authenticated; the HTML buttons add a
  confirm dialog against accidental clicks.
  """

  require Record
  require Logger

  Record.defrecordp(:httpd_mod, :mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  alias Atomcam2NervesApp.CameraNative
  alias Atomcam2NervesApp.Dashboard.{Collector, Server, View}

  @announce_command "/usr/bin/atomcam2-boot-announce"

  # EWSAPI module callback.
  def unquote(:do)(mod_record) do
    method = httpd_mod(mod_record, :method)
    uri = mod_record |> httpd_mod(:request_uri) |> List.to_string() |> strip_query()

    case method do
      ~c"POST" -> authorized(mod_record, fn -> operate(uri) end)
      _other -> respond(method, uri)
    end
  end

  defp respond(~c"GET", "/status.json") do
    body = Collector.collect() |> jsonable() |> :json.encode() |> IO.iodata_to_binary()
    reply(200, "application/json", body)
  end

  defp respond(~c"GET", "/") do
    reply(200, "text/html; charset=utf-8", View.page(Collector.collect()))
  end

  defp respond(~c"GET", "/healthz") do
    reply(200, "text/plain", "ok")
  end

  defp respond(~c"GET", "/snapshot.jpg") do
    case CameraNative.snapshot() do
      {:ok, path} ->
        case File.read(path) do
          {:ok, jpeg} -> reply(200, "image/jpeg", jpeg)
          {:error, _reason} -> reply(503, "text/plain", "no snapshot")
        end

      {:error, _reason} ->
        reply(503, "text/plain", "snapshot unavailable")
    end
  end

  defp respond(_method, _uri) do
    reply(404, "text/plain", "not found")
  end

  # -- Phase 2: authenticated operations ------------------------------

  defp operate("/announce") do
    {:ok, _pid} = Task.start(fn -> System.cmd(@announce_command, [], stderr_to_stdout: true) end)
    Logger.info("Dashboard: announce requested")
    reply(200, "application/json", ~s({"status":"ok","message":"announce started"}))
  end

  defp operate("/reboot") do
    Logger.warning("Dashboard: reboot requested")

    {:ok, _pid} =
      Task.start(fn ->
        # Let the response reach the client first.
        Process.sleep(1_000)
        Nerves.Runtime.reboot()
      end)

    reply(200, "application/json", ~s({"status":"ok","message":"rebooting"}))
  end

  # Night vision: IR-cut + IR LED only (camd's apply_night/1 no longer
  # touches IMP_ISP_Tuning_SetISPRunningMode -- that used to be called
  # inline from the encode loop and could stall the H.264 stream; see
  # docs/worklog/20260804-ネイティブカメラ不具合の調査.md 問題A). Safe to expose here.
  defp operate("/night/" <> mode) when mode in ["on", "off", "auto"] do
    CameraNative.night_vision(String.to_existing_atom(mode))
    Logger.info("Dashboard: night vision #{mode}")
    reply(200, "application/json", ~s({"status":"ok","message":"night #{mode}"}))
  end

  # IR-cut filter: move it in/out by pulsing the H-bridge GPIO directly
  # (no ISP change), so it does not stall the RTSP stream.
  defp operate("/test/ircut/" <> mode) when mode in ["on", "off"] do
    Atomcam2NervesApp.HardwareTest.ircut(String.to_existing_atom(mode))
    Logger.info("Dashboard: hardware test ircut #{mode}")
    reply(200, "application/json", ~s({"status":"ok","message":"test ircut #{mode}"}))
  end

  # Hardware checks (動作確認 tab). These only poke the status LEDs, the IR
  # LED and the speaker — nothing that fights camd or stalls the RTSP stream.
  defp operate("/test/" <> what)
       when what in ["blue", "yellow", "ir_led", "speaker"] do
    case what do
      "blue" -> Atomcam2NervesApp.HardwareTest.blue_led()
      "yellow" -> Atomcam2NervesApp.HardwareTest.yellow_led()
      "ir_led" -> Atomcam2NervesApp.HardwareTest.ir_led()
      "speaker" -> Atomcam2NervesApp.HardwareTest.speaker()
    end

    Logger.info("Dashboard: hardware test #{what}")
    reply(200, "application/json", ~s({"status":"ok","message":"test #{what}"}))
  end

  defp operate(_uri), do: reply(404, "text/plain", "not found")

  defp authorized(mod_record, on_authorized) do
    header = mod_record |> httpd_mod(:parsed_header) |> List.keyfind(~c"authorization", 0)

    with {_key, ~c"Basic " ++ encoded} <- header,
         {:ok, decoded} <- Base.decode64(List.to_string(encoded)),
         ["admin", password] <- String.split(decoded, ":", parts: 2),
         true <- Server.password_valid?(password) do
      on_authorized.()
    else
      _no_or_bad_credentials ->
        body = "unauthorized"

        # inets renders an atom key as-is ("Www_authenticate"), which
        # browsers ignore — no Basic auth dialog appears. A string key is
        # emitted verbatim, so the header reaches the browser as the
        # standard WWW-Authenticate and Firefox/Chrome prompt for it.
        # inets emits a string (charlist) header key verbatim but crashes
        # on an Elixir binary key, so the field name must be a charlist.
        head = [
          {:code, 401},
          {~c"WWW-Authenticate", ~c"Basic realm=\"atomcam2\""},
          {:content_type, ~c"text/plain"},
          {:content_length, body |> byte_size() |> Integer.to_charlist()}
        ]

        {:proceed, [response: {:response, head, :binary.bin_to_list(body)}]}
    end
  end

  defp reply(code, content_type, body) when is_binary(body) do
    head = [
      code: code,
      content_type: String.to_charlist(content_type),
      content_length: body |> byte_size() |> Integer.to_charlist()
    ]

    {:proceed, [response: {:response, head, :binary.bin_to_list(body)}]}
  end

  defp strip_query(uri), do: uri |> String.split("?", parts: 2) |> hd()

  # OTP's :json encodes the atom nil as the string "nil"; JSON null is
  # the atom :null. Normalizing here keeps the Collector encoding-agnostic.
  defp jsonable(nil), do: :null
  defp jsonable(%{} = map), do: Map.new(map, fn {key, value} -> {key, jsonable(value)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(other), do: other
end
