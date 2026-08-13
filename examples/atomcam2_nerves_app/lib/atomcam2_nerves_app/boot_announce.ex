defmodule Atomcam2NervesApp.BootAnnounce do
  @moduledoc """
  Play the boot announcement once at application startup: three short
  beeps followed by 「起動しました。」 (one PCM file), with the infrared
  LED blinking five times on a one-second cycle in sync. On success, a
  second announcement follows: the device's eth0/wlan0 IPv4 addresses
  read out digit-by-digit (see `announce_ip/0`), built at runtime from
  small pre-synthesized clips under `/usr/share/atomcam2/digits/` (see
  docs/worklog/20260806-起動時IP発声の実装記録.md).

  Cold boots intermittently leave the audio driver broken
  (`IMP_AO_Enable = -1`, no /dev/dsp) even with the correct module load
  order, so playback retries every 30 seconds. Every attempt logs the
  player's step output, and the final outcome is appended to
  `/media/mmc/boot-announce-history.log` — the FAT boot partition, which
  is writable seconds after power-on, so the record survives even when
  power is cut before /data finishes its filesystem check — so the
  failure pattern can be tracked across boots: if a retry eventually
  succeeds the hardware just needed time, if all attempts fail the boot
  is permanently wedged and the module-load timing is to blame.

  The IP announcement can be toggled from an IEx session with
  `set_ip_announce/1`; the setting is written to the FAT boot partition
  so it persists across reboots (the fixed "起動しました" chime is
  unaffected and always plays). Call `announce_ip/0` directly to trigger
  it immediately without waiting for the next boot.
  """

  use Task, restart: :temporary

  require Logger

  @command "/usr/bin/atomcam2-boot-announce"
  @digits_dir "/usr/share/atomcam2/digits"
  @ip_announce_tmp_path "/tmp/camd-ip-announce.raw"
  @history_path "/media/mmc/boot-announce-history.log"
  @ip_announce_state_path "/media/mmc/ip-announce-enabled"
  @ir_led_gpio 26
  @ir_blinks 5
  @max_attempts 6
  @retry_delay_ms 30_000
  # Wait for CameraNative's module loading to surface the audio devices so
  # the IR blink starts together with the sound, not during the wait.
  @audio_wait_ms 25_000

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_options) do
    Task.start_link(&announce/0)
  end

  @doc "Whether the boot-time IP announcement is enabled. Defaults to true."
  @spec ip_announce_enabled?() :: boolean()
  def ip_announce_enabled? do
    case File.read(@ip_announce_state_path) do
      {:ok, content} -> String.trim(content) != "false"
      {:error, _reason} -> true
    end
  end

  @doc """
  Enable or disable the boot-time IP announcement. Persists to the FAT
  boot partition so it survives reboots; takes effect on the next boot.
  Call `announce_ip/0` directly to test the announcement right away.
  """
  @spec set_ip_announce(boolean()) :: :ok | {:error, File.posix()}
  def set_ip_announce(enabled?) when is_boolean(enabled?) do
    File.write(@ip_announce_state_path, if(enabled?, do: "true", else: "false"))
  end

  defp announce do
    attempt(1)
  rescue
    exception ->
      Logger.warning("boot announcement error: #{Exception.message(exception)}")
  end

  defp attempt(number) when number > @max_attempts do
    Logger.warning(
      "boot announcement gave up after #{@max_attempts} attempts (audio wedged this boot)"
    )

    record_history("failed after #{@max_attempts} attempts")
  end

  defp attempt(number) do
    if number == 1, do: wait_for_audio_devices(@audio_wait_ms)

    {:ok, _blink_pid} = Task.start(fn -> blink_ir_led(@ir_blinks) end)

    case System.cmd(@command, [], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("boot announcement played (attempt #{number})")
        if number > 1, do: Logger.info("announcement recovery detail: #{String.trim(output)}")
        record_history("ok on attempt #{number}")
        if ip_announce_enabled?(), do: announce_ip()

      {output, status} ->
        Logger.warning(
          "boot announcement attempt #{number} failed (#{status}): #{String.trim(output)}"
        )

        Process.sleep(@retry_delay_ms)
        attempt(number + 1)
    end
  end

  @doc """
  Play the IP announcement: "ゆうせん/むせん あいぴー <digits> ドット ...
  です" for each of eth0/wlan0 that currently has an address, concatenated
  into one temp raw file and played via the same player script (re-used
  so it gets the same audio-device checks; ATOMCAM2_BOOT_ANNOUNCE_SOUND
  overrides which file it plays). Silently does nothing if neither
  interface has an address. Callable directly from IEx to test on demand,
  independent of `set_ip_announce/1` (which only gates the automatic
  boot-time call).
  """
  @spec announce_ip() :: :ok
  def announce_ip do
    clip_names =
      [{"wired", ipv4_of("eth0")}, {"wireless", ipv4_of("wlan0")}]
      |> Enum.filter(fn {_label, ip} -> ip end)
      |> Enum.flat_map(fn {label, ip} -> [label, "ip"] ++ ip_digit_clips(ip) ++ ["desu"] end)

    case clip_names do
      [] ->
        :ok

      names ->
        audio = names |> Enum.map(&File.read!(clip_path(&1))) |> IO.iodata_to_binary()
        File.write!(@ip_announce_tmp_path, audio)
        play_ip_announcement()
    end
  rescue
    exception ->
      Logger.warning("boot IP announcement error: #{Exception.message(exception)}")
  end

  defp play_ip_announcement do
    case System.cmd(@command, [],
           env: [{"ATOMCAM2_BOOT_ANNOUNCE_SOUND", @ip_announce_tmp_path}],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("boot IP announcement played")

      {output, status} ->
        Logger.warning("boot IP announcement failed (#{status}): #{String.trim(output)}")
    end
  end

  defp ip_digit_clips(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.graphemes/1)
    |> Enum.intersperse(["dot"])
    |> List.flatten()
  end

  defp clip_path(name), do: Path.join(@digits_dir, name <> ".raw")

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

  defp wait_for_audio_devices(remaining_ms) when remaining_ms <= 0, do: :timeout

  defp wait_for_audio_devices(remaining_ms) do
    if File.exists?("/dev/dsp") and File.exists?("/dev/speakerctl") do
      :ok
    else
      Process.sleep(200)
      wait_for_audio_devices(remaining_ms - 200)
    end
  end

  # One line per boot, e.g. "2026-08-04 02:10:33Z up=41s ok on attempt 1".
  # The FAT partition is mounted by pre-run, so the first write normally
  # succeeds; the retry is belt and braces.
  defp record_history(result) do
    line =
      "#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_string()} " <>
        "up=#{uptime_seconds()}s #{result}\n"

    append_when_writable(line, 30)
  end

  defp append_when_writable(_line, 0), do: :ok

  defp append_when_writable(line, tries_left) do
    case File.write(@history_path, line, [:append]) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(10_000)
        append_when_writable(line, tries_left - 1)
    end
  end

  defp uptime_seconds do
    with {:ok, contents} <- File.read("/proc/uptime"),
         {seconds, _rest} <- Float.parse(contents) do
      trunc(seconds)
    else
      _other -> -1
    end
  end

  # One-second cycle: 500 ms on, 500 ms off. The IR light is invisible to
  # the naked eye but shows purple on a phone camera and lights up the
  # scene on the night-vision video.
  defp blink_ir_led(times) do
    gpio_root = "/sys/class/gpio/gpio#{@ir_led_gpio}"

    unless File.dir?(gpio_root) do
      File.write("/sys/class/gpio/export", Integer.to_string(@ir_led_gpio))
    end

    File.write(Path.join(gpio_root, "direction"), "out")
    File.write(Path.join(gpio_root, "active_low"), "0")

    for _blink <- 1..times do
      File.write(Path.join(gpio_root, "value"), "1")
      Process.sleep(500)
      File.write(Path.join(gpio_root, "value"), "0")
      Process.sleep(500)
    end

    :ok
  end
end
