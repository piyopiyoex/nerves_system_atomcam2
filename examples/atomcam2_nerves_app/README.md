# Atom Cam 2 向け Nerves サンプルアプリ

このアプリは `nerves_system_atomcam2` の動作確認と開発の基準実装です。
Wi-Fi、有線 LAN、mDNS、SSH、遠隔更新、ネイティブカメラ、RTSP、状態画面を含みます。

初回導入は [はじめに](../../docs/はじめに.md)、全体構成は
[構成](../../docs/構成.md)、操作は [運用](../../docs/運用.md) を参照してください。

## 初回設定

```sh
export MIX_TARGET=atomcam2
export MIX_ENV=prod
export NERVES_WIFI_SSID="your-ssid"
export NERVES_WIFI_PASSPHRASE="your-passphrase"

# 使用する鍵を明示する場合
export ATOMCAM2_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub"
```

```sh
mix setup
mix firmware.burn
```

`mix firmware.burn` は選択した MicroSD カードを消去します。

## 接続

```sh
ping nerves.local
ssh nerves@nerves.local
```

## 現在の標準映像経路

ネイティブカメラは既定で起動します。

```elixir
Atomcam2NervesApp.CameraNative.status()
```

RTSP URL:

```text
rtsp://<機器のIP>:8554/video0_unicast
```

状態画面:

```text
http://<機器のIP>/
```

管理操作を有効にするにはパスワードを設定します。

```elixir
Atomcam2NervesApp.Dashboard.set_password("十分に長い固有のパスワード")
```

## 遠隔更新

```sh
mix firmware
mix upload nerves.local
```

## 開発時にローカルの system を使う

既定では GitHub Release の `v0.5.0` を取得します。このリポジトリ内の system を
直接使って変更を確認する場合は次を設定します。

```sh
export ATOMCAM2_SYSTEM_SOURCE=local
```

その後、依存関係を更新してビルドします。

```sh
mix deps.get
mix firmware
```

## 任意の互換機能

標準 Atom アプリと既存録画を必要とする場合は、ベンダーカメラ互換機能を使用できます。
現在の標準経路ではありません。ネイティブカメラとの同時運用は保証していません。

設定と検証は [運用](../../docs/運用.md#ベンダー互換機能を使う) を参照してください。
