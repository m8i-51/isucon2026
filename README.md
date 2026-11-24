# ISUCON2026 問題

ISUCON2026 の問題アプリケーション「ISUReal」、ベンチマーカー、競技環境の構築コードを収録しています。
ISUReal は、asia、europe、america の3地域で写真を共有する SNS です。

## このフォークについて

これは [isucon/isucon2026](https://github.com/isucon/isucon2026) の**非公式**フォークです。公式リポジトリではありません。

macOS の Docker Desktop でローカルに立ててベンチを通すための追加資料だけを入れています。公式の `compose.yaml` や問題アプリのコードは変更していません。

- 手順と理由: [docs/local-mac.md](docs/local-mac.md)
- 上書き設定の例: [`compose.override.mac.example.yaml`](compose.override.mac.example.yaml)（使うときは `compose.override.yaml` にコピーする）
- ネットワーク内からベンチを回すスクリプト: [`scripts/local-mac-bench.sh`](scripts/local-mac-bench.sh)

- [ISUCON2026 当日マニュアル](https://gist.github.com/whywaita/17f3ab1a8c1b7585c571f4f8afe5f531)

## ISUCON2026 で使用した競技環境

1チームあたり、以下の5台で構成されます。
地域間の遅延と帯域は Router が再現します。
初期状態の DB は asia の db1 です。

| ホスト | 役割 | InstanceType |
|---|---|---|
| app1 | asia のアプリケーションサーバー | c5.large (2vCPU, 4GiB Mem) |
| app2 | europe のアプリケーションサーバー | c7i.large (2vCPU, 4GiB Mem) |
| app3 | america のアプリケーションサーバー | c7i.large (2vCPU, 4GiB Mem) |
| db1 | asia の DB サーバー | c5.large (2vCPU, 4GiB Mem) |
| Router | 地域間の通信制御とベンチマーカーの入口 | c6in.large (2vCPU, 4GiB Mem) |

- ボリューム: gp3、アプリケーションサーバーと DB サーバーは 60GB、Router は 20GB
  - db1 は 6,000 IOPS、200 MiB/s
- ベンチマーカー: ECS Fargate (4vCPU, 8GiB Mem)

初期実装は Go、Ruby、Rust、Python、PHP、Perl、Node.js です。

## AWS 上での過去問環境の構築方法

AMI は提供していません。
Packer と Ansible で AMI を作成し、Pulumi で環境を構築してください。

必要なツールとバージョンは [mise.toml](mise.toml) に記録しています。
Pulumi は [provisioning/aws/mise.toml](provisioning/aws/mise.toml) で指定しています。
AWS の認証情報を設定してから実行してください。

### AMI のビルド

リポジトリルートで以下を実行します。
問題サーバー（app1〜3 と db1 で共用）と Router の2種類の AMI を作成します。

```sh
make ami                          # 両方
make ami ROLE=problem-server      # 問題サーバーのみ
make ami ROLE=router              # Router のみ
```

問題サーバーの AMI には本番規模の初期データ（DB で約 18GB）を投入するため、ビルドに 45 分ほどかかります。
ビルド用インスタンスは c6i.2xlarge、ディスクは 60GB です。
すべての言語の初期実装をビルドするため、必要に応じて下記の[対象言語の絞り込み](#対象言語の絞り込み)も確認してください。

### Pulumi による環境の構築

Pulumi の backend と stack は各自で用意してください。
`provisioning/aws/mise.toml` の `PULUMI_BACKEND_URL` を使用する backend に変更し、`pulumi stack init` で stack を作成します。
stack の設定は `pulumi config set` で `Pulumi.<stack>.yaml` に書き込まれます。

```sh
make aws-infra-install

cd provisioning/aws
pulumi stack init mystack
pulumi config set aws:region ap-northeast-1
pulumi config set --path 'clientCidrs[0]' 203.0.113.10/32   # 手元の IP アドレス
cd ../..

make aws-infra-preview STACK=mystack
make aws-infra-up STACK=mystack
```

指定がなければ、タグが一致する最新の AMI を使用します。
TLS 証明書を指定しない場合は自己署名証明書を生成します。
その他の設定項目は [provisioning/README.md](provisioning/README.md) を参照してください。

使い終わったら環境を削除してください。
AMI と EBS スナップショットは自動では削除されません。

```sh
make aws-infra-destroy STACK=mystack
```

### 構築時の注意事項

- 1チームで 10 vCPU を使用します。オンデマンドの標準インスタンスの vCPU 上限（`L-1216C47A`）に注意してください
- Router の `TCP/443` と `TCP/8080` は `clientCidrs` からのみ受け付けます。手元の IP アドレスが変わったら設定し直してください
- SSH は公開していません。SSM Session Manager または EC2 Instance Connect Endpoint で接続してください
  ```sh
  aws ec2-instance-connect ssh --instance-id i-xxxxxxxx --connection-type eice
  ```
  - 接続後は `sudo su - isucon` で `isucon` ユーザーに切り替えてください
- Router の IP アドレスとホスト名は `pulumi stack output teamOutputs` で確認できます

## Ansible による AMI の構成

AMI の中身は [provisioning/ansible](provisioning/ansible/README.md) の Ansible で構成します。
`make ami` から Packer 経由で実行されます。

| playbook | 内容 |
|---|---|
| `prepare.yml` | 手元で webapp、frontend、datagen、Router などをビルドする |
| `problem-server.yml` | 問題サーバー（app1〜3 と db1）の言語環境、PostgreSQL、nginx、webapp を構成し、初期データを投入する |
| `router.yml` | Router と HAProxy を構成する |

チームごとに異なる設定（地域、DB の接続先、起動するサービス、Router の設定）は Pulumi の user-data が起動時に設定します。

### 対象言語の絞り込み

デフォルトでは、初期状態に含まれるすべての言語環境をビルドするため、時間がかかります。
`provisioning/ansible/problem-server.yml` の言語のロールと、`provisioning/ansible/roles/webapp/tasks/main.yml` の該当する言語のタスクをコメントアウトすることで、ビルド時間を短縮できます。

## ベンチマーカーの実行

構築した環境の Router を対象に、リポジトリルートから実行します。
ベンチマーカーは開始時に対象アプリケーションのデータを初期化します。

```sh
make aws-benchmark STACK=mystack TEAM=1
```

Router のアドレスを直接指定する場合は、以下のように実行します。

```sh
go -C bench run . -target "http://ROUTER_IP:8080" -host "APP_HOSTNAME" -scale large
```

`-scale` は AMI に投入した初期データの規模（本番は `large`）に合わせてください。
写真データ、負荷や検証のオプションは [bench/README.md](bench/README.md) を参照してください。

## 初期データ

初期データの生成には Go が必要です。

```sh
make datagen
```

生成した `webapp/sql/002-seed.sql` は git 管理対象外です。
本番規模のデータ生成と投入方法は [webapp/datagen/README.md](webapp/datagen/README.md) を参照してください。

## docker compose での環境構築

作問時に利用した docker compose で、3地域のアプリケーション、DB、Router を手元に構築できます。
ただし、スペックなどは競技環境と異なります。
地域間の遅延は Router が再現します（既定 100ms）。

### アプリケーションの起動

事前に初期データを生成してから起動します。

```sh
go -C webapp/datagen run .
docker compose up -d --build --wait
```

初期実装は既定で Go です。
`ISUREAL_WEBAPP_LANGUAGE` で他の言語に切り替えられます。

```sh
ISUREAL_WEBAPP_LANGUAGE=ruby docker compose up -d --build --wait
```

停止するときは `docker compose down`、DB を初期状態に戻すときは `docker compose down -v` を実行します。
詳細は [deploy/dev/README.md](deploy/dev/README.md) を参照してください。

### 負荷走行の実行

ベンチマーカーは既定で `http://app.127.0.0.1.nip.io:18090` を対象にします。

```sh
go -C bench run .
```

## 運営向けの資料

ポータル、Supervisor など大会運営のためのインフラについては [docs/for-committee](docs/for-committee/README.md) を参照してください。

## Links

- [ISUCON2026 まとめ](https://isucon.net/archives/60124520.html)
- 講評・講評: TBD

## License

[MIT License](LICENSE)
