# 2026-08-13 v4l2rtspserver epipe クラッシュループ 技術相談(セカンドオピニオン依頼)

> **結論(TL;DR、2026-08-13 解決済み)**: crash-loop の正体は
> `v4l2rtspserver` の自壊ではなく、**sprop 捕捉の確率的レースに
> watchdog が負けるたびに `restart_stack()` を呼び、その再起動「遷移」
> 自体が持つ数秒の固有不安定性を再点火する自己増幅ループ**だった
> (§8.5-8.6)。**watchdog を「サーバ無応答」と「sprop 欠落のみ」の
> 二段階に分離**(サーバ無応答は即 rebuild、sprop 欠落のみは約 5 分の
> 猶予を置いてから rebuild)し、`camera_native.ex` に実装・実機確認
> 済み(§9〜9.1、commit `34e2ff9`)。sprop 捕捉レース自体の根本原因は
> 別ドキュメント([映像信頼性・sprop 捕捉機構特定 技術相談](20260813_video信頼性_sprop捕捉機構特定_技術相談.md))
> で追跡・修正済み(commit `acbab4b`)。音声機能自体は無実(§1-4)。

RTSP へのマイク音声追加([RTSP 音声追加 提案書](20260812_RTSP_音声追加_提案書.md)、
`atomcam2-aicap` + `0004-fifo-audio-source.patch`)の実機検証中に、
**`v4l2rtspserver` が `:epipe` で頻繁に終了・再起動を繰り返す**不安定化に
遭遇した。A/B 切り分けにより**音声機能自体は無実**と確定できたが、
**クラッシュループ自体の真因は依然未特定**。[[atomcam2-rtsp-stability]]
には 2026-08-05 時点で同じ症状が「`killall` 連打による churning が原因の
一過性」と記録されているが、今回は churning していないのに発生しており、
その結論が今回にも当てはまるのか判断がつかない。セカンドオピニオンを
求めたい。

対象: AtomCam2(Ingenic T31 + GC2053)、カナリヤ機 192.168.222.56
([[atomcam2-canary-device]])、firmware 0.4.0、main `06ab157` ベース
(+ 今回の音声機能パッチ、作業ツリー上は未コミット)。

---

## 1. 観測事実

### 1-1. 音声機能フルビルドでの初回 OTA 投入(1 回目)

`mix upload` で音声パッチ入りビルドを投入 → 再起動 → 起動から約 150〜218
秒ほど `phase: degraded / rtsp_alive: false` が続いた後、自然に
`phase: running / rtsp_alive: true` へ復帰し、その後 90 秒以上安定して
観測終了。

### 1-2. 同じビルドで 2 回目の OTA 投入(ダッシュボード文言修正のみの再ビルド)

コード差分はダッシュボードの説明文 1 行のみ(RTSP/音声ロジックは無変更)。
にもかかわらず、起動から 66 秒後には `degraded` に入り、以後 8 サイクル
(64 秒間)の観測ですべて `degraded` のまま復帰せず。

```
58s running True
66s running True
74s degraded False
82s degraded False
90s degraded False
98s degraded False
106s degraded False
114s degraded False
```

同一コード・同一手順での 2 回の投入で「早期に settle した」「settle しない
まま観測終了」という**再現性のない結果**になっている。

### 1-3. RingLogger 詳細ログ(フィルタ後)

`v4l2rtspserver`/`aicap` プレフィックスの行のみ抽出すると、次の順序が
確認できた(時系列順、一部抜粋):

```
aicap: waiting for a reader on /tmp/camd-audio.fifo
RTSP publishing is waiting for the vendor camera runtime (:waiting)
Native camera RTSP server started on port 8554
v4l2rtspserver: log level:500
aicap: reader connected on /tmp/camd-audio.fifo
aicap: IMP_AI_SetPubAttr      = 0
v4l2rtspserver: handleCmd_SETUP:SETUP rtsp://192.168.222.56:8554/video0_unicast/track1 RTSP/1.0
v4l2rtspserver: User-Agent: LibVLC/3.0.12 (LIVE555 Streaming Media v2016.11.28)
v4l2rtspserver: Transport: RTP/AVP;unicast;client_port=57662-57663
v4l2rtspserver: handleCmd_SETUP:SETUP rtsp://192.168.222.56:8554/video0_unicast/track2 RTSP/1.0
v4l2rtspserver: User-Agent: LibVLC/3.0.12 (LIVE555 Streaming Media v2016.11.28)
v4l2rtspserver: Transport: RTP/AVP;unicast;client_port=57664-57665
v4l2rtspserver: Session: 533DF8D4
aicap: IMP_AI_Enable          = 0
aicap: IMP_AI_SetChnParam     = 0
aicap: IMP_AI_EnableChn       = 0
aicap: IMP_AI_SetVol(100)     = 0
aicap: streaming to /tmp/camd-audio.fifo (rate=8000)
camd: go after 2600 ms (rtsp reader attached)
RTSP unhealthy (down or no sprop) while camera running; rebuilding stack   ← アプリ自身の watchdog
/usr/bin/v4l2rtspserver: Process exited with status 143                    ← killall SIGTERM(=143)
aicap: reader gone, reopening /tmp/camd-audio.fifo
GenServer #PID<0.329.0> terminating
** (stop) :error_exit_status
v4l2rtspserver exited (:error_exit_status); restarting
Native camera RTSP server started on port 8554
v4l2rtspserver: log level:500
v4l2rtspserver: [NOTICE] (main.cpp:247) Version: 1 live555 version:2025.10.13
/usr/bin/v4l2rtspserver: Process exited successfully                       ← :normal 終了
v4l2rtspserver exited (:normal); restarting
Native camera RTSP server started on port 8554
v4l2rtspserver: log level:500
v4l2rtspserver: [NOTICE] (main.cpp:247) Version: 1 live555 version:2025.10.13
v4l2rtspserver exited (:epipe); restarting                                 ← 以後 :epipe が連続
...(同パターンが 5 回以上連続)
```

重要な点:

1. **track1(映像)・track2(音声)双方の SETUP が実際に成功しており、
   `Session:` も確立している**。`LibVLC/3.0.12 (LIVE555 Streaming Media
   v2016.11.28)` という User-Agent の RTSP クライアントが実際に接続して
   いる(このプロジェクトのコード内には該当する自己ヘルスチェック用
   RTSP クライアントの実装は見当たらず — `grep -rn "LibVLC" lib/` は
   ヒット無し — 何らかの外部クライアントが継続的にポーリングしている
   可能性がある)。
2. `aicap` の `IMP_AI_*` 初期化もすべて `=0` で成功し、実際に
   ストリーミングを開始している。
3. この**正常動作している最中に**、アプリ自身の `rtsp_healthy?/0`
   (`camera_native.ex`、127.0.0.1 へ `DESCRIBE` を送り 1.5 秒以内に
   応答の SDP に `sprop-parameter-sets=` が含まれるかを見る既存の
   ウォッチドッグ)が unhealthy と判定し、`restart_stack()`
   (`killall atomcam2-camd v4l2rtspserver`、SIGTERM)を自ら実行している。
4. その後の再起動サイクルでは、**バージョンバナーを表示した直後
   (`Create V4L2 Source...` 等、後続のはずのログが一切出る前)に
   `:epipe` で即終了**するパターンが繰り返される。ただし
   `RingLogger` は Wi-Fi ドライバの `[atbm_log]:atbm_sdio_irq_period:Miss`
   のような無関係なログでも埋まるため、**「後続ログが本当に出ていない」
   のか「リングバッファから溢れて見えないだけ」なのかは未確定**。

### 1-4. A/B 切り分け(すべて `mix firmware` → `mix upload` → 再起動で実施)

| 構成 | 結果 |
| --- | --- |
| ① 音声フル(`v4l2rtspserver` に FIFO 引数あり、`aicap` 起動) | 数十秒 running → 長時間 degraded(§1-2) |
| ② `v4l2rtspserver` の起動引数から音声 FIFO 部分だけ除去(`aicap` は起動したまま) | 同じパターンで再現(67s running → 76s degraded → 観測終了まで degraded) |
| ③ `aicap` 自体も起動を止める(実質 main `06ab157` と機能的に同一) | **それでも同じパターンで再現**(44〜68s running → 76s degraded → 観測終了まで degraded) |

**結論: 音声機能(FIFO 引数・`aicap` 常駐のどちらも)を完全に排除しても
同じクラッシュループが再現するため、今回追加した音声パッチが原因では
ない。**

### 1-5. [[atomcam2-rtsp-stability]] との整合性の疑問

2026-08-05 の記録では「`v4l2rtspserver` の `:epipe` crash-loop は
sprop 捕捉切り分けで `killall` を連打した churning が誘発したもので、
**叩かず放置すれば settle し 6h 安定**、恒久バグではなかった」と結論
されている。

今回は:
- **`killall` 連打などの外部からの churning は一切行っていない**
  (通常の `mix upload` による OTA 再起動のみ)。
- §1-3 のとおり、churning の発生源は **アプリ自身の `rtsp_healthy?`
  ウォッチドッグによる自発的な `restart_stack()`** であり、2026-08-05
  の「人間が `killall` を連打した」ケースとは発生源が異なる。
- 数分程度の観測では 2026-08-05 のような完全な settle を確認できて
  いない(ただし観測時間が短いだけの可能性もあり、断定はできない)。

---

## 2. 有力仮説(確率評価つき、主観)

| 仮説 | 主観確率 | 補足 |
| --- | --- | --- |
| `rtsp_healthy?` ウォッチドッグの誤検知が自発的な churning を生み、それが今回の crash-loop の引き金になっている | 35〜45% | §1-3 で「track1/track2 とも SETUP 成功済み・aicap もストリーミング中」という明らかに健全な状態で unhealthy 判定・`restart_stack()` が発火している。2 トラック構成になった SDP サイズ・応答生成タイミングの変化が `rtsp_healthy?` の 1.5 秒/4096 バイトという閾値に影響している可能性 |
| 外部の未知 RTSP クライアント(`LibVLC/3.0.12`)による頻繁な SETUP/TEARDOWN が `v4l2rtspserver` 自体を不安定化させている | 20〜30% | 何のクライアントか特定できていない。ユーザ環境で常時ポーリングしている監視ソフト等の可能性 |
| [[atomcam2-rtsp-stability]] に記録済みの pre-existing な `v4l2rtspserver`/live555 側のバグが、2026-08-05 とは異なる条件(churning の発生源が変わった、camd/v4l2rtspserverのバージョンが変わった等)で再発している | 20〜30% | §1-4③ で音声機能ゼロでも再現するため、根はここ(または上記2つ)にある |
| 87MB という厳しいメモリ制約下で、`aicap` 追加分のフットプリントが間接的にタイミングへ影響 | 5〜10% | §1-4③(aicap 完全停止)でも再現したため主因の可能性は低いが、`aicap` が「システムに一度でも常駐した」ことによる何らかの残留影響(FIFO 関連の状態等)は未検証 |

---

## 3. 未解明事項

- `v4l2rtspserver` が実際に**どこで** `:epipe` 終了しているのか
  (プロセスのクラッシュか、それとも `restart_stack()` の `killall`
  SIGTERM を MuonTrap 側が `:epipe` として報告しているだけなのか)。
  §1-3 のログでは `:error_exit_status`(status 143, killall 由来と
  明確)、`:normal`(exit 0)、`:epipe` の 3 種類の終了理由が混在して
  おり、**`:epipe` だけが指すものが何なのか特定できていない**。
- `LibVLC/3.0.12 (LIVE555 Streaming Media v2016.11.28)` の正体。
  ユーザ環境の何が RTSP へ継続的に接続しているか。
- `rtsp_healthy?` が「明らかに健全な状態」で unhealthy と誤判定した
  タイミングでの実際の DESCRIBE 応答内容(タイムアウトしたのか、
  sprop 無しの不完全な SDP が返ったのか)。
- 2026-08-05 の「6h 安定」実証時と今回とで、camd/`v4l2rtspserver` の
  バージョンやビルド条件に差分がないか(未比較)。

---

## 4. 検討中の対策と相談したい論点

### 案 A: `rtsp_healthy?` の閾値・判定方法を見直す

- 現状: 127.0.0.1 への DESCRIBE、1.5 秒 or 4096 バイトで打ち切り、
  `sprop-parameter-sets=` の有無のみで健全性判定。2 トラック化で
  SDP が伸びたが、673 バイト程度でありサイズ超過の可能性は低い。
- **論点(1)**: それでも誤検知が起きるなら、タイムアウトを緩める、
  リトライを増やす、あるいは「DESCRIBE が失敗した場合のみ unhealthy」
  とし sprop チェックを補助的な扱いに格下げする、といった方向性は
  妥当か。

### 案 B: `:epipe`/`:normal`/`:error_exit_status` の実際の意味を切り分ける

- **論点(2)**: `MuonTrap.Daemon` の `exit_status_to_reason` がこれらを
  どうマッピングしているかコードレベルで確認し、`:epipe` が
  「プロセスのクラッシュ」なのか「ポートの通信断」なのかを先に
  確定すべきではないか。

### 案 C: 外部クライアントの特定

- **論点(3)**: `LibVLC` UA のクライアントを一時的に遮断(ファイア
  ウォール等)した状態で同条件の再現試験を行い、影響があるか見る
  価値はあるか。ユーザへの確認(心当たりの有無)を先にすべきか。

### 案 D: 音声機能のマージ判断

- **論点(4)**: 音声機能自体は §1-4 で無実と確定しているため、
  「crash-loop の真因調査とは切り離して先に音声機能をコミットして
  良いか」「それとも crash-loop 解消が先か」。前提として、この
  crash-loop は音声機能の有無に関わらず main 相当の構成でも起きる
  **既存の問題**である。

---

## 5. 制約と前提

- 87MB RAM の機体([[atomcam2-approach-b]])。
- 制御カーネルは差し替え禁止([[atomcam2-control-kernel]])。
- 実機を過度に叩かない・破壊的操作は確認を取る
  ([[atomcam2-device-handling]])。今回の調査でも `killall`/強制的な
  reboot は行わず、`mix upload`(OTA、自動 A/B 再起動)のみを使用した。
- カナリヤ機は 2026-08-13 時点で 192.168.222.56(31.31 ネットワーク
  停止中のため移動、[[atomcam2-canary-device]])。
- 音声機能自体のコードは [RTSP 音声追加 提案書](20260812_RTSP_音声追加_提案書.md)
  参照。作業ツリー上は未コミット。

---

## 6. 求める意見(要約)

1. §1-3 で観測された「健全な状態からの `rtsp_healthy?` 誤検知
   → 自発的 `restart_stack()`」が crash-loop の主因という仮説は
   妥当か。他に優先して切り分けるべき点はあるか。
2. `:epipe`/`:normal`/`:error_exit_status` という 3 種の終了理由を
   どう解釈すべきか(案 B)。
3. [[atomcam2-rtsp-stability]] の「churning 起因の一過性」という
   2026-08-05 の結論を、今回の事象に対して撤回・修正すべきか。
4. 音声機能のコミット可否(案 D)についての判断。
5. 全体として、この crash-loop の真因調査にどこまでコストを掛ける
   べきか(優先順位)。

---

## 7. セカンドオピニオン回答(2026-08-13)と方針確定

### 総合判定

主犯候補の優先順位:

| 優先 | 仮説 / 調査 | 評価 |
| --- | --- | --- |
| ★★★★★ | `rtsp_healthy?` の誤検知 → `restart_stack()` → 自発的 churning | 最優先 |
| ★★★★★ | `:epipe` の意味を MuonTrap レベルで確定 | 最優先 |
| ★★★★☆ | `LibVLC` クライアントの正体・接続周期を確認 | 高優先 |
| ★★★☆☆ | 2026-08-05 と今回の binary/version/config 差分比較 | やる価値あり |
| ★★☆☆☆ | `v4l2rtspserver`/live555 自体の恒久バグ調査 | 現段階では後回し |
| ★☆☆☆☆ | audio/aicap が主因 | ほぼ除外済み |

### 是正点

- **`:epipe` を「`v4l2rtspserver` がクラッシュした」と解釈するのは時期
  尚早**。`:normal`(exit 0)・`:error_exit_status`(status 143、
  `killall` の SIGTERM に一致)とは異なるレイヤーの情報である可能性が
  高く、`MuonTrap.Daemon` レベルでの生成箇所を先に確定すべき。
- §1-3 の「健全な SETUP 成立直後に unhealthy 判定 → 自発的
  `restart_stack()`」という順序こそが最重要の手掛かり。**RTSP server
  が完全に死んでいた証拠ではなく、`rtsp_healthy?` が一時的に条件を
  満たさなかっただけ**という可能性の方が高い。
- [[atomcam2-rtsp-stability]] の「2026-08-05: churning を止めれば
  settle した」という**実験結果自体は有効**。ただし「`:epipe` は
  churning による一過性」への一般化は**撤回ではなく条件付き修正**
  ("恒久バグではない" は保留に戻す): 今回は**アプリ自身の watchdog が
  churning を自動生成している**新しいパターンであり、8/5 の知見を
  一段深く説明する事例と捉えるのが妥当。
- 音声機能(`atomcam2-aicap` + FIFO パッチ)は §1-4 の3段階 A/B により
  **無実と確定**。crash-loop 調査とは切り離し、**先にコミットしてよい**。

### `:epipe` の正体をコードで確認(本ドキュメント作成時に追加調査)

セカンドオピニオンの指摘(§17)を受け、`deps/muontrap` のソースを確認した:

- `MuonTrap.Daemon.handle_info({port, {:exit_status, status}}, state)`
  (`daemon.ex:273-286`)は **`status == 0` → `:normal`**、**それ以外 →
  `state.exit_status_to_reason.(status)`**(既定値は
  `fn _ -> :error_exit_status end`)という 2 択しか生成しない。
- `camera_native.ex` は `MuonTrap.Daemon.start_link/3` 呼び出しで
  **`exit_status_to_reason` オプションを一切渡していない**
  (`grep -n "exit_status_to_reason" camera_native.ex` はヒット無し)。
  つまり非ゼロ終了は常に `:error_exit_status` になるはずで、
  **`exit_status_to_reason` 経由で `:epipe` が生成されることはあり
  得ない**。
- `MuonTrap.Daemon` は **`Process.flag(:trap_exit, true)` を一切呼んで
  いない**(daemon.ex 全体を grep して確認)。`Port.open/2` で開いた
  ポートはデフォルトで呼び出しプロセスに **link** される。
- 以上から、`:epipe` は `{port, {:exit_status, status}}` 経路(§1-3 で
  観測した `:normal`/`:error_exit_status`)とは**別のレイヤー**、
  すなわち **ポート自体が `:epipe` を exit reason として送出する
  link シグナルによって、trap_exit していない `MuonTrap.Daemon`
  GenServer が直接 kill される**、という経路である可能性が非常に高い
  と判断した。これは `v4l2rtspserver` 自身の異常終了(SIGSEGV 等)
  ではなく、**`muontrap` ラッパー(`priv/muontrap`)とのポート通信
  自体が壊れた**ことを示している可能性がある(特に、直前の
  `restart_stack()` による強制 kill 直後の急な再起動で、ポート/
  cgroup の後始末と新規 `Port.open` がレースしている場合に起きやすい
  と推測される)。**未実証の推測であり、実機での再現実験による裏付け
  が必要。**

### 確定した進行順序

1. **watchdog 無効化実験(最優先)**: `rtsp_health/1` の
   `restart_stack()` 呼び出しのみを一時的に無効化(`v4l2rtspserver`
   自体の異常終了時の再起動監視は残す)したビルドを投入し、数十分〜
   1 時間程度放置。**安定すれば主犯は watchdog 誤検知**、**それでも
   `:epipe` が自然発生するなら `v4l2rtspserver`/`muontrap` 側の
   問題**という、非常に情報量の多い一発の切り分けになる。
2. `rtsp_healthy?/0` の判定を boolean ではなく `connect/response/
   elapsed_ms/sdp_bytes/sprop` を含む構造化ログにし、実際に何が
   閾値を割っているかを可視化する。
3. `LibVLC/3.0.12` クライアントの接続元 IP・周期を記録して正体を
   特定する(ファイアウォール遮断などの積極的な遮断は最初の手段に
   しない)。
4. 2026-08-05 時点との camd/`v4l2rtspserver`/依存バージョン差分を
   比較する。
5. 上記で解消しない場合のみ、`v4l2rtspserver`/live555 自体の深掘りへ
   進む。

### 音声機能について

**A/B③(`aicap` 完全停止)までの切り分けにより、コミットしてよいと
判断する。** RTSP 安定性調査とは別 issue/別コミットとして扱う。

> 総合評価: 今回のセカンドオピニオンで最も価値が高かったのは、
> 「`:epipe` = クラッシュ」という早計な解釈を止め、`MuonTrap` の
> 実装確認を最優先事項に格上げした点。実装確認の結果、`:epipe` が
> `exit_status_to_reason` 経由ではなく **link されたポートからの
> 直接シグナル**である可能性が高いと判明し、次の一手(watchdog
> 無効化実験)の設計にも直結した。

## 8. watchdog 無効化実験の結果(2026-08-13)と統合された結論

### 8.1 実験内容

`camera_native.ex` に `@watchdog_restart_enabled false` を追加し、
`rtsp_health/1` が `restart_stack()` を呼ぶ経路だけを無効化(health check
自体は継続し、`connect/response/elapsed_ms/sdp_bytes/sprop/healthy` を
毎回 `Logger.info` で構造化ログ出力)。`v4l2rtspserver`/`camd` の通常の
異常終了時リスタート(`MuonTrap` の `{:EXIT, pid, reason}` ハンドラ)は
そのまま維持。この状態で音声フル機能ビルドを `mix upload` → 起動後、
**110 秒間隔で 20 回(約 35 分)** `status.json` を無人で記録した。

### 8.2 結果: 20/20 すべて `running`/`rtsp_alive: true`

```
uptime=59s   .. uptime=2150s (約35分)
全20サンプル: phase=running rtsp_alive=True
degraded 検出: 0件
```

**watchdog 無効化後、定常運転中に自然発生する `:epipe` は一度も観測
されなかった。** これは 2026-08-13 §1 で確認した「watchdog 有効時は
数十秒 running → 長時間 degraded を延々繰り返す」という挙動とは対照的。

### 8.3 追加実験: 手動 `restart_stack()` 相当(killall)を 1 回実行

観察の途中、`rtsp_healthy?` が「sprop 無し」を継続検知しているのに
watchdog が無効で放置され続けている状態(§8.4 参照)を解消するため、
SSH IEx から `System.cmd("killall", ["atomcam2-camd", "v4l2rtspserver"])`
を **手動で 1 回だけ**実行した。RingLogger を直後に確認したところ:

```
:normal
:normal
:epipe
:epipe
:epipe
:normal ← track1 SETUP OK, track2 SETUP OK, Session確立(ここで映像が一瞬映った)
RTSP health check: ... sprop=false healthy=false
```

**watchdog の自動再トリガーが一切無い状態でも、たった 1 回の再起動操作
だけでこれだけの `:normal`/`:epipe` 連鎖が自然発生した。** その後は
本ドキュメント執筆時点(uptime 1284 秒超)までクラッシュ無く安定継続
している。

### 8.4 sprop と映像表示は別軸だと判明

`killall` 後、SDP の `a=fmtp:96` は**一貫して空(sprop 無し)**のまま
だったが、ユーザは異なるタイミングで 2 回「VLC で映像が映った」と報告
した(1 回目は §8.3 の SETUP 直後、2 回目は uptime 1284 秒の定常運転中)。
sprop-parameter-sets が SDP に無くても、ストリーム中の in-band
SPS/PPS(NAL ユニット)を VLC 側が拾って復旧できる場合があるためと
考えられる。**「SETUP が成功した/映像が映った」ことは「sprop を正しく
捕捉できている」ことの証明にはならない**、という点は今後の判定基準
から外すべき。

### 8.5 統合された因果モデル

以上を総合すると、次の一本の筋で全観測が説明できる:

```
sprop 捕捉は起動ごとの確率的レース([[atomcam2-rtsp]])
        │
        ▼
   ある起動で sprop 捕捉に失敗(§1-3, §8.3 とも実際に発生)
        │
        ▼
   rtsp_healthy?() が「本物の」unhealthy を正しく検知
   (誤検知ではない。§8.2/8.3 で毎回 sprop=false を一貫して観測)
        │
        ▼
   watchdog が restart_stack() を実行(sprop を再度引き直す狙い)
        │
        ▼
   camd + v4l2rtspserver 同時 kill → 再起動という「遷移」自体に
   固有の短時間不安定性がある(§8.3: 1 回の再起動で :normal/:epipe が
   複数回連鎖してから収束。原因未特定 — camd/rtspserver の終了順序、
   FIFO/ポートの再確立レース、V4L2 device の open/close 等が候補)
        │
        ▼
   再起動後の新インスタンスでも sprop 捕捉に失敗する確率がそれなりに
   高い(同じ確率的レースのため)
        │
        ▼
   watchdog が再び unhealthy を検知 → restart_stack() → …
        │
        └──→ 「定常状態としての crash-loop」に見えるものは、実際には
             watchdog が確率的レースに負け続けるたびに再起動遷移の
             不安定性を再発火させている状態
```

**定常運転(再起動が起きていない間)は完全に安定**(§8.2: 35 分/20 回
無傷)。**crash-loop に見える現象の本体は「sprop レースに負ける →
watchdog が再起動 → 遷移不安定性 → 場合によりまた sprop レースに負ける」
というループそのもの**であり、`v4l2rtspserver`/live555 が定常的に
自壊しているわけではない。

### 8.6 更新された結論

1. **§7 の「watchdog 誤検知が主因」は一部修正**: `rtsp_healthy?` の
   判定自体は(少なくとも今回のケースでは)誤検知ではなく毎回正しく
   sprop 欠落を検出していた。問題は判定の正確性ではなく、**その修復
   手段(`restart_stack()`)が発火するたびに、再起動遷移固有の不安定性
   を踏み抜くこと**、および **sprop 捕捉の確率的レースが再起動のたびに
   独立に発生し直すため、運が悪いと再修復に何度も失敗しうる**こと。
2. 2026-08-05 の「churning を止めれば settle した」という観測は、
   今回の因果モデルで完全に説明できる: churning(=繰り返す再起動)を
   止めれば、その1回の再起動遷移が収束した時点のスプロップ状態
   (良し悪しどちらでも)がそのまま固定され、それ以上再起動が起きない
   限り安定して見える。「settle した」のではなく「そこで再起動の連鎖が
   止まった」というのがより正確な描写。
3. **次の焦点は 2 つに分離すべき**:
   - (a) **再起動遷移自体の不安定性**(§8.3 で確認、原因未特定)を
     減らせないか。camd と `v4l2rtspserver` の kill 順序をずらす、
     `killall` 一括ではなく段階的に止める、等が候補。
   - (b) **sprop 捕捉の確率的レースそのもの**(既知、[[atomcam2-rtsp]]
     で過去に「GO 遅延調整・SPS バースト・GO 撤去連続配信・ポーリング
     短縮のいずれも安定化せず」と記録済み)。§8.4 の「in-band SPS/PPS
     で後から復旧しうる」という新知見を踏まえ、**sprop が SDP に無くても
     一定時間は正常系として扱い、性急に `restart_stack()` を呼ばない**
     方向の方が、遷移不安定性(a)を誘発する頻度を減らせる可能性がある。
4. **watchdog の再設計方針(暫定)**: `restart_stack()` を単純に
   「sprop 無し即 rebuild」から、「sprop 無しでも一定時間(例: 数分)は
   様子見し、その間に in-band 復旧しないか確認してから rebuild するか
   判断する」方向に緩和することを次の実装候補とする。

## 9. 実装: 二段階 watchdog(2026-08-13)

§8.6 の方針に沿って `camera_native.ex` の RTSP watchdog を実装し直した。

- `rtsp_healthy?/0`(boolean 1本)を `rtsp_health_check/0`(構造化診断
  マップ `%{connect, response, elapsed_ms, sdp_bytes, sprop}`)に置き換え、
  毎回 `Logger.info` で全項目を記録するようにした(実験用の一時ログでは
  なく恒久化)。
- 状態を `rtsp_fails: 0` 単一カウンタから `rtsp_dead_fails` /
  `rtsp_sprop_fails` の 2 本に分離。
- `escalate_rtsp_health/2` で判定を分岐:
  - `connect == false or response == false`(サーバ自体に応答が無い) →
    従来通り短い閾値(`@rtsp_dead_fail_threshold = 2`、約 40〜60 秒)で
    即 `restart_stack()`。
  - `connect == true and response == true and sprop == false`(応答は
    あるが sprop 無し) → 長い猶予(`@rtsp_sprop_fail_threshold = 15`、
    20 秒間隔で約 5 分)を置いてから `restart_stack()`。連続して健全な
    チェックが 1 回でもあればどちらのカウンタも 0 にリセット。

実機(カナリヤ機 192.168.222.56、UUID `fca49cfd`)へ投入し、起動直後の
health check ログで新ロジックが意図通り動作していることを確認:

```
RTSP health check: connect=true response=true elapsed_ms=1513 sdp_bytes=737 sprop=false dead_fails=0 sprop_fails=0
```

(この起動でも sprop 捕捉には失敗しているが、`dead_fails` 分岐ではなく
`sprop_fails` 分岐でカウントが始まっており、即 rebuild されていないこと
を確認済み。5 分間のフルサイクル完走・実際に rebuild がトリガーされる
挙動までは本ドキュメント執筆時点では未確認 — 今後の長時間観察課題。)

### 9.1 フルサイクルの実機確認(同日、追加観察)

上記の投入後、そのまま観察を継続したところ、`sprop_fails` が
0 → 1 → … → 14 まで一貫して 20 秒間隔で増加し、しきい値 15 に到達した
時点で設計通り rebuild が発火した:

```
RTSP health check: ... sprop=false dead_fails=0 sprop_fails=13
RTSP health check: ... sprop=false dead_fails=0 sprop_fails=14
RTSP sprop-parameter-sets still missing after sustained grace period; rebuilding stack
RTSP health check: connect=true response=true elapsed_ms=1504 sdp_bytes=843 sprop=true dead_fails=0 sprop_fails=0
RTSP health check: ... sprop=true dead_fails=0 sprop_fails=0   (以降 4 回連続で健全)
```

rebuild 後の新インスタンスは **sprop 捕捉に成功**し(SDP に
`sprop-parameter-sets=J00AM+dAPAET8s1AQEB8AAADAAQAAAMAyMkAAehIAAtxt//wKA==,KO48gA==`
が出現)、以後 `sprop_fails` は 0 のまま安定継続(uptime 475 秒超、
クラッシュ無し)。ユーザが VLC で確認した「映像が映った」はこの正常
復旧に一致する。

**§8 の未解明事項だった「5 分猶予後の rebuild が実際にどう振る舞うか」
まで含めて実機で確認できた**: 猶予期間中はプロセス安定(クラッシュ
無し)、猶予明けの rebuild も(今回は)`:epipe` 連鎖に陥ることなく一発で
成功した。二段階 watchdog は設計通り機能していると判断してよい。

継続課題として残るのは、rebuild 自体が §8.3 のように `:normal`/`:epipe`
連鎖を伴うケース(今回は伴わなかった)がどの頻度で起きるか、長期運用
(数時間〜数日)での再現性確認。

## 参考

- [RTSP 音声追加 提案書](20260812_RTSP_音声追加_提案書.md)
- [[atomcam2-rtsp-stability]] — 2026-08-05 時点の crash-loop 記録
  (「churning 起因の一過性」)、および本件を受けた 2026-08-13 追記。
- [[atomcam2-rtsp]] — sprop 捕捉の確率的レース。
- [[atomcam2-device-handling]] — 過度な実機操作を避ける方針。
- [[atomcam2-canary-device]] — カナリヤ機の現在地。
- [[atomcam2-control-kernel]] — カーネル差し替え禁止の制約。
- `examples/atomcam2_nerves_app/lib/atomcam2_nerves_app/camera_native.ex`
  の `rtsp_healthy?/0`・`restart_stack/0`・`rtsp_health/1`。
- `package/v4l2rtspserver/0004-fifo-audio-source.patch`(今回追加、
  A/B で無実と確定)。
- watchdog 無効化実験(§8)のログ全文(セッション固有の一時パスのため、
  恒久保存が必要なら別途 docs 配下へコピーすること):
  `.../scratchpad/watchdog_off_experiment.log`
