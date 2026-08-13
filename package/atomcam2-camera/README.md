# atomcam2-camera

iCamera_app を置き換えるネイティブカメラデーモン `atomcam2-camd`
(ビルド済みバイナリ + ソース)を rootfs に載せる Buildroot パッケージ。
起動・監視は Elixir の `Atomcam2NervesApp.CameraNative` が行う。

## 動作

- パイプライン: sensor(GC2053) → ISP → FrameSource → OSD → H.264 →
  v4l2loopback(`/dev/video0`)書き出し
- 実行: `atomcam2-camd <frames> <loopback> <sensor> <i2c-addr> [bitrate-kbps]`
  (例: `atomcam2-camd 2000000000 /dev/video0 gc2053 0x37`)。
  第 1 引数はフレーム数上限。終了したら監督側が再起動する
- 実行時制御: **`/tmp/camd.ctl`** に 1 コマンドずつ書く
  (`clock on|off` / `logo on|off` / `info <text>` / `info off` /
  `snap` / `night on|off|auto` / `bitrate <kbps>` / `qp <min> <max>` /
  `clockpos <x> <y>` / `logopos <x> <y>` / `infopos <x> <y>` /
  `wb get|auto|daylight|cloudy|shade` / `wb manual <rgain> <bgain>` /
  `quit`)。/data 非依存にするため `/data/camd.ctl` から移した
- **JPEG スナップショット**: `/tmp/camd.snap` を touch すると 1 枚撮って
  `/tmp/camd.jpg` に出力(`snap` コマンドでも可)。**T31 の JPEG
  エンコーダチャネル**(H.264 と同一グループ、OSD 込み)を使う。
  ハマり: JPEG チャネルは **チャネル番号 2・initialQP 正の値(-1 は
  量子化テーブルでクラッシュ)** が必要。
  **解像度は H.264 側と同じフル解像度(現在 1920x1080)、ただし
  独立バッファ**(H.264 チャネルとはバッファを共有しない)。
  旧版(VERSION 29 まで)は `IMP_Encoder_SetbufshareChn` で H.264 と
  バッファを共有していたが、これがダッシュボードの頻繁なスナップ要求と
  H.264 チャネルの並行アクセスを引き起こし、無出力 wedge の原因になって
  いた(実機 A/B で実証、[docs/20260806_RTSPとWebダッシュボード競合_技術相談.md](../../docs/20260806_RTSPとWebダッシュボード競合_技術相談.md))。
  VERSION 30 で解像度を 640x360 に下げて独立バッファ化し解消(rmem に
  収まる範囲に縮小したので共有が不要になった)。VERSION 31 でフル解像度
  (1920x1080)を試したところ画面全体が紫がかる副作用が出て VERSION 32
  で 640x360 に戻したが、**真因は解像度ではなく ISP キャリブレーション
  ファイル欠落**(次項)と判明し、VERSION 34 でファイルを追加した上で
  VERSION 35 にてフル解像度へ再度戻し、実機 2 台で自然な発色を確認済み
  (詳細は
  [docs/20260806_ISPキャリブレーション欠落_技術相談.md](../../docs/20260806_ISPキャリブレーション欠落_技術相談.md))。
  **解像度を上げる場合は crash-free だけでなく画質(色)も必ず
  再検証すること**(rmem クラッシュとは別に、キャリブレーション不備の
  ような副作用が別途あり得る)。
- **frame1 の write() リトライ(VERSION 37, 2026-08-13)**: `got == 0`
  (まだ 1 フレームも配信できていない)の間だけ、loopback への
  `write()` が `ENOTTY`(読み手未接続)で失敗したら最大 5 秒リトライ
  してから諦める(`GO_PATH` 待ちは固定ヒューリスティックであり、実際に
  書き込みが通るかどうかの完了確認ではないため)。実機診断の結果、
  **T31 SDK のエンコーダは実際には毎回の IDR 直前に SPS/PPS を自然に
  含めている**ことが判明した(2026-08-05 時点の「起動時に一度だけ」
  という記述は誤りだった)ため、SPS/PPS を camd 側で手動 prepend する
  対策は不要と判明し撤回した。RTSP の SDP に `sprop-parameter-sets`
  が乗らない不具合の真因は camd 側ではなく `v4l2rtspserver` 側の
  SDP キャッシュ生成タイミング(最初の `DESCRIBE` が capture 開始前に
  来ると空のまま恒久キャッシュされる)にあり、
  `package/v4l2rtspserver/0005-sprop-startup-race-fix.patch` で対応
  済み。詳細な調査過程は
  [docs/20260813_video信頼性_sprop捕捉機構特定_技術相談.md](../../docs/20260813_video信頼性_sprop捕捉機構特定_技術相談.md)。
- **ナイトビジョン** `night on|off|auto`: ISP RunningMode(DAY/NIGHT)+
  IR-cut フィルタ(GPIO 53/52 の H ブリッジをパルス)+ IR LED(GPIO 26)。
  auto は `IMP_ISP_Tuning_GetTotalGain` を毎秒監視し、8x で夜・4x で昼に
  ヒステリシス切替
- **OSD**: 時計(右下、既定 ON)/ ロゴ(左下、**既定 OFF**)/
  **システム情報行(左上、`info <text>` で表示)**。info は printable
  ASCII 最大 40 文字、8x16 コンソールフォント(`osd_font8x16.h`、
  Linux kbd の default8x16 由来・パブリックドメイン)を 2 倍拡大で描画。
  内容は `CameraNative` がホスト名・IP・FW バージョンを 60 秒毎に送る
- 依存: `/atom/system/lib` の libimp ほか(実行時
  `LD_LIBRARY_PATH=/atom/system/lib:/atom/lib`)、カメラ系カーネル
  モジュール(tx_isp_t31 / sensor_gc2053_t31 / avpu / sinfo)
- **ISP キャリブレーションファイル(重要)**: `/etc/sensor/gc2053-t31.bin`
  (159,736 バイト)は本パッケージが `$(TARGET_DIR)/etc/sensor/` へ
  インストールする。libimp が `IMP_ISP_EnableTuning()` 系の内部処理で
  このパスを直接 open するため、camd.c 側からは触れない(パス変更 API
  は無い)。**これが無いと AWB が基準を失い、シーンによっては画面全体が
  マゼンタ/紫色になる**(2026-08-06 に実機 2 台で確認・修正、詳細は
  [docs/20260806_ISPキャリブレーション欠落_技術相談.md](../../docs/20260806_ISPキャリブレーション欠落_技術相談.md))。
  ファイルは機種共通(2 台の `/atom/system/etc/sensor/gc2053-t31.bin` を
  比較し bit-for-bit 一致を確認済み、SHA256
  `68f12813686112ea5579bfa746e1bca40a0628f2be8bf10340d0b9aea7e184c2`)。
  診断用に `wb get|auto|daylight|cloudy|shade|manual <r> <b>`(VERSION
  33 で追加)で `IMP_ISP_Tuning_{Get,Set}WB` を直接叩けるが、対症療法
  (手動ゲインは非対称なずれを追い切れない)であり本命はこのファイル。

## なぜビルド済みバイナリをコミットするか

実機の `/atom/system/lib/libimp.so`(uClibc 0.9.33.2 / GCC 4.7.2 ビルド)を
動的リンクするため、Buildroot のツールチェーン(musl)ではビルドできない
(`package/atomcam2-boot-announce/` の aoplay と同じ事情)。

## ビルド手順

1. ツールチェーン: Ingenic GCC 4.7.2 / uClibc 0.9.33.2
   (`mips-linux-uclibc-gnu-gcc`)
2. SDK ヘッダ: `cgrrty/Ingenic-SDK-T31-1.1.1-20200508` の `include/imp/`
   (エンコーダ API は 1.1.1 完全一致が必須。旧ヘッダは ABI 不一致で
   `invalid resolution(0x0)` になる)
3. OSD 用データ: atomcam_tools の ingenic_samples `libimp-samples`
   (`logodata_100x100_bgra.h` / `bgramapinfo.h`)
4. リンク用に実機の `/atom/system/lib/{libimp.so,libalog.so}` をコピー

```sh
mips-linux-uclibc-gnu-gcc -O2 -march=mips32r2 \
  -I<sdk-include> -I<libimp-samples> \
  -Wl,--dynamic-linker=/atom/lib/ld-uClibc.so.0 \
  camd.c -L<device-libs> -limp -lalog -lpthread -lm -lrt \
  -o atomcam2-camd
```

## 実装メモ(ハマりどころ)

- エンコーダは T31 1.1.1 の新 API(`IMP_Encoder_SetDefaultParam`)。
  ストリームは `IMPEncoderPack.offset` + リング折り返しで読む
- ループバックへは `VIDIOC_S_FMT`(H264)+ `STREAMON` 後にフレーム毎
  write。**書き手が S_FMT してから** v4l2rtspserver を起動すること
