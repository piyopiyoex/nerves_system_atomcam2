# 変更履歴

## 未公開

- Actually fix the intermittent missing `sprop-parameter-sets` in the
  RTSP SDP for good (the 2026-08-05 "GO handshake" entry below reduced
  but did not eliminate the race — see
  [docs/20260813_video信頼性_sprop捕捉機構特定_技術相談.md](docs/20260813_video信頼性_sprop捕捉機構特定_技術相談.md)
  for the full investigation, including two second-opinion rounds and a
  disproven hypothesis that camd's encoder only emits SPS/PPS once).
  Root cause: the very first RTSP `DESCRIBE` can race camd's first
  frame; if it wins, `v4l2rtspserver`'s SDP line is built empty and
  cached for that process's entire lifetime (never recomputed). Fixed
  with two changes: camd (VERSION 37) now retries a frame1 `write()`
  that fails with `ENOTTY` (no reader attached yet) for up to 5 s
  instead of silently dropping it, and `v4l2rtspserver` gained a local
  patch (`0004`→`0005`, `0005-sprop-startup-race-fix.patch`) that waits
  up to 3 s for the capture source to have SPS/PPS before building the
  SDP line. Verified on two independent physical units (7/7 consecutive
  reboots, sprop present and VLC decoding every time).
- Fix a self-inflicted RTSP restart loop: the existing sprop-liveness
  watchdog rebuilt the whole camd+v4l2rtspserver stack on any single
  missing-sprop check, which both re-rolled the (then still probabilistic)
  sprop race and re-triggered a few seconds of inherent restart-transition
  instability in v4l2rtspserver — looking like a permanent crash-loop but
  actually a self-amplifying loop. The watchdog now escalates "server
  unreachable" (fast, ~1 min) and "reachable but no sprop" (a ~5-minute
  grace period, since sprop-less video can often still decode via in-band
  NAL recovery) separately, and logs full diagnostic detail
  (connect/response/elapsed/sdp size/sprop) on every check. See
  [docs/20260813_v4l2rtspserver_epipeクラッシュループ_技術相談.md](docs/20260813_v4l2rtspserver_epipeクラッシュループ_技術相談.md).
- Add microphone audio to the RTSP stream. A new always-on daemon,
  `atomcam2-aicap`, polls the mic via libimp's `IMP_AI_*` API (the same
  8 kHz/16-bit/mono path the one-shot "record mic" hardware test used)
  and writes raw big-endian PCM into a FIFO; a local `v4l2rtspserver`
  patch (`0004-fifo-audio-source.patch`) adds an ALSA-free
  `FifoAudioCapture` source that publishes it as an `audio/L16` RTP
  subsession alongside the existing H.264 video, with no ALSA
  dependency (the control kernel has none). The one-shot "record mic
  (5s)" hardware-test button is retired in favor of listening to the
  live RTSP audio, since it can no longer coexist with the always-on
  capture (`IMP_AI` is exclusive). See
  [docs/20260812_RTSP_音声追加_提案書.md](docs/20260812_RTSP_音声追加_提案書.md).

> 既知の不具合(2026-08-04→2026-08-05 更新): (A) ナイトビジョン切替が
> H.264 を停止させる(有力仮説: `SetISPRunningMode` のインライン実行。
> IR-cut+IR LED のみに変更で緩和)、(B) camd の kill・ソフト再起動反復後に
> フレームが出ない(有力仮説: teardown 不足。SIGTERM ハンドラで緩和)、
> **(C) RTSP の sprop 間欠欠落 → 解決**(下記「GO ハンドシェイク」参照)。
> 詳細は [作業記録 2026-08-05](docs/20260805_作業記録.md)。

- Fix the intermittent missing `sprop-parameter-sets` in the RTSP SDP
  (problem C) without altering the stream. camd now waits for the RTSP
  server to be reading the loopback (a `/tmp/camd.go` handshake written by
  CameraNative) before `StartRecvPic`, so the first frame's SPS/PPS reaches
  the attached reader instead of being dropped with ENOTTY (v4l2loopback
  write fails until a reader attaches). v4l2rtspserver then repeats the
  parameter sets before every IDR by default, so the SDP reliably carries
  sprop. camd also runs a clean IMP teardown on SIGTERM (sigaction +
  SA_RESTART). Note: when RTSP "connects but shows no video" it is usually
  not the stream but RTP (UDP) routing — over plain IPSec the RTP
  destination is the client's off-subnet real IP; force RTSP-over-TCP in
  the player, or use L2TP/IPSec.
- Support multi-location Wi-Fi via build-time environment variables so an
  OTA carries the networks. `WifiProvisioning` captures `NERVES_WIFI_SSID`
  / `_2` / ... at compile time and `config/runtime.exs` merges them under
  the SD `nerves-provisioning.conf` (the SD file wins per key, so a device
  can still be re-pointed without a rebuild). No SSID or passphrase is
  hard-coded — the values come from the build host's environment.

- Add on-device JPEG snapshots and a dashboard preview. camd gains a
  JPEG encoder channel (same group as H.264, so the still carries the
  OSD overlay) captured on demand via `/tmp/camd.snap`; no H.264 decode
  and no ffmpeg needed — this is how the atomcam_tools web UI does it
  too. `CameraNative.snapshot/1` returns the JPEG path, and the
  dashboard shows it at `GET /snapshot.jpg` and inline on the page.
  Pitfalls found on this libimp: the JPEG channel must be channel 2 with
  a positive initial QP (−1 crashes in the quant-table setup) and must
  share the H.264 channel's buffer via `IMP_Encoder_SetbufshareChn` (a
  second full-res buffer exhausts rmem and crashes).
- Add night vision control. `CameraNative.night_vision(:on | :off |
  :auto)` and the dashboard buttons drive camd, which sets the ISP
  running mode (day/night), pulses the IR-cut filter (GPIO 53/52), and
  the IR LED (GPIO 26). Auto switches on the ISP total gain with
  hysteresis (night above ~8x, day below ~4x).

- Add dashboard operations (Phase 2): `POST /announce` plays the boot
  announcement and `POST /reboot` reboots the device, each behind a
  confirm dialog in the HTML. Reads stay anonymous; the POST routes
  require HTTP Basic auth (user `admin`) and are rejected until a
  password is set with `Dashboard.set_password/1` (persisted, compared
  with a constant-time SHA-256 check; `nil` removes it and disables the
  operations). The 401 sends a `WWW-Authenticate` header (charlist key,
  so inets emits the real header name) and Firefox/Chrome prompt for
  credentials. Verified on hardware: unauthenticated and wrong-password
  POSTs return 401, the browser buttons trigger the auth dialog, and
  announce and reboot run only when authenticated.

- Add the status dashboard (Phase 1 of the proposal): `GET /status.json`
  as the canonical machine-readable state (camera, rtsp, system, memory,
  network, firmware, storage, logs), `GET /` as an HTML view of the same
  data (inline CSS, meta refresh, no JavaScript), and `GET /healthz`.
  Served by OTP's `:inets` httpd on port 80 (configurable), JSON encoded
  with OTP's `:json` (nil normalized to null at the encoding layer). Off
  by default: `Dashboard.enable(true/false)` from IEx starts or fully
  terminates the server — a disabled dashboard has no open port and no
  cost — and the choice persists across reboots. Measured on hardware:
  +316 KB BEAM RSS while enabled, camera unaffected by request bursts.

- Fix the intermittent silent boot: about half of all boots (soft or
  cold alike) came up with the audio driver half-initialized — the codec
  probe succeeded but /dev/dsp was never registered and IMP_AO_Enable
  returned -1 for the whole boot, pointing at audio.ko's contiguous DMA
  allocation failing under late-boot memory fragmentation. The ISP and
  audio modules (tx_isp first, then audio and speaker_ctl) now load from
  `atomcam2-pre-run`, before the BEAM starts, while memory is pristine.
  Verified 5/5 soft reboots and 4/4 power-cut boots announcing on the
  first attempt; disable with `ATOMCAM2_PRE_RUN_AUDIO_MODULES=0`.
- Prepend three short beeps (2 kHz) to the boot announcement, retry
  playback every 30 seconds up to six times, and append one line per
  boot to `/media/mmc/boot-announce-history.log` (the FAT partition, so
  the record survives power cuts during the /data check) for tracking.
  The player's IMP_AO_* step output is kept in the log on failure.
- Start `v4l2rtspserver` only after camd signals loopback readiness via
  `/tmp/camd.ready`. The previous fixed delay raced camd's variable
  init; when the server opened the device before the writer's S_FMT,
  the SDP was published without sprop-parameter-sets and players could
  not decode the stream.
- Add an on-video debug overlay, off by default so operational video
  stays clean. camd renders a top-left panel of up to 14 lines x 80
  columns (public-domain Linux console 8x16 font; the IPU rejects OSD
  regions over ~1 MB, so the panel draws at 1x) from
  `/tmp/camd.info`, polled once a second; `CameraNative` writes an
  IEx-greeting-sized summary every three seconds when enabled — app
  version and slot, hostname, uptime, JST clock and NTP state, load
  average and CPU usage, memory (MemFree + Buffers + Cached stands in
  for MemAvailable on kernel 3.10), BEAM memory and process count,
  eth0/wlan0 addresses, camera phase, and /data usage. Toggle with
  `CameraNative.osd_debug(true/false)` (persisted in
  `/data/atomcam2-native-camera/osd-debug.conf`). A single-line
  `info <text>` control command also exists. Cheaper than an HTTP
  dashboard and with no new network surface.
- Blink the infrared LED (GPIO 26) five times on a one-second cycle
  while the boot announcement plays.
- Hide the OSD logo by default in camd itself instead of sending
  `logo off` after start, so the logo never flashes at startup.
  `logo on` via `/tmp/camd.ctl` still shows it.

- `/data` のファイルシステム検査を起動の重要経路から外す。異常電源断後、ext2 データ用パーティションの完全 `e2fsck` には数分かかり、以前は `nerves_runtime` の初期化処理として同期実行されるため、案内音、表示灯、ネットワーク、SSH、カメラのすべてを妨げていた。電源断後の測定では、現在は 29 秒でネットワークが応答し、48 秒で RTSP が公開される一方、検査は裏で継続する。既知の問題として、冷間起動では音声駆動処理が不完全なため、正しいモジュール順でも `/dev/dsp` がなく `IMP_AO_Enable -1` となり、音声案内が失敗する。ソフト再起動では安定して案内できる。検査を裏で動かせるよう、SSH ホスト鍵と `nerves_time` ファイルを FAT 起動用パーティション `/media/mmc` へ移し、sshd が安定したホスト鍵で早く起動し、時刻も早期に復元できるようにした。起動案内、状態表示灯、カメラは開始時に `/data` へ触れない。正常終了後の `e2fsck -p` 事前検査は約二秒で完了する。
- 生のカメラ常駐処理を `atomcam2-camd` としてルートファイルシステムへ含める。`atomcam2-camera` 小包が、以前の `/data/camd` 構築済みファイルを置き換える。実行時制御ファイルは `/data/camd.ctl` から `/tmp/camd.ctl` へ移し、カメラを `/data` から完全に独立させ、ファイルシステム検査中でも開始できるようにした。

- 状態表示灯で機器状態を示す。起動中は青を消灯し、黄を一秒ごとに二回点滅させる（100 ms 点灯、200 ms 消灯、100 ms 点灯、600 ms 消灯）。RTSP 公開後は黄を消灯し、青を点灯状態にして五秒ごとに二回だけ暗くする（100 ms 消灯、200 ms 点灯、100 ms 消灯、4600 ms 点灯）。両表示灯は負論理配線であり、sysfs の `active_low` が極性を揃える。`atomcam2-pre-run` は電源投入数秒後に両方を消灯する。BusyBox の `sleep` は一秒未満を扱えないため、新しい `StatusLed` GenServer が時間制御を担う。
- 起動時に OSD の印を隠す。`CameraNative` は camd 起動ごとに `/data/camd.ctl` へ `logo off` を送り、既定で表示される印だけを消す。時計表示は残る。

- 生のカメラ群を起動時に自動開始する。新しい `CameraNative` GenServer はカメラ用カーネルモジュールを読み込み、`camd`（libimp 取り込みと H.264 符号化を v4l2loopback へ出力）と `v4l2rtspserver` を MuonTrap 監督下で動かし、終了時に再開する。映像は `rtsp://<ip>:8554/video0_unicast` で公開する。システム小包化まで `camd` は `/data` にあり、開始時に存在を待つ。`/data/atomcam2-native-camera/auto-start.conf` に `enabled=false` を書けば無効化できる。ファイル欠落は有効を意味する。この配備では生方式が唯一のカメラ方式である。

- 起動準備完了を音声と表示灯で知らせる。アプリケーション起動時にスピーカーから「起動しました。」と案内し、青表示灯を三回点滅させた後、点灯状態にする。これは生方式だけを前提とし、IMP 音声鍵を保持する `iCamera_app` は動かさない。`atomcam2-boot-announce` は、まだ読み込まれていない場合に音声用カーネルモジュールを自ら読み込む。再生には新しい `atomcam2-aoplay` を使う。これは libimp `IMP_AO` を利用し、製造元 uClibc 道具鎖で構築済みで、原本は `package/atomcam2-boot-announce/` に置く。MicroSD 上の `atomcam2.env` で `ATOMCAM2_BOOT_ANNOUNCE=disabled` とすれば無効化でき、`ATOMCAM2_BOOT_ANNOUNCE_SOUND` で PCM を差し替えられる。

## 0.4.0 - 2026-08-03

- 複数の Wi-Fi 場所に対応する。`nerves-provisioning.conf` は番号なしの組に加え、`NERVES_WIFI_SSID_2` など番号付き SSID・合言葉組を受け付け、VintageNet は範囲内の設定済みネットワークへ接続する。同じ MicroSD を再構築せず複数場所で使え、FAT パーティションを編集して追加できる。空の合言葉は公開ネットワークを表す。

- 製造元カメラ連携で有線だけの配備に対応する。準備判定、事前検査のネットワーク確認、実行環境が報告する IPv4 は `wlan0` だけでなく `eth0` も受け付ける。Wi-Fi 接続がなく USB 有線 LAN だけで到達するカメラも開始できる。時刻同期も `wlan0` 固有ではなく、全体の接続状態を契機にする。

- 製造元カメラの符号化済み映像を任意で RTSP 公開する。事前読み込みした映像枠処理が符号化器出力を v4l2loopback へ複製し、`v4l2rtspserver` が再符号化なしで公開する。`/data/atomcam2-rtsp/auto-start.conf` に `enabled=true` を書くと有効になる。サーバーは製造元カメラ実行環境に追従し、停止時に共に停止する。
- `atomcam2-pre-run` から `v4l2loopback` を読み込み、製造元実行環境開始前にデバイスを用意する。`ATOMCAM2_VIDEO_LOOPBACK_DEVICES` と `ATOMCAM2_VIDEO_LOOPBACK_VIDEO_NR` で、作成数と番号を指定する。
- 圧縮形式で呼び出し側が指定した `sizeimage` を v4l2loopback が尊重するよう修正する。以前は生画像の形状から緩衝領域を計算し、実際の枠がはるかに小さい 1080p 映像に対して一緩衝領域あたり 7.91 MiB を確保し、`v4l2rtspserver` がその値を live555 の `OutPacketBuffer::maxSize` へ伝えていた。87 MiB の基板ではサーバー接続直後にメモリを使い切った。製造元実行環境と同時に、1920x1080 H.264、約 18 fps、約 950 kbps を実機確認した。
- `atomcam2-vendor-camera precheck` で loopback デバイス利用可能性を報告する。
- RTSP 映像枠の停止を観測可能にする。枠処理は転送ごとに生存確認ファイルを書き換え、`RtspServer` は、すべてが「running」と報告しているのに生存確認が進まない場合、記録と `status` へ警告する。HD 競合後に自然復旧する停止と、再起動が必要な停止は、処理一覧だけでは区別できない。これは観測だけを行い、自動復旧はしない。サーバー再開では映像枠のない loopback へ再接続するだけで、製造元実行環境は再起動なしに再開できず、映像枠欠落を理由に機器を再起動すると携帯アプリで正当に HD 閲覧中の利用者を追い出すためである。

- USB 有線 LAN 変換器による有線 LAN に対応する。制御カーネルで `r8152`、`usbnet`、`asix`、`ax88179_178a`、`cdc_ether`、`rndis_host` モジュールを構築し、atomcam_tools で確認済みの駆動処理群に合わせる。
- `atomcam2-pre-run` から Wi-Fi 駆動処理より前に呼ぶ `atomcam2-eth-driver` を追加する。種類別・製造元別の駆動処理を順に試し、進行を FAT 上の `atomcam2-eth-driver.env` へ報告する。`ATOMCAM2_PRE_RUN_ETH_DRIVER=0` で無効化できる。
- 事前実行とネットワーク確認の段階印へ、`eth0` の存在とアドレスを記録する。
- 見本アプリケーションで `vintage_net_ethernet` を使い、`eth0` を DHCP 設定する。VintageNet は有線経路を優先し、ケーブルや変換器がない場合は Wi-Fi へ戻る。
- 検証済みの製造元互換制御カーネルを変更せず出荷し続ける。Buildroot のカーネル構築は、vermagic が一致する読み込み可能モジュールを作るために存在するため、`mix upload` だけで有線ネットワークを有効にできる。Realtek RTL8152 変換器 `0bda:8152` で実機確認した。

## 0.3.0 - 2026-07-28

- ADR 0008 と、任意の製造元カメラ互換調査用の読み取り専用 `atomcam2-vendor-camera precheck` を追加した。
- Nerves の musl 利用者空間を置き換えず、製造元 uClibc 実行環境を動かすために必要な最小 BusyBox `chroot` を有効にした。
- 物理 v0.2.0 実現可能性調査で確認した、保護ファイルシステム、モジュール ABI、メモリ、監視タイマー、NAS ファイルシステムの結果を記録した。
- 既定無効の手動製造元カメラ互換実行環境に、明示的な `prepare`、`start`、`status`、`stop` を追加した。
- 製造元ファイルシステムを読み取り専用で維持し、私有設定と一時保管を `/data` 配下へ置き、選別デバイスだけを公開し、ネットワーク、マウント、モジュール読み込み、再起動、デバイス項目作成に関する製造元処理の権限を落とした。
- 必須の製造元補助処理、ネットワーク状態、SD カード検査が、実物監視タイマー、Wi-Fi 制御、MicroSD ブロックデバイスを見ずに成功する、限定した独立互換補助処理を追加した。
- 製造元ネットワーク、クラウド、SD 健全性、SD マウント初期化、上限内メモリ、子孫処理・マウント・IPC の停止、恒久モジュールの再起動復旧、Nerves Wi-Fi と監視タイマー所有の安定、ファームウェア検証を実機確認した。
- 標準 Atom 携帯アプリ、HD 生映像、録画再生、健全な記憶領域表示、`/data` 一時保管下の一分連続録画確定を確認した。
- 保護対象制御カーネルが NFS・CIFS をマウントできないことを確認し、完了録画用の任意 OTP SFTP 搬出処理を追加した。
- 鍵認証と登録済み NAS ホスト鍵を要求し、一時名と原子的名前変更で公開し、繰り返し可能に再試行し、局所再生用一時保管を上限付きで維持し、設定保持期間後に日付付き NAS 録画を削除する。
- ファームウェア検証、インターネット接続、時刻同期、既存互換事前検査後にカメラを開始する、明示的 `/data` 任意有効化を追加した。
- 自動カメラ開始を一起動一回に制限し、後の劣化を再起動や自動再開循環なしで報告する。
- 再起動後の古い製造元実行状態印を正規化し、候補起動と通常再起動の双方で、任意カメラ開始、ファームウェア検証、監視タイマー所有、Wi-Fi・SSH 安定、録画確定を確認した。
- 一時保管目標を超えても未搬出局所録画を保持し、大きさ一致の永続完了印を持つファイルだけを削除する。
- SFTP 利用者ルートを閉じ込め、通常一周期を二件に制限し、個々の OTP SSH/SFTP 操作へ期限を設け、一つの監督接続を周期間で再利用する。
- 既存 ext2 `/data` を読み書き可能でマウントする前にオフライン検査し、異常電源断をアプリケーション利用前に修復する。
- 閉じ込めた LMDE 7 接続先で、NAS への原子的公開、繰り返し可能な再試行、障害復旧、選択的 20 日保持、一時保管安全性、持続接続の後始末、カメラ到達性の維持を確認した。

## 0.2.0 - 2026-07-26

- 検証済み Atom Cam 2 制御カーネルと Flat SD 起動契約を維持しつつ、標準 fwup 媒体作成と `mix burn` 手順を採用した。
- 必要時作成、修復検査、工場出荷状態への初期化に対応する永続 `/data` パーティションを追加した。
- 不変の起動管理処理、二重化ファームウェア情報、A/B アプリケーション用スロット、健全性に基づく確定、監視タイマー復旧、巻き戻しを追加した。
- 標準 Nerves の状態、検証、巻き戻し、`prevent-revert`、工場出荷状態への初期化 API を連携した。
- 中断送信の後始末と進行報告を含む、検査済み Atom Cam 2 A/B 更新処理を通じた標準 SSH `mix upload` に対応した。
- ファームウェア認証を通常の Nerves 基準へ合わせた。SSH が更新権限を管理し、fwup と対象側検査が候補を検証し、公開者署名は任意とする。
- v0.1.0 から新 A/B 構成への移行では、取り外し可能媒体の完全導入を必須とした。

## 0.1.0 - 2026-07-18

- 公開可能なシステムと Atom Cam 2 独自道具鎖の成果物情報を追加した。
- Linux 3.10 向け VintageNet 互換定義をシステムの準備用ヘッダーへ移した。
- 見本アプリケーションが既定で公開済み成果物を使用し、明示的な局所システム上書きを持つようにした。
- 成果物作成、公開、隔離アプリケーション検証用の公開手順を追加した。
- 未検証の遠隔 fwup を拒否し、対応する更新経路として `mix atomcam2.install` を維持した。
- 最小 AtomCam2 Nerves システム原本の写しを作成した。
- 最初の節目を `ping nerves.local` と `ssh nerves.local` に絞った。
- Flat SD カード梱包手順を追加した。
- Wi-Fi、mDNS、SSH 用の最小見本 Nerves アプリケーションを追加した。
- 最初の SSH 用シェル補助処理は、Buildroot 小包で重複させず `rootfs_overlay` に置いた。
- SD 内容作成手順の選択肢解析と機器名検証を強化した。
- SD 導入・報告手順で選択肢値欠落を明確に失敗させた。
- 対象側の機器名ファイルが欠落・不正なら `nerves` を使用する。
- Wi-Fi 合言葉欠落を `nil` ではなく公開ネットワーク設定として扱う。
- BusyBox `head`、`sort`、`tr` への隠れた対象側依存を削除した。
- 既存の生成済み `nerves-provisioning.conf` があれば SD 梱包で再利用できるようにした。
- 機器名検証を厳しくし、危険な SD 梱包・導入ディレクトリ組み合わせを拒否した。
- 安全性に関わる元・出力・マウントディレクトリ比較前に、ホスト側パスを物理的に解決する。
- 現在の内部 Buildroot 道具鎖を使う際、`nerves-config` が期待するホスト側 `opt/ext-toolchain/bin` を作成する。
- 補助処理を `rootfs_overlay` から導入するため、古い `atomcam2-first-ssh` Buildroot 小包ディレクトリを削除した。
- カメラ、RTSP、WebUI、Samba、製造元実行環境の連携を後回しにした。
