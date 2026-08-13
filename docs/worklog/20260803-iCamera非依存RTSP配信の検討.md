# 2026-08-03 iCamera 非依存 RTSP 配信の検討

## 文書情報

- 日付: 2026-08-03
- 種別: 設計検討
- 状態: 検討完了
- 位置づけ: 当時の調査、実装、検証を残す記録。現在の仕様は上位文書を優先する。
- 現行資料: [構成](../構成.md) / [運用](../運用.md)

ベンダーアプリ `iCamera_app` を使わずに RTSP 配信を実現するための、
実行可能な実装提案。方式 B(ネイティブ実装)の具体化であり、8/2 以降の
実機調査で判明した事実を反映して経路と手順を確定させたもの。

関連: [カメラ参照機能スクラッチ実装 提案書](20260802-カメラ参照機能の試作計画.md)
(全体構想)、
[ネイティブカメラ実装 技術相談](20260803-ネイティブカメラ実装の調査.md)
(初期化停止の切り分け)

## なぜ iCamera_app を外すか

現行の RTSP は `iCamera_app`(ブラックボックス)のエンコード出力を
LD_PRELOAD フックで横取りしている。この依存が次の制約を生む。

- モバイルアプリの HD/SD 切り替えでエンコーダチャンネルが競合し、フレーム
  供給が止まる。繰り返すとパイプライン全体が停止し**自動復旧しない**
- 解像度・fps・ビットレート・チャンネルを一切制御できない
- `iCamera_app` は RSS 18MB を消費し、87MB 機のメモリを圧迫する

映像パイプラインを自前で持てば、いずれも根本解決する。

## 鍵となる着眼点: 配信半分は再利用できる

「iCamera_app を外す」= パイプライン全体の作り直し、ではない。現行構成は
2 段に分かれる。

```text
[前段] iCamera_app → libvideo-hook.so → /dev/videoN   ← ここだけ置き換える
[後段] /dev/videoN(v4l2loopback)→ v4l2rtspserver → RTSP   ← そのまま再利用
```

**後段(v4l2loopback + v4l2rtspserver)は実機で動作実績があり、そのまま使える。**
必要なのは前段、すなわち **libimp を自前で駆動して `/dev/videoN` にエンコード
済みフレームを書き込むネイティブプロセス**を作ることだけ。これにより開発
範囲が大幅に狭まる。

## 提案アーキテクチャ

```text
Nerves（musl / soft-float）
  ├── CameraNative GenServer（監督・死活監視・自動再起動）
  │     socket / 状態ファイル（ABI 非依存のバイト列でやり取り）
  ▼
atomcam2-camera（uClibc / hard-float、実機の libimp.so を動的リンク）
  ├── IMP_System_Init → ISP → sensor → framesource → encoder（libimp 経由）
  └── エンコード済み H.264/H.265 を /dev/video0 へ write()
        │
        ▼
  /dev/video0（v4l2loopback、既存）→ v4l2rtspserver（既存）→ RTSP :8554
```

- **前段の置き換え**: `atomcam2-camera` が libimp を駆動し、フレームを
  loopback へ書く。書き込み先とフォーマットは現行フックと同一のため、
  後段は無改修
- **ABI の分離**: musl/soft-float の Nerves と hard-float の libimp は
  **別プロセス**にすれば同居できる(プロセス境界で ABI は消える)。
  やり取りは loopback(バイト列)と状態ファイルのみ
- **監督**: `CameraNative` GenServer が起動・ヘルス監視・自動再起動を担う。
  停止を検知して**自前で再起動できる**(ベンダーアプリと違い再開に
  リブートが不要になる見込み)。既存の心拍監視(`RtspServer`)の仕組みも
  そのまま活きる

## 実機で確認済みの前提(すべて揃っている)

| 部品 | 実機での所在 | 状態 |
| --- | --- | --- |
| センサー | `sensor_gc2053_t31.ko`(GC2053、I2C `0x37`) | 確認済み |
| ISP | `tx_isp_t31.ko` | 確認済み |
| エンコーダ | `avpu.ko` | 確認済み |
| libimp | `/atom/system/lib/libimp.so`(1.1.1) + `libalog` / `libsysutils` | 確認済み |
| uClibc ランタイム | `/atom/lib/`(0.9.33.2、`ld-uClibc.so.0` 一式) | 確認済み |
| ISP チューニング | `/atom/system/etc/sensor/gc2053-t31*.bin` | 確認済み |
| デバイスノード | `/dev/tx-isp`、`/dev/isp-m0`、`/dev/avpu`、`/dev/framechan0-2` | **iCamera_app なしで、モジュール insmod だけで生成されることを確認済み** |
| 後段 | v4l2loopback + v4l2rtspserver | 実機で配信実績あり |

**iCamera_app を止めた状態でカメラモジュールを手動ロードし、デバイスノードが
生成されることは検証済み**。ハードウェア面の成立性は確認できている。

## 現在の障害と、その解決策(調査で判明)

自前プログラム(Ingenic 公式サンプル)は `IMP_System_Init` 付近で停止する。
調査で原因を 2 段階に絞り込んだ。

1. **float ABI 不一致 → 解決済み**。Nerves の musl は soft-float、libimp は
   hard-float で同居できず `Bus error` になっていた。hard-float の
   ツールチェーンでビルドして解消
2. **libimp と実機環境のビルド系統不一致 → 未解決の本命**。リンクした
   ingenic-lib の libimp は **glibc / GCC 5.4.0** だったが、実機の libimp は
   **uClibc / GCC 4.7.2**。Ingenic SDK は OEM ごとに libimp・tx-isp・
   センサドライバが改変され、SDK 番号(1.1.1)が同じでも互換とは限らない

**解決策(セカンドオピニオンとも一致)**: **実機の `/atom/system/lib/libimp.so`
を、実機の uClibc ランタイムに合わせてそのまま使う。** これにより実機の
tx-isp モジュールとの整合性が保証される。動作しない場合でも「SDK の違い」を
原因候補から外せる。

## 実証結果(2026-08-03 追記): フェーズ 1 完了 = GO

本提案のフェーズ 1(実機 libimp で 1 ストリーム取得)を実機 192.168.1.77 で
完了した。詳細は [作業記録 §9](20260803-ネイティブカメラ移行の作業記録.md) と
[方式B推進判断](20260803-ネイティブ方式採用の判断.md)。

- **ビルド**: `mips-linux-uclibc-gnu-gcc`(Dafang mips-gcc472)で、実機の
  `libimp.so`/`libalog.so`/`libsysutils.so` を動的リンク。interpreter を
  `-Wl,--dynamic-linker=/atom/lib/ld-uClibc.so.0` で実機 uClibc 0.9.33.2 に
  向けて解決(提案時に懸念した SONAME/リンカパスの食い違いはこの指定で解消)。
- **ISP + センサ**: `IMP_ISP_Open/AddSensor/EnableSensor/System_Init/EnableTuning`
  全て 0。GC2053 が通電。
- **エンコード**: FrameSource(1920x1080 NV12)→ H.264 で 60 フレーム取得。
  先頭 SPS→PPS→IDR の正しい H.264。
- **想定との差分**: エンコーダ API が T31 **1.1.1 の新 API** で、旧サンプル
  ヘッダとは ABI 非互換だった(`invalid resolution(0x0)`)。正しい 1.1.1
  ヘッダ(`cgrrty/Ingenic-SDK-T31-1.1.1-20200508`)+ `IMP_Encoder_SetDefaultParam`
  + `IMPEncoderPack.offset` 読み出しで解決。

### フェーズ 2 も完了 = GO(loopback → RTSP + メモリ実測)
エンコード出力を `/dev/video0`(v4l2loopback)へ現行フックと同じ作法で書き出し、
既存の `v4l2rtspserver` で配信。外部からの RTSP DESCRIBE が `200 OK` +
`H264/90000` + native 生成の `sprop-parameter-sets`(SPS/PPS)を返し、**後段
(loopback + v4l2rtspserver)は無改修で native ソースに載る**ことを実証した。
- **メモリ実測**: native 常駐プロセスの VmRSS は **初期化直後 1.36MB → 定常
  1.55MB**。本見積もり(下記「メモリ所要量の見積もり」)の 3–6MB を下回った。
  ベンダー三点(約 25MB)を約 1.5MB に置換 → **平常時 RSS 約 23MB 削減**の
  見込み(配信後段 v4l2rtspserver 約 13MB は両モード共通で据え置き)。
- **注意**: ベンダー停止後も旧 `v4l2rtspserver` が 8554 を占有し続けると新規
  サーバがバインドできない。切替時に既存サーバの停止を先行させること(フェーズ 3
  の監督・排他切替で担保する)。

## 段階計画

### フェーズ 1: PoC(実機の libimp.so で 1 ストリーム取得)— ✅ 完了(上記)

1. **uClibc ツールチェーンを用意**(Bootlin の mips32el uclibc、hard-float)。
   ただし実機は uClibc **0.9.33.2** の古い版で、Bootlin は uClibc-ng。
   SONAME/動的リンカのパスが食い違う場合は、**実機の `/atom/lib` の uClibc
   ランタイムを sysroot として使う**(chroot 実行または `--sysroot` 指定)
2. 実機の `libimp.so` / `libalog.so` / `libsysutils.so` を動的リンクして、
   最小のエンコーダ(`IMP_System_Init` → sensor → framesource → encoder →
   1 本の H.264)をビルド
3. カメラモジュールを手動ロードし、ベンダーアプリ停止状態で実行。
   **`IMP_System_Init` を通過してフレームが取れることを確認**
   (デバッグは `fprintf(stderr,...)` + `fflush` で停止位置を追う。stdout は
   フルバッファリングされるため使わない)
4. 画質(チューニングデータ適用)・CPU・メモリを実測

### フェーズ 2: loopback へ接続 — ✅ 完了(上記「実証結果」参照)

- エンコード済みフレームを `/dev/video0` へ書き込む(現行フックと同じ流儀)。
  後段(v4l2rtspserver)は無改修で RTSP 配信に載る<br>
  → 実機で RTSP DESCRIBE 200 OK + native SPS/PPS を確認、native 常駐 RSS 約 1.5MB。

### フェーズ 3: Buildroot パッケージ化と監督

- `package/atomcam2-camera`(uClibc ビルド、実機 libimp を実行時に参照)
- `CameraNative` GenServer(起動・ヘルス監視・自動再起動)
- ベンダーモード(現行)とネイティブモードの排他切り替え(ISP は同時に
  1 利用者のみ)。`/data` の設定で選択
- precheck・文書・ADR 追記

## 再利用するもの / 新規に作るもの

| 区分 | 内容 |
| --- | --- |
| 再利用 | v4l2loopback、v4l2rtspserver、`atomcam2-video-loopback`(起動時ロード)、`RtspServer` の心拍監視、ベンダー資産の chroot マウント機構 |
| 新規 | `atomcam2-camera`(libimp 駆動プロセス)、`CameraNative` GenServer、uClibc ビルドの仕組み |

## 失うもの(明示)

ネイティブモード動作中は **Atom モバイルアプリ・クラウド連携が使えない**
(ISP を専有するため)。両立が必要な利用者はベンダーモードを選ぶ。連続録画・
NAS 転送はネイティブ側でも実装可能。

## リスクと検証項目

| リスク | 内容 | 対応 |
| --- | --- | --- |
| uClibc 版差 | 実機 0.9.33.2 と Bootlin uClibc-ng の SONAME 不一致 | 実機 `/atom/lib` を sysroot に。最悪 chroot 実行 |
| libimp と .ko の整合 | 実機 libimp と実機 tx-isp なら整合するはず | フェーズ 1 で確認。これでも駄目なら別要因に切り分け |
| ベンダー独自の前処理 | `ver-comp` 等が ISP 初期化に必要な可能性 | `ver-comp` の open/ioctl/`/proc` アクセスを観察し、必要な初期化を再現 |
| メモリ | ネイティブプロセスの実フットプリント | フェーズ 1 で実測。`iCamera_app`(18MB)より小さい見込み |
| 音声 | 本カーネルは ALSA 非搭載 | libimp の AI API は ALSA 非依存の可能性。まず映像のみ |
| ライセンス | ベンダー .ko / libimp / チューニングデータ | **再配布せず**、実機 `/atom` から実行時に読む(現行ベンダーモードと同じ整理) |

## 構築内容とメモリ所要量の見積もり

### 構築内容(新規 / 再利用)

| 区分 | 成果物 | 実体 / 概算サイズ |
| --- | --- | --- |
| 新規・実行体 | `atomcam2-camera`(libimp 駆動、uClibc/hard-float) | rootfs 上 1〜2MB。Ingenic 公式サンプルの静的版が約 1.9MB |
| 新規・監督 | `CameraNative` GenServer(Elixir) | BEAM 内。メモリ増は無視できる程度 |
| 新規・ビルド | uClibc ツールチェーン + 実機 libimp 参照の仕組み | ビルドホスト側のみ。デバイスには載らない |
| 再利用 | `v4l2loopback.ko`(46KB)、`v4l2rtspserver`(205KB)、`atomcam2-video-loopback`、`RtspServer` 心拍監視 | 既に rootfs に存在。無改修 |

デバイスに新たに載るのは実質 **`atomcam2-camera` バイナリ 1〜2MB のみ**。
後段は既存資産をそのまま使う。

### メモリ所要量: 前提となる重要事実

カーネル起動引数は `mem=92M@0x0 rmem=36M@0x5c00000`。**Linux が管理する
87.7MB とは別に、ISP/VPU 用に 36MB が予約(rmem)されている。**
エンコーダのフレームバッファ・ISP のワークバッファはこの rmem 側に確保され、
**プロセスの RSS(= 87MB 側の消費)には現れない**。

つまり `iCamera_app` の RSS 約 18MB は、フレームバッファではなく
**アプリ自身のユーザー空間**(クラウド連携、アプリ通信、内蔵 RTSP、動体検知
など)が大半を占める。ネイティブ実装はこれらを持たないため、同じ映像を
出しても RSS は大幅に小さくなる。

### 現行(ベンダーモード)の実測 RSS(87MB 側)

| プロセス | RSS | 備考 |
| --- | --- | --- |
| `beam.smp` | 約 31MB | Nerves 本体。両モードで不変 |
| `iCamera_app` | 約 18MB | ベンダーアプリ本体 |
| `assis` | 約 2MB | ベンダー補助 |
| `hl_client` | 約 0.5MB | ベンダー補助 |
| `v4l2rtspserver` | 約 2.5MB | 後段(再利用) |
| **ベンダー 3 点計** | **約 20.5MB** | 置き換え対象 |

### ネイティブモードの見積もり RSS(87MB 側)

| プロセス | 見積もり RSS | 根拠 |
| --- | --- | --- |
| `beam.smp` | 約 31MB | 不変 |
| `atomcam2-camera` | **約 3〜6MB** | libimp(.so の code マップ)+ 制御構造 + スレッドスタック。フレームバッファは rmem 側で RSS に出ない。公式サンプル相当の最小構成での推定 |
| `v4l2rtspserver` | 約 2.5MB | 後段(不変) |

**置き換えの正味効果**: ベンダー 3 点(約 20.5MB)→ `atomcam2-camera`
(約 3〜6MB)で、**約 14〜17MB の削減**。常用時 `MemFree` を現状の 2MB 前後
から 15MB 以上に押し上げられる見込み。

### 見積もりの前提と不確実性

- `atomcam2-camera` の RSS は**推定値**。方式 B はまだ `IMP_System_Init` を
  通過できていないため、実測は取れていない。フェーズ 1 の PoC で確定する
- 前提: エンコーダ/ISP のバッファが rmem 側に確保されること(カーネル
  起動引数から確実だが、libimp が一部を通常メモリに取る可能性は PoC で確認)
- libimp が要求する制御用メモリが想定より大きい場合、上振れの可能性がある。
  それでも `iCamera_app`(18MB)の大半はアプリ固有ロジックのため、
  ネイティブ側が 18MB に達することは考えにくい

### 参考: メモリ以外の効果

- **チャンネル競合の解消**: 自前でチャンネルを専有制御でき、HD/SD 切り替えに
  よる停止が起きない
- **自動復旧**: 停止を検知して自前で再起動できる(ベンダーの「再開に
  リブート必要」制約から解放される見込み)
- **解像度・fps・ビットレートの自由**

## 位置づけ

[RTSP 実装方針 技術相談](20260803-RTSP実装方針の調査.md)の評価では、
本方式は「研究テーマ」(成功すれば価値大だが成否・工数が読めない)。本提案は
その研究を進めるための**具体的な次の一手**を確定させたもの。成功すれば、
現行のフック方式(方式 A)を置き換え、ブラックボックス依存・チャンネル競合・
18MB のメモリ消費をすべて解消できる。

## 関連文書

- [カメラ参照機能スクラッチ実装 提案書](20260802-カメラ参照機能の試作計画.md) —
  方式 B の全体構想と部品調査
- [ネイティブカメラ実装 技術相談](20260803-ネイティブカメラ実装の調査.md) —
  `IMP_System_Init` 停止の詳細な切り分けと助言
- [RTSP 配信 提案書](20260802-RTSP配信方式の検討.md) — 再利用する後段(v4l2loopback
  + v4l2rtspserver)の設計
- [平常時メモリ削減 提案書](20260803-平常時メモリ削減の検討.md) — 本方式が
  実現する 18MB 削減の位置づけ
