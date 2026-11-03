# StdExt: `Std.Http.Server` 接続移譲 API と WebSocket 実装

所属: [Std拡張WebSocket開発](./README.md)。現行APIの説明であり、
寿命管理の純粋モデルが実通信経路へ組み込まれたことは意味しない。

2026-11-02 作成。[websocket-risk-return-report.md](https://github.com/bgnori/LeanWebStudy/blob/main/docs/application-study/websocket-risk-return-report.md)
の提案 6.1-1(`Std.Http.Server` の Upgrade / 接続移譲 API)と付録 A.5 の適用案を、
本リポジトリ内の拡張ライブラリー `StdExt` として実装したもの。これにより
WebSocket を **HTTP と同一ポート** で提供でき、レポートが固定費として挙げた
別リスナー・ポート発見・開発トンネル・二重 Origin 検証が不要になる。
動作実証は `/ws-echo/socket`(エコーエンドポイント)と
[tests/test_ws_std.py](../tests/test_ws_std.py) にある。

## 1. 配置と名前空間のポリシー

Lean 4.35.0 の `Std` はツールチェーンに同梱されており直接編集できないため、
拡張は Lake ライブラリー `StdExt` として置く。**モジュール名のみ** `StdExt`
接頭辞を持ち、**名前空間は拡張先の `Std.Http.*` をそのまま使う**。upstream へ
提案時の名前空間移行を小さくする狙いである。ただし独立化・本家への提案には、
接続終了契約・互換性・接続ループの共通化等の検討が別途必要で、
ファイル名の変更だけでupstream化が完了するわけではない。

| モジュール | 内容 | 名前空間 |
| --- | --- | --- |
| `StdExt.Http.Server.Upgrade` | `Upgraded` ストリーム、`UpgradableResponse`、`UpgradableHandler` | `Std.Http.Server` |
| `StdExt.Http.Server.Connection` | upgrade 終端状態を追加した接続ループ(`serveUpgradableConnection`) | `Std.Http.Server` |
| `StdExt.Http.Server.Serve` | `serveUpgradable`(`serve` と同形の accept ループ) | `Std.Http.Server` |
| `StdExt.Http.WebSocket.Crypto` | ハンドシェイク用 SHA-1 / Base64 | `Std.Http.WebSocket.Internal` |
| `StdExt.Http.WebSocket.Frame` | RFC 6455 フレーム層(sans-I/O) | `Std.Http.WebSocket` |
| `StdExt.Http.WebSocket.Connection` | メッセージレベル API(`WebSocket`) | `Std.Http.WebSocket` |
| `StdExt.Http.WebSocket` | ハンドシェイク検証と `WebSocket.upgrade` | `Std.Http.WebSocket` |

接続ループ(`StdExt.Http.Server.Connection`)は Std の
`Std/Http/Server/Connection.lean` の private 実装を複製した上で終端状態を
一つ追加した「パッチとして読める」構成になっている。複製が必要なのは
Std 側のループ補助関数がすべて private なためで、upstream 化の際は差分のみが残る。

## 2. 移譲 API の設計(レポート付録 A.5 の実装)

レポートの結論どおり、**A.3(Warp `responseRaw`)を骨格に A.2(hyper)の
時系列規約を組み合わせ、後始末は Cowboy 型でサーバー側に残す**。

### 2.1 ハンドラー結果の和型(Warp 型)

```lean
inductive UpgradableResponse (β : Type) where
  | normal (response : Response β)
  | upgrade (head : Response.Head) (fallback : Response β)
      (continuation : Upgraded → Async Unit)
```

`Handler : Request → ContextAsync Response` の抽象を壊さず、結果型に移譲
コンストラクタを一つ足す。Warp と同じく **フォールバック Response を同時に
要求する**:切替を履行できない場合(HTTP/1.0、1xx でない head、ボディ未消費、
応答コミット済み)はサーバーが `fallback` を通常応答として送る。

`UpgradableHandler` は `Handler` と同形のクラスで、既存の `Handler` インスタンスは
低優先度のブランケットインスタンスにより「決して upgrade しない
`UpgradableHandler`」として無改修で `serveUpgradable` に渡せる。

### 2.2 101 送信と先読みバイト(hyper 型)

- 101 の書き込みは **サーバーが行う**。`H1.Machine.send` は 1xx 応答を
  writer の状態を変えずに出力バッファーへ直接エンコードするため、この経路を
  そのまま使い、送信完了後にのみ継続を起動する。「101 前後で両者が同じ
  ソケットを読まない」要件が API の構造で保証される。
- 継続が受け取る `Upgraded` は **ソケットではなく抽象的な双方向バイト
  ストリーム**(`recv` / `send` / `sendAll`)で、HTTP リーダーが先読みした
  未消費バイトを内包する(`recv` が最初に返す)。`Transport` 型は消去される
  ため、継続はトランスポートの実装に依存しない。

先読みの正しさはサーバー側 H1 ステートマシンの性質に依拠する:
受信方向のリーダーはレスポンスが完了するまで次メッセージをパースしない
(`processReaderCompleteState` / `processCompleteStep`)ため、ハンドラーが
応答を決める間にクライアントが先行送信したフレームは未消費のまま
`reader.input` に蓄積される。upgrade 時はその残余をそのまま引き継ぐ。
ハンドシェイクと同一パケットでフレームを送るクライアントの検証は
`test_preread_bytes_survive_handoff` にある。

### 2.3 所有権と後始末(Cowboy 型)

移譲は接続ループの **loop back しない終端状態** として実装した
(`LoopAction.upgrade` → `performUpgrade`)。ソケットの所有権は終始サーバーに
残す設計である。ただし、現在の実装について次の保証上の制約がある:

- 継続の完了・例外はサーバーの接続後始末に接続され、`Transport.close` は
  サーバーが呼び出す(継続に直接のTransport解放操作は公開しない)。
- サーバーのシャットダウン時は、継続をキャンセルコンテキストと race し、
  `Transport.close` を呼び出してから継続の完了を待つ。
  **標準TCPではこの操作はno-opのため、これによる即時切断・待機解除は保証されない。**
- 継続の例外は `UpgradableHandler.onFailure` に通知される。
- 継続から派生した独立タスクは追跡しない。WebSocketや `Upgraded` の参照が
  残る場合の操作権失効と終了完了の契約は未整備であり、継続の完了だけで
  すべての接続利用が終了したとは言えない。

この制約とsend/close競合を、プロトコル順序だけでなく寿命管理の問題として扱う。
[問題定義と証明に向けた設計方針](websocket-lifetime-design.md)に、
単一の接続所有タスク、状態遷移の証明、native境界の検証を含む案を記す。
これは設計案であり、現行実装の保証ではない。

keep-alive 接続の 2 本目以降のリクエストとして Upgrade が来ても機能する
(`test_upgrade_after_keep_alive_request`)。これは別リスナー方式では原理的に
不可能だった性質である。

## 3. WebSocket 層

移譲プリミティブの上に、axum の `WebSocketUpgrade` に相当する
エルゴノミック層を提供する。

```lean
instance : Server.UpgradableHandler MyHandler where
  onRequest self request := do
    if toString request.line.uri.path == "/ws-echo/socket" then
      WebSocket.upgrade request.line echoLoop { checkOrigin := ... }
    else
      .normal <$> Server.Handler.onRequest self request

def echoLoop (socket : WebSocket.WebSocket) : Async Unit := do
  let mut running := true
  while running do
    match ← socket.recv with
    | some (.text content) => socket.sendText content
    | some (.binary content) => socket.sendBinary content
    | none => running := false
```

- **ハンドシェイク**(`checkHandshake`、純粋関数):GET、`Upgrade: websocket`、
  `Connection: upgrade` トークン、`Sec-WebSocket-Version: 13`、キー形式、
  Origin ポリシーを検証し、失敗は 405 / 400 / 426 / 403 の通常応答になる。
  `Sec-WebSocket-Accept` は自前の SHA-1 + Base64(テストベクター付き)で計算する。
- **フレーム層**(`Frame.encode` / `Frame.decode?`、sans-I/O):RSV ビット、
  予約オペコード、マスク方向、制御フレーム制約(断片化禁止・125 バイト上限)、
  最小長エンコード、ペイロード上限を検証する。
- **メッセージ層**(`WebSocket.recv` / `send*` / `ping` / `close`):断片化の
  再構成、Ping への自動 Pong、クローズハンドシェイク(コード検証・エコー)、
  テキストの UTF-8 検証(違反は 1007、上限超過は 1009、その他は 1002 で切断)。
  `recv` は単一タスクで駆動する契約。送信は 1 フレーム = 1 トランスポート
  書き込みのため、並行送信でフレームのバイト列が混ざることはない。

レポート 2.2 で ws-lean 利用時に自前実装が必要だった運用機構のうち、
プロトコル品質(検証・自動応答・クローズ順序)はこの層が持つ。接続上限は
`Std.Http.Config.maxConnections`(HTTP と共有)が適用される。アイドル
タイムアウトと Ping 送出の周期はアプリケーション責務のまま(§5)。

### 3.1 Originポリシーの設定

**注意: `UpgradeOptions.checkOrigin` と `checkHandshake` の省略時引数は全許可。**
Cookie等の暗黙の認証情報を利用するアプリは、ブラウザからのクロスサイト接続を防ぐため、
信頼するページのOriginを明示的に制限する。通常のCORS設定だけでは代替できない。
Origin検証は認証・認可の代わりではなく、非ブラウザクライアントによる偽装も防がない。

現行APIで固定allowlistを適用する例（値は実際の公開URLに置き換える）:

```lean
def trustedOrigin : Option String → Bool
  | some origin => origin == "https://app.example.com"
  | none => false
```

これを `WebSocket.upgrade` の `{ checkOrigin := trustedOrigin }` として渡す。
この例はOrigin欠落も拒否するブラウザ専用の設定。CLI等の欠落を許可する場合は
`none` の扱いを明示的に変え、別途認証する。文字列 `"null"` は欠落とは区別し、
原則として許可しない。

デモはすでに `WebHandler.wsEchoOrigin` を設定し、ローカルのHTTP Origin二つと
Origin欠落だけを許可している。TLS終端やCodespaces転送先で使う場合は、
内部のlocalhostではなく実際の外部Originを設定する。転送ヘッダを無条件に信頼したり、
共有プレビュー用ドメイン全体を許可したりしない。

全許可維持・必須設定・全拒否・same-origin等の選択肢、欠落時の方針、
互換性とプロキシのトレードオフは
[評価レポートのOriginポリシー比較](websocket-evaluation.md#originポリシーの選択肢とトレードオフ)
と[Lean・他言語の設計方針との比較](websocket-evaluation.md#外部視点-lean-4の設計スタイルと他言語のライブラリ)
を参照。低レベルのプロトコル核とアプリ向けの安全な入口は分けて評価し、
ポリシー必須化を全層の前提とはしない。現時点では既定値やAPIの挙動を変更していない。

## 4. テスト

- **Lean 単体テスト**([LeanWebStudyTests.lean](../Tests.lean)):
  SHA-1(FIPS 180-4 ベクター)、Base64(RFC 4648 §10 ベクター)、
  `Sec-WebSocket-Accept`(RFC 6455 §1.3 の実例)、フレームの往復と
  RFC 6455 §5.7 のマスク例、フレーム違反、クローズコード、
  ハンドシェイク検証の全拒否経路。
- **結合テスト**([tests/test_ws_std.py](../tests/test_ws_std.py)、
  標準ライブラリーのみ、24 ケース):同一ポートでのハンドシェイク、
  テキスト・バイナリー(0〜70000 バイト、16/64 ビット拡張長)、断片化、
  断片間の制御フレーム、Ping/Pong、クローズハンドシェイク、先読みバイトの
  移譲、keep-alive 後の upgrade、並行接続、拒否応答(405/400/426/403)、
  プロトコル違反時の 1002/1007 切断、切断後の HTTP 継続稼働。
- **Autobahn 互換性**([tests/test_ws_autobahn.py](../tests/test_ws_autobahn.py)、
  標準ライブラリーのみ、28 ケース・2026-11-03 全通過):
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite) の
  ケースクラス 1〜7・9 の代表的挙動を再実装した準拠スイート。
  長さ境界(0〜64 KiB 超)の echo、Pong の順序と payload 一致、RSV ビット、
  予約 opcode、多数・空断片の再構成、断片越しの UTF-8 検証(1007)、
  有効・無効クローズコードの echo/拒否(1002)、close 後データの無視、
  1 MiB 上限ちょうどの echo と超過時の 1009。
  本家スイートは Docker 専用のため、Docker がある環境向けの実行構成を
  [tools/autobahn/](../tools/autobahn/README.md)に同梱する
  (`bash tests/autobahn.sh`)。除外ケース(1 MiB 超の 9.x、未実装の
  permessage-deflate 12/13)の根拠も同所に記録。

```sh
lake build && lake test
python3 -m unittest tests.test_ws_std
python3 -m unittest discover -s tests -p 'test_ws_autobahn.py'
```

## 5. 制約と今後

- サブプロトコル(`Sec-WebSocket-Protocol`)ネゴシエーションと拡張
  (permessage-deflate)は未実装。前者は `UpgradeOptions` の拡張、後者は
  フレーム層の RSV1 許可が挿入点になる。
- アイドルタイムアウト・サーバー発 Ping の周期運転はアプリケーション責務。
  レポート 6.1-3 の「接続運用プリミティブの標準化」は未着手。
- RFC 6455 の不変条件の定理化(レポート 6.1-4)は行っていない。フレーム層が
  sans-I/O の純粋関数なので、`#guard` ベースの検証から定理への移行は可能。
- 開発プレビュー(`tools/dev.py`)のトンネルは従来どおり別ポートのチャット用。
  `/ws-echo/socket` は HTTP と同一ポートのため、通常のポート転送だけで届く。
- `H2`/RFC 8441(extended CONNECT)は対象外だが、`Upgraded` が「先読みを内包
  した抽象ストリーム」であり生ソケットを約束しないため、API 形状は
  トランスポートの進化に耐える(レポート A.6 の指摘に沿う)。
