# 2026-08-13 映像信頼性(sprop 捕捉機構の誤認)技術相談(セカンドオピニオン依頼)

> **結論(TL;DR、2026-08-13 解決済み)**: 「T31 エンコーダは SPS/PPS を
> 起動時に一度しか出さない」という前提は誤りで、実際は毎 IDR 前に
> 自然に含まれている(§2)。真因は `v4l2rtspserver`(live555)側:
> 最初の `DESCRIBE` が camd の初回フレーム到達より前に来ると、
> `OnDemandServerMediaSubsession::fSDPLines` に空の sprop が**プロセス
> 寿命中ずっと固定キャッシュ**される起動時レースだった。`this` ポインタ
> 追跡で同一オブジェクトであることを実機確認し「別インスタンス説」を
> 排除(§14)。**camd の frame1 write() リトライ(VERSION 37)** と
> **v4l2rtspserver への `0005-sprop-startup-race-fix.patch`**(sprop が
> 空なら最大 3 秒リトライ待機してから SDP 構築)の 2 点で修正、独立した
> 実機 2 台・合計 7/7 回の再起動で sprop 正常出力を確認済み(§15-16、
> commit `acbab4b`)。

「音声は聞こえるが映像が映らない」を解消するため、RTSP の SDP
`sprop-parameter-sets` 捕捉レース([[atomcam2-rtsp]]、
[docs/20260813_v4l2rtspserver_epipeクラッシュループ_技術相談.md](20260813_v4l2rtspserver_epipeクラッシュループ_技術相談.md)
とは別件)を修正しようと `camd`(`package/atomcam2-camera/camd.c`)へ
2 点の対策を実装・実機投入した。しかし**実機診断ログにより、当初の
前提そのものが誤りだったと判明**し、修正は効果が無かった。さらに
v4l2rtspserver のソースを追ったところ、**sprop 捕捉の実体は当初想定
していたコードパスとは別物**である可能性が高いと分かった。ここで
一度立ち止まり、セカンドオピニオンを求めたい。

対象: AtomCam2(Ingenic T31 + GC2053)、カナリヤ機 192.168.222.56
([[atomcam2-canary-device]])、`camd` VERSION 39(本調査用の診断ログ
入り、実機投入済み)。

---

## 1. 発端と前提(当初の誤認)

過去のドキュメント([docs/20260805_RTSP_sprop欠落_安定起動_技術相談.md](20260805_RTSP_sprop欠落_安定起動_技術相談.md)
ほか)に基づき、以下を前提として作業を始めた:

> T31 SDK のエンコーダは SPS/PPS を**起動時に一度だけ**出力し、周期的な
> 再送機能は無い。`v4l2rtspserver` はそれを最初に読んだ瞬間に一度だけ
> キャプチャしてキャッシュする。掴み損ねるとそのプロセスの寿命中ずっと
> sprop が空になる。

この前提のもと、`camd.c` に 2 点の対策を実装した(commit 前、作業ツリー
上):

1. **SPS/PPS prepend**: 直近に見た SPS/PPS パックをキャッシュし、
   同一フレーム内に自前の SPS が無い IDR パックの直前へ毎回 prepend。
   捕捉のチャンスを「起動時の一瞬」から「ほぼ毎 IDR(既定 GOP=1 秒)」
   へ広げる狙い。
2. **write() リトライ**: `got == 0`(まだ 1 フレームも配信できていない)
   の間だけ、loopback への `write()` が `ENOTTY`(読み手未接続)で
   失敗したら最大 5 秒リトライ。

事前に libimp SDK(vendored `imp_encoder.h`、T31 SDK 1.1.1)を直接確認し、
**エンコーダ側に SPS/PPS を自動的に周期再送する設定・API が存在しない
ことを高確信度で確認済み**(`IMPEncoderChnAttr`/`RcAttr`/`GopAttr` の
全フィールドを列挙、それらしいものは皆無)。ここまでは前提と整合していた。

## 2. 実機診断で判明した事実(前提の反証)

`camd.c` に一時的な診断ログを追加し(`IMPEncoderPack.nalType.h264NalType`
を直接ログ出力。SDK の enum で SPS=7, PPS=8, IDR=5 と確定済み)、実際の
エンコーダ出力を確認した。

```
camd: diag frame packCount=3
camd: diag pack[0] nalType=7 length=41     ← SPS
camd: diag pack[1] nalType=8 length=8      ← PPS
camd: diag pack[2] nalType=5 length=94440  ← IDR
camd: diag IDR frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0
...(以下、後続の IDR イベントすべてで同じ)
camd: diag IDR frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0
camd: diag IDR frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0
camd: diag IDR frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0
camd: diag IDR frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0
```

**`frame_has_sps=1` がログに残った 5 回の IDR イベント全てで真**。
つまり **`camd` のエンコーダは実際には毎回の IDR 直前に自然に
SPS/PPS を含めている**(2026-08-05 時点の記述、および今回の libimp
調査結果からの推測とは矛盾する新事実)。当方の prepend 処理は一度も
発火しなかった(`will_prepend=0` 固定)— 実装は無害だが完全に空振り。

にもかかわらず、**DESCRIBE の SDP には `a=fmtp:96 `(sprop 無し)が
今回も出力された**。camd が正しく SPS/PPS を渡しているのに
`v4l2rtspserver` 側が依然として捕捉できていない。

## 3. v4l2rtspserver ソース再調査: 想定と違うコードパス

当初、sprop 捕捉は `H264_V4L2DeviceSource::splitFrames()`
(`src/H264_V4l2DeviceSource.cpp`)が担っていると想定していた。この
関数は SPS(7)/PPS(8) を見るたびに `m_sps`/`m_pps` を更新し、
**両方非空になった以降は毎フレーム `m_auxLine` を更新し続ける**設計
(一度きりではない、動的)。これが正しければ camd が正しく SPS/PPS を
渡している以上、数秒以内に sprop は捕捉されるはずだった。

しかし `BaseServerMediaSubsession::getAuxLine()`
(`src/ServerMediaSubsession.cpp:113-124`)を読むと:

```cpp
char const* BaseServerMediaSubsession::getAuxLine(V4L2DeviceSource* source, RTPSink* rtpSink)
{
	const char* auxLine = NULL;
	if (rtpSink) {
		std::ostringstream os; 
		if (rtpSink->auxSDPLine()) {
			os << rtpSink->auxSDPLine();
		}
		else if (source) {
			...
			os << "a=fmtp:" << int(rtpPayloadType) << " " << source->getAuxLine() << "\r\n";
```

**`rtpSink->auxSDPLine()` が非 NULL なら、`source->getAuxLine()`
(= 上記の splitFrames ベースの動的キャッシュ)は一切参照されない**。
そして映像の sink は `createSink()`(`ServerMediaSubsession.cpp:57`)で
`H264VideoRTPSink::createNew(...)` — **標準 live555 のクラスをそのまま
使っている**(v4l2rtspserver 独自のオーバーライドではない)。

**`H264VideoRTPSink`(live555 標準)の `auxSDPLine()` は、一般に
「ダミー sink を短時間再生してフレームを読ませ、SPS/PPS が見えるまで
待つ(タイムアウト付き)」という、`source->getAuxLine()` とは別の
一度きりの捕捉ロジックを持つことで知られる**(live555 の
`OnDemandServerMediaSubsession`/`H264or5VideoRTPSink` 系の標準実装)。
これが実際に使われているコードパスだとすれば、**camd がどれだけ
毎 IDR で SPS/PPS を渡しても無関係**であり、当方の対策が効かなかった
ことと整合する。

**この repo には live555 のソース自体がベンダされていない**(ビルド時に
外部取得、`CMake/FindlibliveMedia.cmake` はあるがソース実体は無し)ため、
`auxSDPLine()`/`H264VideoStreamDiscreteFramer` の正確なタイムアウト値・
キャッシュタイミング・再評価条件をこのセッションでは直接確認できて
いない。

## 4. 有力仮説(確率評価つき、主観)

| 仮説 | 主観確率 | 補足 |
| --- | --- | --- |
| `H264VideoRTPSink::auxSDPLine()`(live555 標準)が実際の捕捉経路で、`ServerMediaSession` 生成時(`v4l2rtspserver` 起動直後)に一度だけ有限時間待って評価され、その時点で camd がまだフレームを書けていなければ(GO ハンドシェイク待ち中など)、以後そのプロセスの寿命中ずっと空のまま固定される | 55〜65% | §3 のコードパス調査と直接整合。§2 で camd 側は毎 IDR で SPS/PPS を渡していると確認済みなのに直らない、という観測を唯一explainできる |
| `auxSDPLine()` 自体は再評価されうる(DESCRIBE 毎、あるいはセッション毎)が、その際の待機時間が短すぎて `v4l2rtspserver` の内部フレームキュー/レイテンシに間に合っていない | 15〜20% | 未検証。live555 のソースを読まないと判別できない |
| `H264VideoStreamDiscreteFramer` が SPS/PPS を検出する際、camd の出力するパック区切り(Annex-B 以外の可能性、offset/wraparound 由来のバイト列崩れ)を正しく解釈できていない | 10〜15% | copy_pack のラップアラウンド処理は既存ロジックを流用しているため可能性は低いが未確認 |
| 何らかの理由で `rtpSink->auxSDPLine()` が常に NULL を返し、実際には `source->getAuxLine()`(splitFrames ベース)の方が使われているが、そちらにも別のバグがある | 5〜10% | `getAuxLine()` のコード上は `if (rtpSink->auxSDPLine())` が優先されるため考えにくいが、live555 側の `auxSDPLine()` 自体が特定条件で恒久的に NULL を返す実装である可能性は排除できない |

## 5. 未解明事項

- `H264VideoRTPSink::auxSDPLine()`(または `H264or5VideoRTPSink` 共通実装)の正確なソース(このバージョンの live555 で使われている実装)。
- そのタイムアウト値、呼び出しタイミング(`ServerMediaSession` 生成時 1 回か、`DESCRIBE` 毎か)、キャッシュの有無・スコープ(プロセス全体か、セッション毎か)。
- `v4l2rtspserver` が `H264VideoStreamDiscreteFramer` に渡す前段(`H264_V4L2DeviceSource` → `StreamReplicator` → `H264VideoStreamDiscreteFramer`)で、SPS/PPS を含む NAL が実際にどう伝播しているか(specifically: `H264VideoStreamDiscreteFramer` はディスクリートな NAL 単位の入力を前提とするクラスだが、`H264_V4L2DeviceSource::splitFrames()` が SPS/PPS を個別の NAL として `frameList` に push しているかどうかは §2 で未検証)。
- 今回の diag ビルドは `-c`(`repeatConfig` 無効化)を渡していない(既定 true)。`repeatConfig` と `auxSDPLine()` の関係(独立か、`auxSDPLine()` が拾えた SPS/PPS を `repeatConfig` が使い回すのか)も未確認。

## 6. 検討中の対策と相談したい論点

### 案 A: live555 のソースを取得して `auxSDPLine()` の実装を直接確認する

- **論点(1)**: Buildroot のビルドログ/Makefile から live555 の実際の取得元・バージョンを特定し、該当ソース(`H264VideoRTPSink.cpp`, `H264or5VideoRTPSink.cpp` 等)を読んで、タイムアウト値とキャッシュスコープを確定させるのが最優先か。

### 案 B: `ServerMediaSession` 生成(`auxSDPLine()` の初回評価)を遅らせる

- 現状 `CreateVideoReplicator`/`AddUnicastSession` 相当の呼び出しは
  `v4l2rtspserver` の起動直後に走ると見られる。camd の GO ハンドシェイク
  完了(=最初の書き込み成功)を待ってから `v4l2rtspserver` 自体を
  起動する、あるいは `ServerMediaSession` の生成を遅延させる改修が
  考えられるが、後者は v4l2rtspserver 本体への手を入れる話になる。
- **論点(2)**: 現状の `GO_PATH` ハンドシェイクは「camd が v4l2rtspserver
  の起動を待つ」方向(§2026-08-13 の epipe 相談書参照)。もし
  `auxSDPLine()` が起動直後に一発評価されるなら、**逆方向(v4l2rtspserver
  の起動そのものを camd の frame1 成功まで遅らせる)** も検討が要るか。

### 案 C: `v4l2rtspserver` 側にわずかな独自パッチを入れ、`auxSDPLine()` を毎 `DESCRIBE` 再評価させる(または `source->getAuxLine()` を優先させる)

- 本プロジェクトは既に `package/v4l2rtspserver/0001〜0004` の自前パッチを
  保守しており([[atomcam2-rtsp-stability]] 参照)、5 件目のパッチを
  追加すること自体は運用パターンの延長線上。
- **論点(3)**: `getAuxLine()` の `if (rtpSink->auxSDPLine())` 分岐を
  `source->getAuxLine()`(動的・毎フレーム更新)優先に入れ替える、
  という改修は妥当か。副作用(既存の音声サブセッション含め、他の
  auxSDPLine 依存箇所への影響)は無いか。

### 案 D: 一旦ここで区切り、実用上の妥協点を探す

- §8.4(epipe 相談書)で確認済みの「sprop 無しでも in-band SPS/PPS で
  クライアントが後から映像復旧することがある」という事実を踏まえ、
  sprop 完全解決を追うより、**クライアント側の in-band 復旧を促す
  方向**(例: 定期的な軽い再接続を促す、GOP 長を短縮して in-band
  復旧のチャンスを増やす、等)に方針転換する余地はあるか。
- **論点(4)**: 全体として、この sprop 捕捉問題にどこまでコストを
  掛けるべきか。今回だけで camd VERSION 37/38/39 と 3 回の実機投入を
  行ったが、いずれも当初の仮説が外れており、今のところ有効な前進が
  ない。

## 7. 制約と前提

- 87MB RAM の機体([[atomcam2-approach-b]])。
- 制御カーネルは差し替え禁止([[atomcam2-control-kernel]])。
- 実機を過度に叩かない([[atomcam2-device-handling]])。今回は
  `mix upload`(OTA)のみで、3 回の camd バイナリ更新を実機投入した。
- `camd.c` の変更は MIPS uClibc クロストールチェーン(旧セッションの
  scratchpad `/tmp/claude-1000/.../39fe2451.../scratchpad/mips-gcc472`
  に発見・利用。本セッション終了後は失われる可能性があるため、
  正式な保存場所の検討が別途必要)でのビルドが必要。
- カナリヤ機は 2026-08-13 時点で 192.168.222.56([[atomcam2-canary-device]])。
- `camd.c` の prepend/write-retry/診断ログはすべて未コミット(作業ツリー
  上のみ)。診断ログ(`g_diag_frames_left`/`g_diag_idr_left`)は
  デバッグ専用で、本採用するコードには含めない想定。

## 8. 求める意見(要約)

1. `H264VideoRTPSink::auxSDPLine()`(live555 標準)が実際の sprop 捕捉
   経路だという推定(§3、§4 の第一仮説)は妥当か。他に確認すべき
   コードパスはあるか。
2. live555 のソース取得・確認(案 A)を最優先にすべきか。
3. `ServerMediaSession` 生成タイミングを camd の準備完了後に遅らせる
   (案 B)、または v4l2rtspserver へパッチして `source->getAuxLine()`
   を優先させる(案 C)、どちらが筋が良いか。
4. このまま sprop 完全解決を追うか、in-band 復旧依存へ方針転換する
   か(案 D)。
5. 全体として、今回の 3 回の実機投入(camd VERSION 37/38/39)は
   結果的に前提の誤りを潰すための調査コストとして正当だったと思うが、
   次に着手する前に、コード调查(live555 ソース読解)を先に済ませて
   から実機投入すべきという教訓を活かすべきか。

---

## 9. セカンドオピニオン回答(2026-08-13)と方針確定

### 総合判定

| 優先 | 方針 | 判断 |
| --- | --- | --- |
| ★★★★★ | live555 実バージョン特定 + `H264VideoRTPSink.cpp`/`OnDemandServerMediaSubsession.cpp` 確認 | 最優先 |
| ★★★★★ | 実際の `DESCRIBE → auxSDPLine → framer` の瞬間をログで観測 | 実機投入前にやる |
| ★★★★☆ | `source->getAuxLine()` を使う v4l2rtspserver 側修正 | かなり筋が良い |
| ★★★☆☆ | v4l2rtspserver 起動を camd frame1 成功後へ遅延(案 B) | 補助策。第一選択ではない |
| ★☆☆☆☆ | camd の SPS/PPS prepend 継続 | もう不要 |
| ★☆☆☆☆ | sprop を諦めてクライアント再接続依存(案 D) | まだ早い |

**VERSION 39 の camd は当面コミットせず、prepend/write-retry/診断コードは
一旦退避する。**

### 重要な訂正: `auxSDPLine()` は「ダミー再生して待つ」処理ではない

§4 第一仮説の「起動直後に一定時間フレームを読んで待つ」は**不正確**。
実際の `H264VideoRTPSink::auxSDPLine()`(および共通実装
`H264or5VideoRTPSink`)は:

```
fSPS/fPPS が既にあればそれを使用
無ければ fOurFragmenter->inputSource() から
  H264or5VideoStreamFramer::getVPSandSPSandPPS() を呼ぶ
  → その時点で SPS/PPS があれば SDP 生成
  → まだ無ければ即 NULL(待機ループは無い)
```

**同期的な問い合わせであり、待機は無い。** 「ダミー sink 再生待ち」は
live555 の別クラス(`H264VideoFileServerMediaSubsession` 等、ファイル系
サブセッション)の話で、今回の記憶はそれと混同していた可能性が高い。

### さらに重要: SDP はキャッシュされる、DESCRIBE 毎の再構築ではない

`OnDemandServerMediaSubsession::sdpLines()` は概ね:

```cpp
char const* OnDemandServerMediaSubsession::sdpLines() {
    if (fSDPLines == NULL) {
        ...
        setSDPLinesFromRTPSink(...);  // ここで auxSDPLine() が呼ばれる
        ...
    }
    return fSDPLines;
}
```

**`fSDPLines == NULL` の最初の一回だけ SDP を構築し、以後は固定。**
つまり「プロセス起動直後に一回」ではなく、**「その subsession の SDP が
初めて要求された瞬間(=最初の DESCRIBE)に一回」**が正確なタイミング。

この 2 点を踏まえた修正版の因果モデル:

```
最初の DESCRIBE
  → OnDemandServerMediaSubsession::sdpLines()
  → fSDPLines が NULL なので構築開始
  → H264VideoRTPSink::auxSDPLine()
  → framer の getVPSandSPSandPPS() を同期的に問い合わせ
  → その瞬間に SPS/PPS が framer 内に無ければ NULL
  → sprop 無しの SDP が fSDPLines に固定
  → 以後 DESCRIBE は何回来ても同じ SDP を返す(再構築されない)
```

これは「camd が毎 IDR で SPS/PPS を出しているのに直らない」という
観測(§2)と整合する。**問題の所在は camd でも、想定していた
`source->getAuxLine()`(splitFrames ベースの動的キャッシュ、これは
呼ばれてすらいない)でもなく、`V4L2 source → H264 framer` 間で
SPS/PPS がどう伝播しているか(問題 C)、および「最初の DESCRIBE の
タイミングで framer が SPS/PPS を持っているか」(問題 D)に絞られる。**

### 問題の切り分け直し

| 区分 | 状態 |
| --- | --- |
| A: IMP Encoder が SPS/PPS/IDR を出すか | **解決済み**(実機確認済み) |
| B: camd が loopback へ正しく書き込むか | **ほぼ解決済み**(診断ログ上正常、prepend は不要と判明) |
| C: `V4L2 source(H264_V4L2DeviceSource::splitFrames) → H264VideoStreamDiscreteFramer` 間で SPS/PPS が正しく伝播するか | **未確認、第一容疑者** |
| D: 最初の DESCRIBE 時点で framer が SPS/PPS を保持しているか(SDP キャッシュの確定タイミング) | **未確認、今回の race の核心** |

### 次の一手(実機投入なし、コード調査のみ)

1. Buildroot/CMake から実際に使われている live555 のバージョンを特定。
2. 該当バージョンの `H264VideoRTPSink.cpp` / `H264or5VideoRTPSink.cpp` /
   `H264or5VideoStreamFramer.cpp` / `H264VideoStreamDiscreteFramer.cpp` /
   `OnDemandServerMediaSubsession.cpp` を確認し、`getVPSandSPSandPPS()`
   の実装を読む。
3. `H264_V4L2DeviceSource::splitFrames()` が SPS/PPS をどう
   `H264VideoStreamDiscreteFramer` へ渡しているか(`frameList` への
   push 順序・`H264VideoStreamDiscreteFramer` 側の受け取り方)を読む。
4. 診断ログを 4 点(splitFrames 検出時 / framer 受信時 /
   `getVPSandSPSandPPS()` 返却時 / `auxSDPLine()` 呼び出し時、可能なら
   `DESCRIBE` 到着時刻との相対タイミングも)追加する案を設計。
5. ここまで済ませてから、初めて 1 回の実機投入で検証する。

### 案の優先順位の修正

- **案 B(v4l2rtspserver 起動を camd 完了まで遅延)は根本修正ではない**
  と格下げ。起動順序を整えても「framer が SPS/PPS を拾う保証」には
  ならず、client の DESCRIBE タイミング次第になるだけで、診断用の
  workaround 止まり。
- **案 C(`source` 側キャッシュを SDP 生成に使う)を格上げ**。
  `H264_V4L2DeviceSource::splitFrames()` は既に SPS/PPS を検出できて
  いる(実機確認済み)ので、それを SDP の authoritative source にする
  設計は自然。ただし `source->getAuxLine()` の返す文字列が
  `packetization-mode`/`profile-level-id` まで含む完全な aux SDP line
  か、`sprop-parameter-sets` 単体かを実装を読んで確認してからパッチ化
  する。
- **案 D は時期尚早のまま**。まだ「最後の SDP メタデータ生成部分」の
  問題である可能性が高く、in-band 復旧依存への転換より SDP 側を
  正しく直す方が堅牢(クライアントが PLAY 開始時点から即デコードできる)。

### VERSION 37/38/39 の実機投入は無駄だったか

**無駄ではなかったと判断。** VERSION 39 の診断ログ
(`frame_has_sps=1 g_sps_len=41 g_pps_len=8 will_prepend=0` × 5 イベント)
により「エンコーダが SPS/PPS を一度しか出さない」という仮説を強く
棄却できた。これで「camd をいじり続けるフェーズ」は終了し、次は
live555/v4l2rtspserver のコードのみで詰める段階に移行できる、という
明確な区切りが付いた。

> 総合評価: §4 第一仮説の確率(55〜65%)は「`auxSDPLine()` が sprop
> 生成の中心である」という部分は概ね妥当だが、「ダミー再生してタイム
> アウトまで待つ」という機序の理解は誤りだった。正しくは「最初の
> DESCRIBE 時点で同期的に framer へ問い合わせ、その瞬間に無ければ
> 即座に(待たずに)sprop 無しで SDP が固定される」。この訂正により
> 調査対象は `V4L2 source → framer` 間の伝播(問題 C)と「最初の
> DESCRIBE のタイミング」(問題 D)に絞られた。

## 10. live555 実ソース確認の結果(2026-08-13、セカンドオピニオン反映後)

セカンドオピニオンの指摘通り、live555 のソースは実際にビルドツリーに
残っていた(`live555-2025.10.13`、`file DOWNLOAD` でビルド時取得された
もの)。直接確認した結果:

### 訂正1: `auxSDPLine()` は同期的・待機無し(セカンドオピニオン通り)

`H264VideoRTPSink::auxSDPLine()`(`liveMedia/H264VideoRTPSink.cpp:81-127`)
はコメントで明記:「Generate a new "a=fmtp:" line **each time**」— 呼ばれる
たびに `framerSource->getVPSandSPSandPPS()` を**同期的に**問い合わせる。
待機ループは無い。RTPSink 自体はキャッシュしない。セカンドオピニオンの
訂正が正しかったことを確認。

### 訂正2(新規): SDP キャッシュは `OnDemandServerMediaSubsession::sdpLines()`

セカンドオピニオン指摘通り。最初の呼び出し時に `fSDPLines` が構築され、
以後固定。

### 新発見: `H264or5VideoStreamDiscreteFramer` は Annex-B 開始コード入り NAL を拒否する

`liveMedia/H264or5VideoStreamDiscreteFramer.cpp:130-142`:

```cpp
// Once again, to be clear: The NAL units that you feed to a
// "H264or5VideoStreamDiscreteFramer" MUST NOT include start codes.
if (frameSize >= 4 && fTo[0] == 0 && fTo[1] == 0 && ((fTo[2] == 0 && fTo[3] == 1) || fTo[2] == 1)) {
    envir() << "H264or5VideoStreamDiscreteFramer error: MPEG 'start code' seen in the input\n";
} else if (isSPS(nal_unit_type)) {
    saveCopyOfSPS(fTo, frameSize);
} else if (isPPS(nal_unit_type)) {
    saveCopyOfPPS(fTo, frameSize);
}
```

開始コード入り NAL を検出すると `saveCopyOfSPS`/`saveCopyOfPPS` を
**完全にスキップする**(if/else-if の排他分岐)。camd 側の診断ログ
(VERSION 40 で追加、実機確認済み)で、camd が loopback へ書き込む
全パック(SPS/PPS/IDR/P スライス問わず)が **`00 00 00 01`(4 バイト
Annex-B 開始コード)から始まる**ことを確認した:

```
camd: diag pack[0] nalType=7 length=41    first8=00 00 00 01 27 4d 00 33   (SPS)
camd: diag pack[1] nalType=8 length=8     first8=00 00 00 01 28 ee 3c 80   (PPS)
camd: diag pack[2] nalType=5 length=94916 first8=00 00 00 01 25 b8 40 00   (IDR)
```

**この時点で「開始コードが原因」と断定しかけたが、自己訂正が必要**:
`v4l2rtspserver` が `H264_V4L2DeviceSource` を生成する箇所
(`inc/DeviceSourceFactory.h:26`)を見ると、

```cpp
source = H264_V4L2DeviceSource::createNew(*env, devCapture, outfd, queueSize, captureMode, repeatConfig, false);
                                                                                                          ^^^^^ keepMarker=false(ハードコード)
```

`keepMarker=false` が渡されており、`H26X_V4L2DeviceSource::extractFrame()`
(`src/H26x_V4l2DeviceSource.cpp:22-70`)は `m_keepMarker` が false の場合
**`memmem` で開始コードを検出し、マーカー部分を読み飛ばした位置
(`&startFrame[markerlength]`)を返す**設計になっている(=開始コードを
剥がしてから `frameList` へ積むはずの実装)。つまり **`extractFrame` が
設計通り動いていれば、`H264VideoStreamDiscreteFramer` に渡る時点では
開始コードは既に除去されているはず**であり、camd 側が開始コード付きで
書き込んでいること自体は(v4l2rtspserver がこの状況を正しく処理する
設計である以上)直接の原因とは言い切れない。

**現時点でのフェア(まだ検証していない)な状態**: `extractFrame` の
`memmem` ベースのマーカー検出・除去が実際に正しく機能しているかは
**未検証**。camd が 1 回の `write()` で複数 NAL(SPS+PPS+IDR)を連結
して書き込んでいる、かつ v4l2loopback からの `read()` が
`write()` の境界と一致しない可能性がある構成のもとで、`extractFrame`
のループ処理(`splitFrames()` 内で `extractFrame` を連続呼び出し)が
正しく全 NAL を分割・マーカー除去できているかは、コードレビューだけ
では断定できない。

## 11. 現時点のまとめと次の一手(2026-08-13 時点)

- camd 側(問題 A・B)は実機確認済みで健全。**これ以上 camd を触る
  必要は無い**(セカンドオピニオンの判断を維持)。
- `auxSDPLine()`/`sdpLines()` の同期・キャッシュ機構は理解できた
  (§10 訂正1・2)。
- 残る焦点は **`H26X_V4L2DeviceSource::extractFrame()` が実際に
  マーカーを正しく除去できているか**、および **`saveCopyOfSPS`/
  `saveCopyOfPPS` が実際に呼ばれているか**(問題 C)、**最初の
  `DESCRIBE` 到達時点で framer が SPS/PPS を保持しているか**
  (問題 D)の 2 点に絞られた。
- これらはコードレビューの限界に達しており、**`v4l2rtspserver` 自体に
  一時的な `LOG()` 診断を追加して実機で確認する必要がある**。
  `v4l2rtspserver` は Buildroot の標準クロスツールチェーンでビルド
  される(camd 用のベンダー uClibc 4.7.2 ツールチェーンとは別、
  `mix firmware` の通常のビルドパイプラインに乗る)ため、camd の
  ときのような手動ツールチェーン確保は不要 — 新規パッチファイル
  (`package/v4l2rtspserver/0005-...` 相当)を追加すれば通常の
  `mix firmware` で再ビルドされる。

## 12. v4l2rtspserver 実機診断パッチの結果(2026-08-13、確定的証拠)

### 12.1 Buildroot のはまりどころ: パッチ追加だけでは再ビルドされない

`package/v4l2rtspserver/0005-sprop-diagnostic-logging.patch`
(`BaseServerMediaSubsession::getAuxLine()` に診断 `LOG(NOTICE)` を追加)
を作成し `mix firmware` を 2 回投入したが、**どちらも実際には
再ビルドされていなかった**(v4l2rtspserver のビルドディレクトリの
`.stamp_patched`/`.stamp_built` 等が全て今朝 00:30 のまま、
`src/ServerMediaSubsession.cpp` の mtime も元の git checkout 日時の
まま)。Buildroot の `generic-package` は、新規パッチファイルの追加
だけでは既存の `.stamp_patched` を無効化しない(バージョン変更や
ソース変更を伴わない限り再パッチ・再ビルドをスキップする)。

**対応**: v4l2rtspserver のビルドディレクトリを丸ごと削除
(`rm -rf .nerves/artifacts/.../build/v4l2rtspserver-*`)して
`mix firmware` を再実行し、強制的に再抽出・全パッチ再適用・再ビルド
させた。

### 12.2 確定的証拠: `source->getAuxLine()` が空文字列を返している

パッチ適用後、実機で `DESCRIBE` を送ると:

```
diag getAuxLine ENTER: rtpSink=present source=present
diag getAuxLine: rtpSink->auxSDPLine()=(null) source->getAuxLine()=[]
```

が(video サブセッション分・audio サブセッション分の 2 回)ログに
残った。これにより以下が**確定**した:

- `getAuxLine()` は確かに呼ばれている(想定通り)。
- `rtpSink`・`source` とも非 NULL(`dynamic_cast` は成功している)。
- `rtpSink->auxSDPLine()` は NULL(想定通り、ダミー sink 側の限界)。
- **`source->getAuxLine()`(= 永続的・共有の `H264_V4L2DeviceSource`
  の `m_auxLine`)が空文字列 `""` を返している** — この DESCRIBE
  より**前**に `splitFrames()` が "SPS size:37"/"PPS size:4" を
  複数回ログ出力していた(=`m_sps`/`m_pps`/`m_auxLine` は本来
  構築されているはず)にもかかわらず、である。

### 12.3 反証: スレッド間可視性バグ説

`m_sps`/`m_pps`/`m_auxLine`(`std::string`、同期機構無し)が capture
用の内部スレッド(既定 `CAPTURE_INTERNAL_THREAD`)で書き込まれ、
live555 イベントループスレッドの `getAuxLine()` から読まれる、という
クロススレッド可視性バグ(MIPS の弱いメモリ順序モデル)を疑い、
`-s`(`CAPTURE_LIVE555_THREAD`、単一スレッド化)を試したが、**同じ
結果(`source->getAuxLine()=[]`)のまま改善しなかった**。この仮説は
棄却してよい。

### 12.4 新たな謎: DESCRIBE 毎に `getAuxLine()` が再度呼ばれている(キャッシュされていない)

同一 TCP 接続を使い回さず(`nc` を毎回新規実行)2 回連続で `DESCRIBE`
を送ったところ、**両方とも新たに `diag getAuxLine ENTER` がログに
記録された**。§9-10(セカンドオピニオン反映後)で確認したはずの
「`OnDemandServerMediaSubsession::fSDPLines` は最初の一回だけ構築され
以降は固定」という理解と矛盾する。考えられる可能性:

- 新規 TCP 接続(=新規 RTSP セッション)ごとに `ServerMediaSession`/
  `ServerMediaSubsession` 自体が新規作成されており、`fSDPLines` の
  キャッシュがサーバ全体ではなく**その場限りのセッションスコープ**
  にしかならない設計になっている(未検証)。
- あるいは `fSDPLines` キャッシュ自体は効いているが、別の経路
  (`rtspServer` 側で `DESCRIBE` ハンドラが `sdpLines()` 以外の方法で
  SDP を再構築している)を通っている。

### 12.5 現時点でのまとめ

- **問題は `H264_V4L2DeviceSource::m_auxLine` が(splitFrames() が
  SPS/PPS を検出しているにもかかわらず)期待通り構築・保持されて
  いないこと**まで確定的に特定できた(問題 C そのもの)。
- スレッド間可視性バグ説は実機で反証済み。
- 残る未解明: なぜ `m_auxLine` が空のままなのか(`m_sps`/`m_pps` 自体が
  実は空、または `!m_sps.empty() && !m_pps.empty()` 到達前に何かが
  クリアしている、等)、および DESCRIBE 毎に `getAuxLine()` が
  再呼び出しされる(キャッシュされない)理由。
- 次の一手の候補: `splitFrames()` 内で `m_sps.size()`/`m_pps.size()`/
  `m_auxLine.size()` 自体を都度ログ出力する診断を追加し、SPS/PPS
  検出の**直後**に本当に `m_auxLine` が構築されているかを直接確認する
  (現状は "SPS size:"/"PPS size:" ログはあるが `m_auxLine` 構築成功の
  確認ログが無い)。

## 13. 求める意見(2026-08-13、追加ラウンド)

§9(セカンドオピニオン回答)を受けて live555/v4l2rtspserver ソースを
実際に読み、さらに実機診断パッチ(`0005-sprop-diagnostic-logging.patch`)
で確定的な証拠を得たが、まだ完全解決に至っていない。現時点の状況を
整理して再度意見を求めたい。

### 分かったこと(確定)

1. `camd` はエンコーダの出力(SPS/PPS/IDR)を毎 IDR ごとに正しく loopback
   へ書き込んでいる(§2、camd VERSION 40 で実機確認済み)。
2. `H264_V4L2DeviceSource::extractFrame()` は Annex-B 開始コードを正しく
   除去できている(camd の生パック長 41/8 バイト → v4l2rtspserver 側の
   ログでは 37/4 バイトと、開始コード 4 バイト分ぴったり一致、§10)。
3. `H264_V4l2DeviceSource.cpp::splitFrames()` は SPS(size:37)/PPS(size:4)
   を**繰り返し検出できている**(`-v` で可視化した `LOG(INFO)` を実機
   ログで確認、§11)。
4. `BaseServerMediaSubsession::getAuxLine()` は確かに呼ばれている
   (video/audio 両サブセッションで)。`rtpSink`/`source` とも非 NULL。
   `rtpSink->auxSDPLine()` は NULL(ダミー sink 由来、想定通り)。
   **しかし `source->getAuxLine()`(= 永続・共有オブジェクトの
   `m_auxLine`)が空文字列を返している**(§12.2、実機ログで直接確認)。
5. クロススレッド可視性バグ説(`m_sps`/`m_pps`/`m_auxLine` が
   `std::string` で無同期のまま capture 用内部スレッドと live555
   イベントループスレッド間で共有されている)を疑い、`-s`
   (`CAPTURE_LIVE555_THREAD`、単一スレッド化)で検証したが、**改善せず
   同じ結果**。この仮説は棄却(§12.3)。

### 分からないこと

- **`splitFrames()` が SPS/PPS を検出しログ出力しているのに、なぜ
  同じオブジェクトの `m_auxLine`(`getAuxLine()` の戻り値)が空のまま
  なのか。** コードを読む限り `if (!m_sps.empty() && !m_pps.empty())`
  が真になった時点で `m_auxLine.assign(os.str())` が実行されるはずで、
  一度でも SPS→PPS の順で検出されれば以降ずっと非空になるはずだが、
  実機ではそうなっていない。
- **DESCRIBE 毎に `getAuxLine()` が再度呼ばれている**(§12.4)。§9 で
  確認した「`fSDPLines` は最初の一回だけ構築されキャッシュされる」
  という理解と矛盾する観測。新規 TCP 接続(`nc` の毎回の新規実行)ごとに
  何かがリセットされている可能性がある。

### 相談したい点

1. `m_sps`/`m_pps` は非空なのに `m_auxLine` だけ空になる、という状況が
   コード上あり得るとすれば、どこを疑うべきか(`std::string` の
   代入・スコープ・例外安全性、`base64Encode` の失敗、
   `removeH264or5EmulationBytes`〔`H264VideoRTPSink::auxSDPLine()` 側の
   処理で、`source->getAuxLine()` 側の `splitFrames()` には無いが
   関連する処理があれば〕等)。
2. §12.4 の「DESCRIBE 毎に再呼び出しされる」現象について、
   `ServerMediaSession`/`ServerMediaSubsession` が新規 TCP 接続ごとに
   作り直されている設計なのか、それとも `fSDPLines` キャッシュの
   実装/理解が何か違うのか。
3. 次に追加すべき診断ログの候補として、`splitFrames()` 内で
   `m_sps.size()`/`m_pps.size()`/`m_auxLine.size()` を都度出力する案
   (§12.5)は妥当か。他に優先して確認すべき箇所はあるか。
4. ここまで(camd VERSION 40 + v4l2rtspserver パッチ 0001〜0005、
   複数回の実機投入)で得られた情報量に対して、このまま v4l2rtspserver
   コードレベルの深掘りを続ける価値があるか、それとも別のアプローチ
   (例: `H264_V4L2DeviceSource` を使わない、`source->getAuxLine()`
   経路を諦めて `rtpSink` 側だけで完結させる設計変更、等)に切り替える
   べきか。

## 14. 解決: this ポインタ診断で確定(2026-08-13、セカンドオピニオン第2ラウンド反映)

セカンドオピニオンの提案通り `this`/`source`/`rtpSink` ポインタを
ログに追加し、実機(192.168.1.77、環境変更によりカナリヤ機切替)で
確認した。

```
diag getAuxLine ENTER this(subsession)=0x774451d8 source=0x77944de0 rtpSink=0x7740ac10
diag getAuxLine source=0x77944de0 rtpSink->auxSDPLine()=(null) source->getAuxLine()=[]
diag getAuxLine ENTER this(subsession)=0x7766dd38 source=0x777d9a00 rtpSink=0x777fab30   ← audio サブセッション(別オブジェクトで正常)
diag getAuxLine source=0x777d9a00 ...

(この後に camd の frame1 到達ログ、続いて)

diag splitFrames this=0x77944de0 sps=37 pps=0 aux_before=0
diag splitFrames this=0x77944de0 sps=37 pps=4 aux_before=0
diag splitFrames this=0x77944de0 aux_after=106
```

**`source`(video)= `splitFrames` の `this` = `0x77944de0` で完全に
一致**。§13 で立てた「別インスタンス説」(70%)は**棄却**。代わりに
判明したのは:

- **`getAuxLine()`(= 最初の `DESCRIBE`)が、`splitFrames()` が一度も
  実行されるより前に発生していた。** つまり `H264_V4L2DeviceSource`
  はまだ 1 フレームも読んでおらず、`m_sps`/`m_pps`/`m_auxLine` が
  文字通りまだ何も構築されていない段階で `source->getAuxLine()` を
  呼んでいた。
- §12.4 の「DESCRIBE 毎に再度呼ばれる」謎も解消: 実際には**同じ
  DESCRIBE 内で video サブセッションと audio サブセッションの
  2 回**呼ばれていただけで、別々の DESCRIBE ではなかった(video/audio
  でそれぞれ別の `source` オブジェクトなのは正常な設計)。

**確定した根本原因**: `v4l2rtspserver` の RTSP ポートは起動直後から
接続を受け付けるが、`H264_V4L2DeviceSource` がまだ 1 フレームも
loopback から読んでいない段階で最初の `DESCRIBE`(今回はヘルスチェック
由来)が到達すると、`OnDemandServerMediaSubsession::fSDPLines` に
**空の sprop がその場で恒久的にキャッシュされる**。camd が後から
どれだけ正しく SPS/PPS を出しても、このキャッシュは二度と再構築
されない。§9 で確定した「最初の DESCRIBE で一度だけ構築・以後固定」
という因果モデル(問題 D)が、`this` ポインタという動かぬ証拠つきで
最終確認された形。

## 15. 実装した修正

`BaseServerMediaSubsession::getAuxLine()`(既に診断ログ追加のため
パッチ済みの関数)に、**`source->getAuxLine()` が空の場合だけ短時間
(最大 3 秒、100ms 間隔でポーリング)待ってから再取得する**リトライ
ループを追加した。これは「最初の DESCRIBE が早すぎた場合に、capture
スレッドが追いつくまで待つ」という、当初 live555 標準機能だと誤認して
いた「ダミー再生して待つ」動作を、v4l2rtspserver 側に**実際に**実装する
形になる。

- リスクは小さい: 影響が及ぶのは「プロセス起動後、初めて `DESCRIBE`
  が来た瞬間、かつ `source->getAuxLine()` がまだ空の場合」のみ。
  通常運用では 3 秒以内に camd の frame1(GO ハンドシェイク+write
  リトライ済み)が届くはずで、待機はほぼ発生しないか、発生しても
  数百 ms で終わる。
- 待っても駄目なら(3 秒経過)、従来通り空のまま `fSDPLines` に
  キャッシュされて動作を続ける(フォールバック、回帰無し)。

## 16. 実機フルサイクル確認と最終状態(2026-08-13)

環境変更により実機を 192.168.1.77(別個体、[[atomcam2-canary-device]]
参照)へ切り替え、以下を実施:

- `camd.c` を診断コード込みの VERSION 40 から、**write() リトライだけを
  残したクリーンな VERSION 37 に作り直し**(SPS/PPS prepend は §14 の
  通り不要と判明したため削除、診断ログも全撤去)。
- `package/v4l2rtspserver/0005-sprop-diagnostic-logging.patch` を、
  §15 の恒久修正(`getAuxLine()` に最大 3 秒のリトライ待機)を実装した
  `0005-sprop-startup-race-fix.patch` に置き換え(診断専用コードは撤去)。
- `camera_native.ex` の `-v`/`-s` 診断フラグを撤去し `@rtsp_args` を
  元のシンプルな形に戻した。

実機投入後、`DESCRIBE` で **`sprop-parameter-sets` が正しく SDP に
出現することを確認**:

```
a=fmtp:96 profile-level-id=4d0033;sprop-parameter-sets=J00AM+dAPAET8s1AQEB8AAADAAQAAAMAyMkAAehIAAtxt//wKA==,KO48gA==
```

念のため**同一ファームを 3 回連続で再投入(=3 回の再起動)**して毎回
確認したところ、**4/4(初回+3 回)すべてで sprop が正常に載った**
(修正前は複数回に 1 回程度しか成功しない確率レースだった)。ユーザ側
でも VLC で実際に映像が表示されることを確認済み。

興味深いことに、`getAuxLine()` の待機ログ(`"waited...ms"`)は 4 回とも
一度も出力されなかった — つまり**camd 側の write() リトライ修正
(frame1 が確実に読み手へ届くようにする)だけで、実質的にレースの
大部分が解消された**らしい。v4l2rtspserver 側の待機ロジック(§15)は
現時点では発動していないが、稀なケース(camd 側の対策でも間に合わない
ほど早い `DESCRIBE`)に対するセーフティネットとして残す価値はある。

**結論**: 音声に続き、映像(sprop 経由の即時デコード)も実機で安定
動作を確認できた。「音声は確実に聞こえるが映像は起動時すぐに見えない」
という当初の課題は解消したと判断する。

## 参考

- [RTSP 音声追加 提案書](20260812_RTSP_音声追加_提案書.md)
- [v4l2rtspserver epipe クラッシュループ 技術相談](20260813_v4l2rtspserver_epipeクラッシュループ_技術相談.md) — 別件(watchdog 自己増幅ループ)、本件とは独立に解決済み
- [RTSP sprop 欠落・安定起動 技術相談](20260805_RTSP_sprop欠落_安定起動_技術相談.md) — 2026-08-05 時点の調査(前提となった記述の出典)
- [sprop 修正・VLC 表示回帰 技術相談](20260805_sprop修正_VLC表示回帰_技術相談.md) — 手動 prepend が過去に撤回された経緯(後日 VPN 問題と判明)
- [[atomcam2-rtsp]] — sprop 捕捉の確率的レース、過去の対策一覧
- [[atomcam2-rtsp-stability]] — RTSP 全般の既知パターン
- [[atomcam2-canary-device]] / [[atomcam2-device-handling]] / [[atomcam2-control-kernel]]
- `package/atomcam2-camera/camd.c`(VERSION 39、診断ログ入り、未コミット)
- `.nerves/artifacts/nerves_system_atomcam2-portable-0.4.0/build/v4l2rtspserver-*/src/{ServerMediaSubsession,H264_V4l2DeviceSource,V4L2DeviceSource}.cpp`
