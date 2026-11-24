# macOS の Docker Desktop でローカル起動する

このフォーク向けの追加手順です。公式の一次情報は上流の [isucon/isucon2026](https://github.com/isucon/isucon2026) と、リポジトリの `README.md`、`deploy/dev/README.md`、`bench/README.md`、`compose.yaml` を参照してください。

公式の `compose.yaml` や問題アプリのコードは変更していません。上書きは `compose.override.yaml`（git 管理外）にだけ置きます。

競技環境（AWS 5 台、初期 DB 約 18GB）とはスペックもデータ規模も違います。ここに書くスコアは small データでの**ローカル参考値**で、競技のスコアとは比べません。

## なぜ公式手順のままでは落ちやすいか

Docker Desktop 上では、次の 2 点が重なると、初期実装のままでもベンチが失格（スコア 0）や打ち切りになりやすいです。

1. **localhost ポート転送の接続リセット**
   - Docker Desktop の `com.docker.backend` が `127.0.0.1:18090` を Listen します。macOS の `kern.ipc.somaxconn` は既定 **128** です。
   - アイドル時の同時 connect では、128 本までは成功し、256 本だと数十本が `Connection reset by peer` になりました。同じバーストを compose の `edge` ネット内から Router（`172.28.10.2:8080`）へ送ると、1024 本まで全部成功しました。
   - ベンチの最終チェックは最大 300 ユーザーを **64 並行**（`bench/internal/scenario/final.go`）で叩きます。負荷中の通知ストリームが残った状態だと、ホスト経由では backlog を超えて RST し、失格（スコア 0）になります。
   - **回避:** ホストの `go -C bench run .`（既定ターゲット `http://app.127.0.0.1.nip.io:18090`）は Docker Desktop では使わないでください。Linux 向けのベンチバイナリを作り、override の `bench` プロファイルで Router に直接当てます。ホストから `172.28.10.2` には到達できないので、必ずコンテナ側から当てます。

2. **CPU / メモリ上限**
   - 公式 compose 既定はアプリ 1 CPU / 1GiB、DB 2 CPU / 2GiB で、競技 VM（各 2 vCPU / 4GiB）より細いです。
   - 既定のままネットワーク内ベンチを走らせると、asia が 150 人を超えた終盤に 15 秒タイムアウトと 502 が散発し、エラー率 10% 超で打ち切りになりました。OOM や再起動はありませんでした。初期実装の遅さに、Desktop の CPU クォータと仮想化オーバーヘッドが重なった形です。
   - override でアプリを 2 CPU / 2GiB、DB を 2 CPU / 3GiB にしたら、同じ初期実装で通りました。問題アプリのコードは変更していません。

Linux ネイティブの Docker（Desktop ではない）では、ホストから公式どおり `go -C bench run .` で足りることが多いです。この資料は主に macOS の Docker Desktop（および同様に localhost 転送が細い環境）向けです。

## 前提

- Docker Desktop または OrbStack（Compose v2 付き）。後述の参考結果は Docker Desktop 29.9.3 です。
- Docker の Linux VM に、目安として CPU 8、メモリ 10GB 以上、ディスク 25GB 以上。ホスト 16GB 以上を推奨します。
- ホストに Go **1.26.5**（`mise.toml` と同じ）。[mise](https://mise.jdx.dev/) で入れるのが簡単です。datagen はホストで実行し、ベンチは後述のとおり Linux バイナリをコンテナ内で走らせます。
  - mise を使っている場合、クローンした直後はリポジトリルートで一度 `mise trust` が必要です。そのあと `go version` が `go1.26.5` と出ることを確認してください。
  - `mise.toml` には Python の venv 設定もあるため、`no venv found` という警告が出ることがあります。この手順では無視してかまいません（スモークはシステムの `python3` を使います）。ローカル起動だけなら `mise install` で全ツールを入れる必要はありません。
- スモーク用の `python3`（標準ライブラリのみ）。
- `*.127.0.0.1.nip.io` が解決できること。できないときは `/etc/hosts` に次を足します。

  ```
  127.0.0.1 app.127.0.0.1.nip.io asia.127.0.0.1.nip.io europe.127.0.0.1.nip.io america.127.0.0.1.nip.io
  ```

AWS・Packer・Pulumi は使いません。`make ami` は課金が発生するので、この手順では触らないでください。

## 構成とリソース

サービス（`compose.yaml`、プロジェクト名 `isureal-dev`）:

`compose.yaml` に `name: isureal-dev` があるため、ディレクトリ名が違ってもプロジェクト名、ネットワーク名、イメージ名（`isureal-dev-router`）、Router の IP（`172.28.10.2`）は変わりません。すでに同じプロジェクトが動いているとポート 18090 などで衝突します。公式リポジトリの clone などを先に動かしている場合は、そちらで `docker compose down` してから起動してください。

| コンテナ | 役割 | 公式既定 | この override |
|---|---|---|---|
| `router` / `router-control` / `haproxy` / `digest` | 入口・遅延・ダイジェスト | 各 1.0 / 512m | そのまま |
| `app-asia` / `app-europe` / `app-america` | nginx:80 + アプリ:8080 | 各 1.0 / 1g | 各 2.0 / 2g |
| `db-asia` | PostgreSQL 16.9 | 2.0 / 2g（shm 256m） | 2.0 / 3g |

公式既定の合計は約 9 CPU・7GB です。環境変数 `ISUREAL_APP_CPUS` などでも変えられますが、このフォークでは override に直書きしています。

ネットワーク:

- ホスト公開は `127.0.0.1:18090` → router の 8080 のみ。PostgreSQL の 5432 はホストに出ていません。
- 地域ネットは `172.29.1.0/24`〜`172.29.4.0/24`。Router は edge 上 `172.28.10.2`。
- 既定の遅延は同一地域 0、地域間 100ms。帯域は同一地域 1Gbps、地域間 200Mbps。

URL（ブラウザや curl 用。ベンチはネットワーク内から当てる）:

| URL | 説明 |
|---|---|
| `http://app.127.0.0.1.nip.io:18090` | `X-Country-Code`（JP→asia、DE→europe、US→america）で振り分け |
| `http://asia.127.0.0.1.nip.io:18090` など | 地域へ直接 |

実際に動くスタック:

- Web サーバ: 各アプリコンテナの **nginx**。入口は Router 側の **HAProxy**。この compose に Apache はありません。
- アプリ: 既定は **Go**（`webapp/go`）。`ISUREAL_WEBAPP_LANGUAGE` で他言語に切り替えできます。
- DB: **PostgreSQL 16.9**。ユーザー / DB 名 `isureal`。

## データセット（必ず small で始める）

`002-seed.sql` は git 管理外です。起動前にホストで生成します。写真の元データ `dataset/photos/` はリポジトリ内にあり、追加ダウンロードは不要です。

| 規模 | 生成 | 中身の目安 | 用途 |
|---|---|---|---|
| **small（既定）** | `go -C webapp/datagen run .` | ユーザー 1,000、履歴 30 日 | compose 開発・手元ベンチ |
| large | `go -C webapp/datagen run . -scale large` | ユーザー 5,000、365 日、画像合計約 14GB。AMI 投入後の DB は約 18GB | 本番相当。ノート PC では非推奨 |

bench の `-scale` は datagen と同じにしてください。

ディスクの目安（small）: イメージとレイヤでおおよそ 8〜15GB。空き 25GB 以上を推奨します。

## そのほか Docker Desktop で引っかかりやすい点

- **アーキテクチャ:** 既定の Go アプリと Router はホストの arch に合わせたネイティブイメージになります。`--platform linux/amd64` は付けないでください。
- **`NET_ADMIN` と `tc` netem:** router / app / db が `NET_ADMIN` を持ち、地域間遅延は `tc qdisc` で再現します。Docker Desktop でも動くことを確認済みです。`compose.yaml` は地域ネットをわざと `internal: false` にしています（Desktop では internal ネットだと Router 経由転送が落ちる）。戻さないでください。
- **起動時の router-control エラーは無視してよい:** `HAProxy runtime API: dial tcp 127.0.0.1:18001: connection refused` が起動直後に連続することがあります。haproxy はアプリの healthy 待ちのあとで起きるため、ただの起動レースです。数秒後に `Router configuration applied` が出れば関係ありません。
- **初回ビルド:** `digest` が Rust リリースビルドするので、キャッシュが空だと時間がかかります。`--wait-timeout 180` を付けてください。

## 起動・ベンチ・リセット

リポジトリルートで、先に上書き設定を置きます。Compose が `compose.override.yaml` を自動で読みます。`profiles: [bench]` なので、普通の `up` には乗りません。

```sh
cp compose.override.mac.example.yaml compose.override.yaml

# 1. 初期データ（初回、または dataset を変えたとき）
go -C webapp/datagen run .

# 2. 起動（override の CPU/メモリ上限が適用される）
docker compose up -d --build --wait --wait-timeout 180

# 3. スモーク（DB はリセットしない）
python3 deploy/dev/smoke.py

# 4. ベンチはホストから当てない。Linux バイナリをネットワーク内で走らせる
./scripts/local-mac-bench.sh
# または手で:
#   mkdir -p bin
#   # go -C は bench/ をカレントにするので、出力先はリポジトリルートの $PWD から書く
#   GOOS=linux GOARCH=$(go env GOARCH) CGO_ENABLED=0 go -C bench build -o "$PWD/bin/bench-linux"
#   docker compose --profile bench run --rm --no-deps bench
# 進捗は stderr、結果 JSON は stdout。-scale は datagen と揃える（既定 small）。
# ターゲットは http://172.28.10.2:8080、Host は app.127.0.0.1.nip.io。

# 5. 停止（DB ボリュームは残す）
docker compose down

# 6. 完全リセット（Postgres ボリューム破棄。次の up で seed から入れ直す）
docker compose down -v
```

`GOARCH` はホストに合わせます。Apple Silicon なら `arm64`、Intel Mac なら `amd64` です。linux/amd64 のネイティブ Docker では、このクロスコンパイルとネットワーク内ベンチは通常不要です。

上限だけ変えてコンテナを作り直す（ボリュームは残す）:

```sh
docker compose up -d --wait --wait-timeout 180
```

初期化 API（共有 DB を負荷走行前の状態に戻す。seed の全入れ直しではない）:

```sh
curl -X POST -H 'Host: app.127.0.0.1.nip.io' http://127.0.0.1:18090/api/initialize
```

トラブル時:

```sh
docker compose ps
docker compose logs --tail=200 router router-control haproxy digest db-asia app-asia
docker compose exec router wget -qO- http://127.0.0.1:18081/healthz
docker compose exec db-asia uname -m
docker compose exec router tc qdisc show
sysctl kern.ipc.somaxconn   # 既定 128。ホスト経由ベンチが RST する理由
```

ログを見るときも `docker compose` 経由です。ホストにはログ用のボリュームはありません。

- **nginx**（各 `app-*`）: コンテナ内の access / error ログ。ホストへは出していません。
- **アプリ（Go）**: `docker compose logs app-asia` など。
- **PostgreSQL**: 公式イメージは stderr → `docker compose logs db-asia`。5432 は公開されていません。`docker compose exec -T db-asia psql -U isureal -d isureal`。
- **HAProxy / Router**: `docker compose logs haproxy router`。

## 参考結果

確認した上流の版は `6a3958f`、問題コードは未変更、データは small です。

マシン: MacBook Air M2、ホストメモリ 24GB。Docker Desktop 29.9.3、Linux VM 8 CPU / 約 12GiB。

| 項目 | 結果 |
|---|---|
| 初回 `docker compose up --build --wait`（イメージが空のあと） | 約 2 分（digest の Rust ビルド済みならさらに短い） |
| スモーク `python3 deploy/dev/smoke.py` | PASS |
| 地域間遅延 | 約 100ms で再現できていた |
| ホストから `go -C bench run .`（`127.0.0.1:18090`） | **失敗** `pass=false score=0`。最終チェックで大量の `connection reset by peer`。負荷 60 秒自体は完走 |
| ネットワーク内ベンチ + 既定上限（app 1CPU/1GiB） | **失敗**。RST は消えたが、終盤 55–60 秒のエラー率 17.2%（15 秒タイムアウトと 502）で打ち切り |
| ネットワーク内ベンチ + 上限引き上げ（app 2CPU/2GiB、db 2CPU/3GiB） | **成功** `pass=true score=23552` language=go。failures 0。所要 約 86 秒（準備 20 秒 + 負荷 60 秒 + 最終チェック） |

`score=23552` は small・ローカル上限での**参考値**です。本番 large や競技 5 台とは比べないでください。

そのほかの注意:

- ホストの `go -C bench run .` を使うと、Docker Desktop ではまた最終チェックで RST してスコア 0 になりやすいです。
- Postgres `max_connections` 既定 100 に対し、Go 初期実装は接続プールを台あたり 30 に開きます（× 3 台）。今回は未到達ですが、負荷を上げると詰まる可能性はあります。
