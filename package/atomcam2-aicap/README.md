# atomcam2-aicap

マイク音声を RTSP へ配信するための常駐キャプチャデーモン
(ビルド済みバイナリ + ソース)を rootfs に載せる Buildroot パッケージ。
`libimp` の `IMP_AI_*` でマイクを継続的にポーリングし、16bit PCM を
big-endian(RTP L16)へ変換して名前付きパイプへ書き出す。読み出し側は
`package/v4l2rtspserver` の `FifoAudioCapture`(0004-fifo-audio-source.patch)。
詳細は [RTSP 音声追加の実装](../../docs/worklog/20260812-RTSP音声追加の実装.md)。

## 収録物

- `atomcam2-aicap` — libimp `IMP_AI` でマイクを常時キャプチャし、
  FIFO へ書き出すデーモン(→ `/usr/bin/atomcam2-aicap`)
- `atomcam2-aicap.c` — 上記バイナリのソース(`airec.c` を常駐化した派生)

## なぜビルド済みバイナリをコミットするか

`atomcam2-camera`/`atomcam2-boot-announce` と同様、実機の
`/atom/system/lib/libimp.so`(uClibc 4.7.2 ビルド)を動的リンクするため
Buildroot のツールチェーンではビルドできない。Ingenic 純正の MIPS
uClibc ツールチェーンと T31 SDK 1.1.1 ヘッダが必要。

## ビルド手順

```sh
mips-linux-uclibc-gnu-gcc -muclibc -msoft-float -O2 -march=mips32r2 \
  -I<sdk-include> \
  -Wl,--dynamic-linker=/atom/lib/ld-uClibc.so.0 \
  atomcam2-aicap.c -L<device-libs> -limp -lalog -lpthread -lm -lrt \
  -o atomcam2-aicap
```

`-muclibc -msoft-float` が必要(multilib ツールチェーンで、指定が無いと
glibc/hard-float 版が選ばれる)。`libimp.so` 自体は hard-float ビルド
なので "uses -mhard-float" のリンカ警告が出るが無害
(`atomcam2-camera`/`atomcam2-boot-announce` と同じ)。

## 使い方

```
atomcam2-aicap [fifo] [rate] [gain]
  既定: /tmp/camd-audio.fifo 8000 (gain: -1 =既定値のまま)
```

- FIFO が無ければ `mkfifo` で作成する。
- FIFO の書き込み側 `open()` は読み出し側(v4l2rtspserver)が繋がるまで
  ブロックする(標準的な名前付きパイプの挙動、ポーリング不要)。
- 読み出し側が切断された場合(`EPIPE`)は FIFO を再オープンして待ち直す
  (プロセス自体は終了しない、`SIGPIPE` は無視設定)。
- 実行条件は `atomcam2-boot-announce` の「マイク録音」機能と同じ
  (`audio.ko` ロード済み、`iCamera_app` 不使用)。

## 既存のマイク録音テストとの排他

`aicap` は IMP_AI デバイスを常時保持するため、`airec`(one-shot)との
同時実行は `IMP_AI_Enable` が失敗する見込みだった。ダッシュボードの
「マイク録音(5秒)」/「録音を再生」(`HardwareTest.mic_record/0` /
`mic_play/0`)はこの衝突を避けるため削除済みで、動作確認は RTSP 音声
(この `aicap` の配信そのもの)で代替する。経緯は
[RTSP 音声追加の実装](../../docs/worklog/20260812-RTSP音声追加の実装.md) 参照。
