defmodule Atomcam2NervesApp.CameraNative do
  @moduledoc """
  Boot integration for the native camera stack (Stage 5, first slice).

  Drives the iCamera_app-free pipeline: loads the camera kernel modules,
  then supervises `atomcam2-camd` (libimp capture + H.264 encode into
  v4l2loopback), `atomcam2-aicap` (libimp IMP_AI mic capture into a
  FIFO, see docs/20260812_RTSP_音声追加_提案書.md), and `v4l2rtspserver`
  as OS processes via `MuonTrap.Daemon`, restarting them if they exit.
  Everything needed lives in the rootfs, /atom, and /tmp, so the camera
  comes up even while a long /data filesystem check is still running.

  Auto-start is opt-out: `/data/atomcam2-native-camera/auto-start.conf`
  with `enabled=false` disables it; a missing (or not yet mounted) file
  means enabled, because native is the only camera mode in this
  deployment.
  """

  use GenServer

  require Logger

  @config_path "/data/atomcam2-native-camera/auto-start.conf"
  @camd_path "/usr/bin/atomcam2-camd"
  @loopback_device "/dev/video0"
  @libimp_path "/atom/system/lib/libimp.so"
  @driver_root "/atom/system/driver"
  @ld_library_path "/atom/system/lib:/atom/lib"

  # Effectively "run forever": camd exits after this many frames and the
  # daemon supervisor starts it again.
  @camd_frames "2000000000"
  @camd_args [@camd_frames, @loopback_device, "gc2053", "0x37"]

  # Mic capture daemon (package/atomcam2-aicap): continuously polls IMP_AI
  # and writes S16_BE PCM into a FIFO. v4l2rtspserver's ALSA-free
  # FifoAudioCapture (package/v4l2rtspserver/0004-fifo-audio-source.patch)
  # reads the other end and publishes it as an "audio/L16" RTP subsession.
  # Independent of camd/video readiness -- no camd_ready/camd_go gating.
  @aicap_path "/usr/bin/atomcam2-aicap"
  @audio_fifo_path "/tmp/camd-audio.fifo"
  @audio_sample_rate "8000"
  @aicap_args [@audio_fifo_path, @audio_sample_rate]
  @aicap_restart_ms 5_000

  # Device argument keeps v4l2rtspserver's own "[V4L2 device][,audio
  # device]" convention (see main.cpp's decodeDevice()); the part after
  # the comma is our FIFO path instead of an ALSA device name.
  @rtsp_args ["-Q", "2", "-P", "8554", "#{@loopback_device},#{@audio_fifo_path}"]

  # camd runtime control: one command per line written to the control
  # file; a snapshot request is a marker file camd polls, and the JPEG it
  # writes lands at @snapshot_path.
  @camd_ctl_path "/tmp/camd.ctl"
  @snapshot_request_path "/tmp/camd.snap"
  @snapshot_path "/tmp/camd.jpg"
  # Written once at camd startup with its ATOMCAM2_CAMERA_VERSION (camd.c's
  # CAMD_VERSION) -- lets the dashboard show which camd build is actually
  # running, distinct from the app/firmware version (mix.exs), which does
  # not change on a camd-only rebuild.
  @camd_version_path "/tmp/camd.version"
  # Measured (not nominal) encoder fps, rewritten by camd once per wall-clock
  # second from its actual frame-write count.
  @fps_path "/tmp/camd.fps"

  # The loopback writer has to set the H.264 format (S_FMT) before
  # v4l2rtspserver opens the device — otherwise the SDP is published
  # without sprop-parameter-sets and players cannot decode. camd creates
  # this marker once the loopback is ready; the RTSP server waits for it
  # (camd init takes a variable 10-20 s, so a fixed delay races).
  @camd_ready_path "/tmp/camd.ready"
  # Written once v4l2rtspserver is reading the loopback. camd waits for this
  # before StartRecvPic so the first frame's SPS/PPS reaches the (now
  # attached) reader instead of being dropped with ENOTTY — otherwise the
  # RTSP SDP intermittently comes up without sprop-parameter-sets.
  @camd_go_path "/tmp/camd.go"
  @camd_go_delay_ms 1_500
  @rtsp_poll_ms 2_000
  @poll_interval_ms 5_000
  # RTSP liveness watchdog: while the camera is running, check that the RTSP
  # port is actually accepting connections. v4l2rtspserver can die (or come
  # up unhealthy after a boot) without MuonTrap noticing the child is gone;
  # when that happens the camera pipeline is fine (snapshots still work) but
  # VLC shows nothing. After a couple of consecutive failures we rebuild the
  # whole stack (fresh camd + rtspserver, so sprop is captured again) — a
  # software self-heal, no power cycle.
  @rtsp_health_ms 20_000
  @rtsp_port 8554
  @rtsp_fail_threshold 2
  # Debug overlay on the video (top-left): an IEx-greeting-sized system
  # summary, refreshed every few seconds. On by default; toggle with
  # osd_debug/1 or the conf file (the persisted choice wins once set).
  @info_refresh_ms 3_000
  @info_path "/tmp/camd.info"
  @debug_conf_path "/data/atomcam2-native-camera/osd-debug.conf"
  @debug_default_enabled true

  # The vendor start sequence loads tx_isp first and audio right after;
  # loading audio.ko before tx_isp leaves the codec half-initialized
  # (IMP_AO_Enable returns -1 and /dev/dsp never appears), so all camera
  # and audio modules are loaded here, in this exact order. The boot
  # announcement waits for the audio devices instead of loading modules.
  @camera_modules [
    {"tx_isp_t31", "tx-isp-t31.ko", ["isp_clk=100000000"]},
    {"audio", "audio.ko", ["spk_gpio=-1"]},
    {"avpu", "avpu.ko", []},
    {"sinfo", "sinfo.ko", []},
    {"sensor_gc2053_t31", "sensor_gc2053_t31.ko", ["data_interface=1"]},
    {"speaker_ctl", "speaker_ctl.ko", []}
  ]

  defstruct phase: :not_checked,
            camd_pid: nil,
            rtsp_pid: nil,
            aicap_pid: nil,
            last_error: nil,
            cpu_sample: nil,
            rtsp_fails: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  The running camd binary's own VERSION (from `#{@camd_version_path}`,
  written by camd at startup), or `nil` if camd has not written it yet
  (not started, or a build old enough not to write the file).
  """
  @spec camd_version() :: String.t() | nil
  def camd_version do
    case File.read(@camd_version_path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  defp fps_text do
    case File.read(@fps_path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> "?"
    end
  end

  @doc """
  Enable or disable the on-video debug overlay. Persists across reboots
  (`#{@debug_conf_path}`); the overlay follows within a few seconds.
  """
  @spec osd_debug(boolean()) :: :ok | {:error, term()}
  def osd_debug(enable) when is_boolean(enable) do
    with :ok <- File.mkdir_p(Path.dirname(@debug_conf_path)) do
      File.write(@debug_conf_path, "enabled=#{enable}\n")
    end
  end

  # Minimum spacing between real captures. camd's JPEG encoder channel has
  # its own buffer since VERSION 30 (independent of the H.264 channel), but
  # this still caps how often camd re-captures/re-encodes so the dashboard's
  # polling (every 0.5 s) cannot needlessly spin the JPEG channel faster than
  # the live image actually needs to change. Requests inside this window are
  # served the cached JPEG instead of triggering a new capture.
  @snapshot_min_interval_ms 500

  @doc """
  Capture a JPEG snapshot from the camera's JPEG encoder channel and
  return its path once camd has written it. If a recent snapshot (younger
  than #{@snapshot_min_interval_ms} ms) already exists it is served as-is
  without asking camd for a new one. The image carries the same OSD
  overlay as the video. Returns `{:error, :timeout}` if camd does not
  produce it in time (e.g. camera not running).
  """
  @spec snapshot(timeout()) :: {:ok, Path.t()} | {:error, term()}
  def snapshot(timeout \\ 3_000) do
    if snapshot_fresh?() do
      {:ok, @snapshot_path}
    else
      _ = File.rm(@snapshot_path)

      with :ok <- File.write(@snapshot_request_path, "") do
        await_snapshot(System.monotonic_time(:millisecond) + timeout)
      end
    end
  end

  defp snapshot_fresh? do
    case File.stat(@snapshot_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} when size > 0 ->
        age_ms = (System.os_time(:second) - mtime) * 1_000
        age_ms >= 0 and age_ms < @snapshot_min_interval_ms

      _other ->
        false
    end
  end

  defp await_snapshot(deadline) do
    cond do
      File.exists?(@snapshot_path) ->
        {:ok, @snapshot_path}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(100)
        await_snapshot(deadline)
    end
  end

  @doc """
  Set night vision: `:on` forces night mode (mono, IR-cut out, IR LED
  on), `:off` forces day, `:auto` switches by the ISP gain. camd applies
  it within a second.
  """
  @spec night_vision(:on | :off | :auto) :: :ok | {:error, term()}
  def night_vision(mode) when mode in [:on, :off, :auto] do
    File.write(@camd_ctl_path, "night #{mode}\n")
  end

  @impl GenServer
  def init(_options) do
    # The daemons are linked; trap exits so a crashing camd or RTSP server
    # is restarted here with backoff instead of taking this server down.
    Process.flag(:trap_exit, true)
    # Single self-rescheduling timer (started once here so camd restarts
    # cannot stack additional timers).
    Process.send_after(self(), :update_info, 15_000)
    Process.send_after(self(), :rtsp_health, @rtsp_health_ms)
    {:ok, %__MODULE__{}, {:continue, :check}}
  end

  @impl GenServer
  def handle_continue(:check, state) do
    {:noreply, check(state)}
  end

  @impl GenServer
  def handle_info(:check, state) do
    {:noreply, check(state)}
  end

  def handle_info(:start_rtsp, state) do
    {:noreply, start_rtsp(state)}
  end

  def handle_info(:start_aicap, state) do
    {:noreply, start_aicap(state)}
  end

  def handle_info(:camd_go, state) do
    _ = File.write(@camd_go_path, "")
    {:noreply, state}
  end

  def handle_info(:rtsp_health, state) do
    Process.send_after(self(), :rtsp_health, @rtsp_health_ms)
    {:noreply, rtsp_health(state)}
  end

  def handle_info(:update_info, state) do
    {cpu_percent, cpu_sample} = cpu_usage(state.cpu_sample)

    cond do
      not alive?(state.camd_pid) ->
        :ok

      debug_overlay_enabled?() ->
        File.write(@info_path, debug_overlay_text(state, cpu_percent))

      File.exists?(@info_path) ->
        File.rm(@info_path)

      true ->
        :ok
    end

    Process.send_after(self(), :update_info, @info_refresh_ms)
    {:noreply, %{state | cpu_sample: cpu_sample}}
  end

  def handle_info({:EXIT, pid, reason}, %{camd_pid: pid} = state) do
    Logger.warning("camd exited (#{inspect(reason)}); restarting")
    # A crashed camd cannot remove its own readiness marker.
    File.rm(@camd_ready_path)
    schedule_check()
    {:noreply, %{state | camd_pid: nil, phase: :waiting}}
  end

  def handle_info({:EXIT, pid, reason}, %{rtsp_pid: pid} = state) do
    Logger.warning("v4l2rtspserver exited (#{inspect(reason)}); restarting")
    Process.send_after(self(), :start_rtsp, @poll_interval_ms)
    {:noreply, %{state | rtsp_pid: nil, phase: :degraded}}
  end

  def handle_info({:EXIT, pid, reason}, %{aicap_pid: pid} = state) do
    Logger.warning("atomcam2-aicap exited (#{inspect(reason)}); restarting")
    Process.send_after(self(), :start_aicap, @aicap_restart_ms)
    {:noreply, %{state | aicap_pid: nil}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  # RTSP watchdog: only meaningful once the stack is up (camd running and
  # the RTSP server expected). If the port is not accepting connections for
  # a couple of checks in a row, rebuild the whole stack so a fresh camd +
  # rtspserver re-run the SPS handshake — the camera pipeline itself may be
  # fine (snapshots work), only the RTSP publish is dead.
  defp rtsp_health(%{phase: :running} = state) do
    cond do
      not alive?(state.camd_pid) ->
        %{state | rtsp_fails: 0}

      rtsp_healthy?() ->
        %{state | rtsp_fails: 0}

      state.rtsp_fails + 1 >= @rtsp_fail_threshold ->
        Logger.warning("RTSP unhealthy (down or no sprop) while camera running; rebuilding stack")
        restart_stack()
        %{state | rtsp_fails: 0}

      true ->
        %{state | rtsp_fails: state.rtsp_fails + 1}
    end
  end

  defp rtsp_health(state), do: %{state | rtsp_fails: 0}

  # Healthy means: the RTSP server accepts a connection AND its SDP carries
  # sprop-parameter-sets. Just checking the port is not enough — the server
  # can be up yet publish an empty sprop (frame1 SPS missed), which leaves
  # VLC unable to decode. A DESCRIBE reflects exactly what a client sees.
  defp rtsp_healthy? do
    case :gen_tcp.connect(~c"127.0.0.1", @rtsp_port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        req =
          "DESCRIBE rtsp://127.0.0.1:#{@rtsp_port}/video0_unicast RTSP/1.0\r\n" <>
            "CSeq: 1\r\nAccept: application/sdp\r\n\r\n"

        healthy =
          case :gen_tcp.send(socket, req) do
            :ok ->
              sdp = rtsp_recv(socket, "", System.monotonic_time(:millisecond) + 1_500)
              String.contains?(sdp, "sprop-parameter-sets=")

            _error ->
              false
          end

        :gen_tcp.close(socket)
        healthy

      {:error, _reason} ->
        false
    end
  end

  defp rtsp_recv(socket, acc, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      byte_size(acc) > 4096 or now >= deadline ->
        acc

      true ->
        case :gen_tcp.recv(socket, 0, max(50, deadline - now)) do
          {:ok, data} -> rtsp_recv(socket, acc <> data, deadline)
          {:error, _reason} -> acc
        end
    end
  end

  # Kill both OS processes; the linked MuonTrap daemons exit and the {:EXIT}
  # handlers rebuild the stack from scratch (start_stack). Using killall (vs
  # stopping the daemons) also clears a child that MuonTrap has lost track of.
  #
  # SIGTERM (not -9): camd's handler runs the IMP teardown before exiting, so
  # the encoder is released cleanly and the fresh camd emits SPS at frame1
  # again — otherwise a SIGKILL leaves the encoder dirty and every rebuilt
  # rtspserver still comes up with an empty sprop (an endless restart loop).
  # camd's poll loop wakes at least once a second (PollingStream timeout), so
  # the flag is seen and teardown runs promptly even with no frames.
  defp restart_stack do
    _ = System.cmd("killall", ["atomcam2-camd", "v4l2rtspserver"], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp check(state) do
    cond do
      not enabled?() ->
        log_once(state, :disabled, "Native camera auto-start is disabled")
        schedule_check()
        %{state | phase: :disabled}

      not ready?() ->
        log_once(state, :waiting, "Native camera is waiting for #{inspect(missing())}")
        schedule_check()
        %{state | phase: :waiting}

      alive?(state.camd_pid) ->
        state

      true ->
        start_stack(state)
    end
  end

  defp start_stack(state) do
    File.rm(@camd_ready_path)
    File.rm(@camd_go_path)

    with :ok <- load_camera_modules(),
         :ok <- ensure_dsp_node(),
         {:ok, camd_pid} <- start_camd() do
      Process.send_after(self(), :start_rtsp, @rtsp_poll_ms)
      Logger.info("Native camera started (camd)")
      %{state | phase: :starting, camd_pid: camd_pid, last_error: nil}
      |> start_aicap()
    else
      {:error, reason} ->
        Logger.warning("Native camera start failed: #{inspect(reason)}")
        schedule_check()
        %{state | phase: :waiting, last_error: reason}
    end
  end

  defp start_rtsp(%{rtsp_pid: rtsp_pid} = state) when is_pid(rtsp_pid) do
    if alive?(rtsp_pid), do: state, else: start_rtsp(%{state | rtsp_pid: nil})
  end

  defp start_rtsp(state) do
    if File.exists?(@camd_ready_path) do
      start_rtsp_server(state)
    else
      # camd is still initializing (or restarting); check again shortly.
      Process.send_after(self(), :start_rtsp, @rtsp_poll_ms)
      state
    end
  end

  defp start_rtsp_server(state) do
    case MuonTrap.Daemon.start_link(
           "/usr/bin/v4l2rtspserver",
           @rtsp_args,
           log_output: :info,
           log_prefix: "v4l2rtspserver: ",
           stderr_to_stdout: true
         ) do
      {:ok, pid} ->
        Logger.info("Native camera RTSP server started on port 8554")
        # Release camd's encoder now that a reader is (about to be) attached,
        # so the first SPS/PPS/IDR is not dropped before the RTSP server reads.
        Process.send_after(self(), :camd_go, @camd_go_delay_ms)
        %{state | phase: :running, rtsp_pid: pid}

      {:error, reason} ->
        Logger.warning("v4l2rtspserver start failed: #{inspect(reason)}")
        %{state | phase: :degraded, last_error: reason}
    end
  end

  defp start_camd do
    MuonTrap.Daemon.start_link(
      @camd_path,
      @camd_args,
      env: [{"LD_LIBRARY_PATH", @ld_library_path}],
      log_output: :debug,
      log_prefix: "camd: ",
      stderr_to_stdout: true
    )
  end

  # Best-effort: audio is additive on top of the video pipeline, so a
  # failure here (missing binary on an older firmware slot, IMP_AI busy,
  # etc.) logs a warning and retries instead of failing camera startup.
  defp start_aicap(%{aicap_pid: aicap_pid} = state) when is_pid(aicap_pid) do
    if alive?(aicap_pid), do: state, else: start_aicap(%{state | aicap_pid: nil})
  end

  defp start_aicap(state) do
    case MuonTrap.Daemon.start_link(
           @aicap_path,
           @aicap_args,
           env: [{"LD_LIBRARY_PATH", @ld_library_path}],
           log_output: :debug,
           log_prefix: "aicap: ",
           stderr_to_stdout: true
         ) do
      {:ok, pid} ->
        Logger.info("Mic capture started (aicap)")
        %{state | aicap_pid: pid}

      {:error, reason} ->
        Logger.warning("atomcam2-aicap start failed: #{inspect(reason)}")
        Process.send_after(self(), :start_aicap, @aicap_restart_ms)
        state
    end
  end

  defp enabled? do
    case File.read(@config_path) do
      {:ok, contents} -> String.trim(contents) != "enabled=false"
      {:error, _reason} -> true
    end
  end

  defp ready?, do: missing() == []

  defp missing do
    checks = [
      {@loopback_device, &loopback_present?/0},
      {@libimp_path, fn -> File.exists?(@libimp_path) end}
    ]

    for {name, present?} <- checks, not present?.(), do: name
  end

  defp loopback_present? do
    match?({:ok, %File.Stat{type: :device}}, File.stat(@loopback_device))
  end

  defp load_camera_modules do
    Enum.reduce_while(@camera_modules, :ok, fn {name, file, args}, :ok ->
      if module_loaded?(name) do
        {:cont, :ok}
      else
        case System.cmd(
               "/sbin/insmod",
               [Path.join(@driver_root, file) | args],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            Logger.info("Loaded camera module #{name}")
            {:cont, :ok}

          {output, status} ->
            {:halt, {:error, {:insmod, name, status, String.trim(output)}}}
        end
      end
    end)
  end

  # devtmpfs has been seen skipping the OSS node even after a successful
  # codec probe; the driver registers char major 14 ("sound"), so create
  # the classic /dev/dsp (14, 3) ourselves when it is missing.
  defp ensure_dsp_node do
    if File.exists?("/dev/dsp") do
      :ok
    else
      case System.cmd("/bin/mknod", ["/dev/dsp", "c", "14", "3"], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Created /dev/dsp device node")
          :ok

        {output, status} ->
          Logger.warning("mknod /dev/dsp failed (#{status}): #{String.trim(output)}")
          :ok
      end
    end
  end

  defp module_loaded?(name) do
    case File.read("/proc/modules") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.any?(&String.starts_with?(&1, name <> " "))

      {:error, _reason} ->
        false
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check, @poll_interval_ms)
  end

  defp alive?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp debug_overlay_enabled? do
    case File.read(@debug_conf_path) do
      {:ok, contents} -> String.trim(contents) == "enabled=true"
      {:error, _reason} -> @debug_default_enabled
    end
  end

  # An IEx-greeting-sized system summary, one field per line. camd renders
  # up to 14 lines x 80 columns; content is not abbreviated.
  defp debug_overlay_text(state, cpu_percent) do
    lines = [
      "atomcam2_nerves_app #{firmware_version() || "?"}  slot=#{active_slot()}  camd=v#{camd_version() || "?"}",
      "Host: #{hostname()}  Uptime: #{uptime_text()}",
      "Clock: #{clock_text()}  NTP: #{ntp_text()}",
      "Load: #{loadavg_text()}  CPU: #{(cpu_percent && "#{cpu_percent}%") || "?"}",
      mem_line(),
      beam_line(),
      "eth0: #{ipv4_of("eth0") || "-"}  wlan0: #{ipv4_of("wlan0") || "-"}",
      "Camera: #{state.phase}  FPS: #{fps_text()}  RTSP: :8554/video0_unicast",
      data_line()
    ]

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.replace(~r/[^ -~\n]/, "?")
    |> Kernel.<>("\n")
  end

  defp active_slot do
    case Nerves.Runtime.KV.get("nerves_fw_active") do
      slot when is_binary(slot) -> String.upcase(slot)
      _other -> "?"
    end
  rescue
    _exception -> "?"
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _other -> "?"
    end
  end

  defp uptime_text do
    with {:ok, contents} <- File.read("/proc/uptime"),
         {seconds, _rest} <- Float.parse(contents) do
      total = trunc(seconds)
      days = div(total, 86_400)
      hours = rem(div(total, 3_600), 24)
      minutes = rem(div(total, 60), 60)
      secs = rem(total, 60)

      "#{days}d " <>
        (:io_lib.format(~c"~2..0B:~2..0B:~2..0B", [hours, minutes, secs])
         |> List.to_string())
    else
      _other -> "?"
    end
  end

  defp clock_text do
    DateTime.utc_now()
    |> DateTime.add(9 * 3_600, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S JST")
  end

  defp ntp_text do
    if NervesTime.synchronized?(), do: "sync", else: "unsync"
  rescue
    _exception -> "?"
  end

  defp loadavg_text do
    with {:ok, contents} <- File.read("/proc/loadavg"),
         [one, five, fifteen | _rest] <- String.split(contents) do
      "#{one} #{five} #{fifteen}"
    else
      _other -> "?"
    end
  end

  # Kernel 3.10 has no MemAvailable; approximate the reclaimable headroom
  # as MemFree + Buffers + Cached.
  defp mem_line do
    with {:ok, contents} <- File.read("/proc/meminfo") do
      find = fn key ->
        case Regex.run(~r/^#{key}:\s+(\d+)/m, contents) do
          [_line, kb] -> String.to_integer(kb)
          _other -> 0
        end
      end

      total = find.("MemTotal")
      free = find.("MemFree")
      available = free + find.("Buffers") + find.("Cached")

      "Mem: total #{div(total, 1024)}M  free #{div(free, 1024)}M  " <>
        "avail(approx) #{div(available, 1024)}M"
    else
      _other -> nil
    end
  end

  defp beam_line do
    memory = :erlang.memory()

    "BEAM: total #{div(memory[:total], 1_048_576)}M  " <>
      "processes #{div(memory[:processes], 1_048_576)}M  " <>
      "binary #{div(memory[:binary], 1_048_576)}M  " <>
      "procs #{:erlang.system_info(:process_count)}"
  end

  defp data_line do
    case System.cmd("df", ["-k", "/data"], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split("\n") |> Enum.at(1, "") |> String.split() do
          [_fs, size_kb, used_kb, _avail, percent | _rest] ->
            "/data: #{div(String.to_integer(used_kb), 1024)}M used of " <>
              "#{div(String.to_integer(size_kb), 1024)}M (#{percent})"

          _other ->
            "/data: not mounted"
        end

      _error ->
        "/data: ?"
    end
  rescue
    _exception -> "/data: ?"
  end

  # Overall CPU usage from consecutive /proc/stat samples: busy delta over
  # total delta. The first call only primes the sample.
  defp cpu_usage(previous_sample) do
    with {:ok, contents} <- File.read("/proc/stat"),
         ["cpu" | fields] <- contents |> String.split("\n", parts: 2) |> hd() |> String.split() do
      counters = Enum.map(fields, &String.to_integer/1)
      total = Enum.sum(counters)
      idle = Enum.at(counters, 3, 0) + Enum.at(counters, 4, 0)
      busy = total - idle

      case previous_sample do
        {previous_busy, previous_total} when total > previous_total ->
          percent = round((busy - previous_busy) * 100 / (total - previous_total))
          {min(percent, 100), {busy, total}}

        _other ->
          {nil, {busy, total}}
      end
    else
      _other -> {nil, previous_sample}
    end
  end

  defp ipv4_of(ifname) do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         {_name, options} <- List.keyfind(interfaces, String.to_charlist(ifname), 0),
         {a, b, c, d} <-
           options
           |> Keyword.get_values(:addr)
           |> Enum.find(&match?({_, _, _, _}, &1)) do
      "#{a}.#{b}.#{c}.#{d}"
    else
      _other -> nil
    end
  end

  defp firmware_version do
    case Nerves.Runtime.KV.get_active("nerves_fw_version") do
      version when is_binary(version) and version != "" -> "v" <> version
      _other -> nil
    end
  rescue
    _exception -> nil
  end

  # Waiting is polled every few seconds; only log when the phase changes.
  defp log_once(%{phase: phase}, phase, _message), do: :ok
  defp log_once(_state, _phase, message), do: Logger.info(message)
end
