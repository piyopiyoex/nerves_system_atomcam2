defmodule Atomcam2NervesApp.Dashboard.View do
  @moduledoc """
  Renders the Collector's internal map as a single self-contained HTML
  page. The JSON API (`/status.json`) is the canonical representation;
  this is just a human-friendly view of the same data.

  Tabs (映像 / 状態 / ログ / 動作確認) sit in a left sidebar and are pure CSS
  via `:target` on the URL fragment. The default tab (映像) is rendered
  last so a following-sibling rule can show it when no fragment is set —
  this avoids `:has()`, which older browsers lack.

  Updates happen in place with no page reload, so there is no flicker and
  the chosen tab stays put: a little vanilla JS swaps the live image's
  `src` every 0.5 s and re-fetches only the 状態/ログ panels every two
  seconds (the snapshot is rate-limited server-side, so this cannot
  overload the camera).
  """

  @spec page(map()) :: String.t()
  def page(data) do
    """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>atomcam2</title>
      <style>
        body { font-family: sans-serif; margin: 0; background: #111; color: #ddd;
               display: flex; min-height: 100vh; }
        nav { display: flex; flex-direction: column; background: #1a1a1a;
              border-right: 1px solid #444; min-width: 6rem; }
        nav .brand { padding: .8rem .6rem; font-weight: bold; color: #ddd;
                     border-bottom: 1px solid #333; }
        nav a { padding: .8rem .6rem; color: #9cf; text-decoration: none;
                border-bottom: 1px solid #262626; }
        nav a:hover { background: #262626; }
        main { padding: 1rem; flex: 1; }
        .panel { display: none; }
        .panel:target { display: block; }
        /* Default tab: 映像 is rendered last, shown by default and hidden
           only when another panel is targeted (following-sibling rule, so
           no :has() needed). */
        #live { display: block; }
        #status:target ~ #live,
        #logs:target ~ #live,
        #hwtest:target ~ #live { display: none; }
        table { border-collapse: collapse; margin-bottom: 1rem; width: 100%; max-width: 640px; }
        caption { text-align: left; font-weight: bold; padding: .3rem 0; color: #9cf; }
        td { border: 1px solid #444; padding: .25rem .6rem; font-size: .9rem; }
        td:first-child { color: #aaa; width: 40%; }
        .logs td { font-family: monospace; font-size: .75rem; }
        a { color: #9cf; }
        .ops form { display: inline; }
        .ops button { background: #333; color: #ddd; border: 1px solid #666;
                      padding: .45rem 1rem; margin: 0 .6rem .6rem 0; cursor: pointer; }
        .snap img { width: 80%; max-width: 100%; border: 1px solid #444; display: block; }
        .snap { margin-bottom: 1rem; }
        .rtsp { color: #aaa; font-size: .85rem; word-break: break-all; }
      </style>
    </head>
    <body>
      <nav>
        <span class="brand">atomcam2</span>
        <a href="#live">映像</a>
        <a href="#status">状態</a>
        <a href="#logs">ログ</a>
        <a href="#hwtest">動作確認</a>
      </nav>
      <main>
        <section id="status" class="panel">#{status_panel(data)}</section>
        <section id="logs"   class="panel">#{logs_panel(data)}</section>
        <section id="hwtest" class="panel">#{hwtest_panel()}</section>
        <section id="live"   class="panel">#{live_panel(data)}</section>
      </main>
      <script>
        // Remember the selected tab across manual refreshes.
        (function () {
          try {
            if (location.hash) {
              localStorage.setItem('tab', location.hash);
            } else {
              var saved = localStorage.getItem('tab');
              if (saved) { location.replace(saved); }
            }
          } catch (e) {}
        })();
        window.addEventListener('hashchange', function () {
          try { localStorage.setItem('tab', location.hash || ''); } catch (e) {}
        });
        // Refresh the live image every 0.5 s without reloading (no flicker),
        // only while the 映像 tab is visible. The server still rate-limits
        // actual captures to @snapshot_min_interval_ms (1.5 s), so faster
        // polling here just narrows how stale the shown frame can be, not
        // how often camd actually re-captures.
        setInterval(function () {
          var img = document.getElementById('snap');
          var live = document.getElementById('live');
          if (img && live && live.offsetParent !== null) {
            img.src = '/snapshot.jpg?' + Date.now();
          }
        }, 500);
        // Refresh the 状態/ログ tables in place every 2 s — no reload, tab kept.
        setInterval(function () {
          fetch('/').then(function (r) { return r.text(); }).then(function (html) {
            var doc = new DOMParser().parseFromString(html, 'text/html');
            ['status', 'logs'].forEach(function (id) {
              var cur = document.getElementById(id), next = doc.getElementById(id);
              if (cur && next) { cur.innerHTML = next.innerHTML; }
            });
          }).catch(function () {});
        }, 2000);
        // Ajax operations (announce/reboot/hwtest/night): no page navigation,
        // browser's native Basic-auth prompt still fires on the 401 as with
        // a form POST. Status is shown inline (ops-status / hwtest-status)
        // instead of a redirected response page.
        window.postOp = function (url, confirmMessage, label, statusId) {
          if (confirmMessage && !confirm(confirmMessage)) return;
          var status = document.getElementById(statusId || 'ops-status');
          if (status) status.textContent = label + ': 実行中...';
          fetch(url, {method: 'POST'}).then(function (r) {
            return r.text().then(function (body) { return {ok: r.ok, body: body}; });
          }).then(function (res) {
            if (!status) return;
            status.textContent = res.ok ? (label + ': OK') : (label + ': 失敗 (' + res.body + ')');
          }).catch(function () {
            if (status) status.textContent = label + ': 通信エラー';
          });
        };
      </script>
    </body>
    </html>
    """
  end

  # -- panels ----------------------------------------------------------

  defp live_panel(data) do
    """
    <div class="ops">
      <button type="button" onclick="postOp('/night/on', null, '夜間 ON', 'live-status')">夜間 ON</button>
      <button type="button" onclick="postOp('/night/off', null, '夜間 OFF', 'live-status')">夜間 OFF</button>
      <button type="button" onclick="postOp('/night/auto', null, '夜間 自動', 'live-status')">夜間 自動</button>
    </div>
    <div class="snap">
      <img id="snap" src="/snapshot.jpg?#{:erlang.system_time(:second)}" alt="snapshot">
    </div>
    <p id="live-status" class="rtsp">&nbsp;</p>
    <p class="rtsp">RTSP: #{escape(rtsp_url(data))}</p>
    <p class="rtsp">App: #{escape(app_version(data))}  camd: #{escape(camd_version(data))}</p>
    """
  end

  defp status_panel(data) do
    section("camera", data.camera) <>
      section("system", data.system) <>
      section("memory", data.memory) <>
      section("network", data.network) <>
      section("firmware", data.firmware) <>
      section("storage", data.storage) <>
      "<p><a href=\"/status.json\">status.json</a></p>"
  end

  defp logs_panel(data) do
    logs_section(data.logs) <> announce_history(data.rtsp)
  end

  defp hwtest_panel do
    """
    <div class="ops">
      <button type="button" onclick="postOp('/test/blue', null, '青 LED 点滅', 'hwtest-status')">青 LED 点滅</button>
      <button type="button" onclick="postOp('/test/yellow', null, '黄 LED 点滅', 'hwtest-status')">黄 LED 点滅</button>
      <button type="button" onclick="postOp('/test/ir_led', null, 'IR LED 点滅', 'hwtest-status')">IR LED 点滅</button>
      <button type="button" onclick="postOp('/test/speaker', null, 'スピーカー(発声)', 'hwtest-status')">スピーカー(発声)</button>
      <button type="button" onclick="postOp('/test/ircut/on', null, 'IR-cut ON', 'hwtest-status')">IR-cut ON</button>
      <button type="button" onclick="postOp('/test/ircut/off', null, 'IR-cut OFF', 'hwtest-status')">IR-cut OFF</button>
      <button type="button"
              onclick="postOp('/reboot', '本当に再起動しますか?', '再起動', 'hwtest-status')">再起動</button>
    </div>
    <p id="hwtest-status" class="rtsp">&nbsp;</p>
    <table>
      <caption>GPIO / 周辺機器</caption>
      <tr><td>青 LED</td><td>GPIO 39 (active-low)</td></tr>
      <tr><td>黄 LED</td><td>GPIO 38 (active-low)</td></tr>
      <tr><td>IR LED</td><td>GPIO 26（肉眼不可・スマホカメラで確認）</td></tr>
      <tr><td>スピーカー</td><td>アンプ GPIO 63・「起動しました」を再生</td></tr>
      <tr><td>マイク</td><td>IMP_AI(8kHz/16bit/mono)。常時 RTSP 音声(audio/L16)として配信、単体テストボタンは廃止</td></tr>
      <tr><td>IR-cut フィルタ</td><td>GPIO 53/52 Hブリッジ・ON=昼(IR遮断) / OFF=夜(IR透過)</td></tr>
      <tr><td>夜間ビジョン</td><td>操作は「映像」タブへ移動。IR-cut + IR LED のみ(ISP 昼夜モードは呼ばない。RTSP を止めていた旧実装から修正済み)</td></tr>
    </table>
    <p>各テストは管理パスワード（利用者 admin）が必要です。</p>
    """
  end

  # -- helpers ---------------------------------------------------------

  defp rtsp_url(%{rtsp: %{url: url}}), do: url
  defp rtsp_url(_data), do: "unavailable"

  defp app_version(%{firmware: %{version: version}}) when is_binary(version), do: version
  defp app_version(_data), do: "unavailable"

  defp camd_version(%{camera: %{camd_version: version}}) when is_binary(version), do: version
  defp camd_version(_data), do: "unavailable"

  defp announce_history(%{announce_history: lines}) when is_list(lines) and lines != [] do
    rows = Enum.map_join(lines, "\n", &"<tr><td>#{escape(&1)}</td></tr>")
    "<table class=\"logs\"><caption>boot announce history</caption>#{rows}</table>"
  end

  defp announce_history(_rtsp), do: ""

  defp section(title, %{} = fields) do
    rows =
      Enum.map_join(fields, "\n", fn {key, value} ->
        "<tr><td>#{escape(key)}</td><td>#{escape(value)}</td></tr>"
      end)

    "<table><caption>#{title}</caption>#{rows}</table>"
  end

  defp section(title, other) do
    "<table><caption>#{title}</caption><tr><td>#{escape(other)}</td></tr></table>"
  end

  defp logs_section(%{tail: lines}) do
    rows = Enum.map_join(lines, "\n", &"<tr><td>#{escape(&1)}</td></tr>")
    "<table class=\"logs\"><caption>logs</caption>#{rows}</table>"
  end

  defp logs_section(other), do: section("logs", other)

  defp escape(value) when is_list(value), do: value |> Enum.map_join(", ", &escape/1)

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  rescue
    _exception -> inspect(value)
  end
end
