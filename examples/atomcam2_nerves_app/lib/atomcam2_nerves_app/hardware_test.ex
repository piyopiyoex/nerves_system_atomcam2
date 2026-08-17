defmodule Atomcam2NervesApp.HardwareTest do
  @moduledoc """
  Brief, self-contained hardware checks for the dashboard's 動作確認 tab.

  Each function does a short, visible/audible action and returns quickly;
  the actual work runs in a spawned task so the caller (the HTTP request)
  is not blocked. These touch only peripherals that are safe to poke while
  the camera streams — the status LEDs (via `StatusLed`), the IR LED, and
  the speaker. The IR-cut filter and ISP day/night are intentionally left
  out because driving them fights camd and can stall the RTSP stream.
  """

  require Logger

  alias Atomcam2NervesApp.StatusLed

  @ir_led_gpio 26
  @ir_blinks 5
  # IR-cut filter H-bridge (same pins camd uses). Pulsed momentarily to
  # slide the mechanical filter, then released.
  @ircut_a_gpio 53
  @ircut_b_gpio 52
  @ircut_pulse_ms 300
  @announce_command "/usr/bin/atomcam2-boot-announce"

  @doc "Blink the blue status LED (GPIO 39) a few times."
  def blue_led, do: StatusLed.test(:blue)

  @doc "Blink the yellow status LED (GPIO 38) a few times."
  def yellow_led, do: StatusLed.test(:yellow)

  @doc """
  Blink the IR LED (GPIO 26). Invisible to the eye; check with a phone
  camera or watch the night-vision image brighten.
  """
  def ir_led do
    {:ok, _pid} = Task.start(fn -> blink_ir_led(@ir_blinks) end)
    :ok
  end

  @doc "Play the boot announcement (speaker + amp check)."
  def speaker do
    {:ok, _pid} =
      Task.start(fn -> System.cmd(@announce_command, [], stderr_to_stdout: true) end)

    :ok
  end

  @doc """
  Move the mechanical IR-cut filter in (`:on`, day — blocks IR) or out
  (`:off`, night — passes IR) by pulsing the H-bridge (GPIO 53/52)
  directly. This does NOT touch the ISP, so unlike night_vision it does
  not stall the RTSP stream.
  """
  @spec ircut(:on | :off) :: :ok
  def ircut(:on), do: ircut_pulse(1, 0)
  def ircut(:off), do: ircut_pulse(0, 1)

  defp ircut_pulse(a, b) do
    {:ok, _pid} =
      Task.start(fn ->
        setup_out(@ircut_a_gpio)
        setup_out(@ircut_b_gpio)
        gpio_write(@ircut_a_gpio, a)
        gpio_write(@ircut_b_gpio, b)
        Process.sleep(@ircut_pulse_ms)
        gpio_write(@ircut_a_gpio, 0)
        gpio_write(@ircut_b_gpio, 0)
      end)

    :ok
  end

  defp blink_ir_led(times) do
    setup_out(@ir_led_gpio)

    Enum.each(1..times, fn _ ->
      gpio_write(@ir_led_gpio, 1)
      Process.sleep(250)
      gpio_write(@ir_led_gpio, 0)
      Process.sleep(250)
    end)
  end

  defp setup_out(gpio) do
    root = "/sys/class/gpio/gpio#{gpio}"
    unless File.dir?(root), do: File.write("/sys/class/gpio/export", Integer.to_string(gpio))
    File.write(Path.join(root, "direction"), "out")
  end

  defp gpio_write(gpio, value) do
    File.write("/sys/class/gpio/gpio#{gpio}/value", Integer.to_string(value))
  end
end
