# WebSocket実装(1857fa3)の評価レポート

所属: [Std拡張WebSocket開発](./README.md)。初期実装の評価とその後の追補。
現在の合意・進捗は開発トラックの入口を参照。

対象コミット: `1857fa30de8320914238cdf1e9667afcf0afeaa9`
「feat(websocket): implement WebSocket support with RFC 6455 compliance」

評価日: 2026-11-02
検証方法: 全追加ファイル(約2,400行)の精読、`lake test` の実行、
Python統合テスト `tests/test_ws_std.py`(24件)の実行。いずれもパスを確認。

## 評価軸と総合判定

| 軸 | 評価 | 要約 |
|---|---|---|
| 有用性 | ★★★★★ | 同一ポートでのHTTP/WS共存を汎用的なupgrade APIとして実現。既存ハンドラと後方互換 |
| 安全性(プロトコル) | ★★★★☆ | RFC 6455の検証がフレーム層で網羅的。DoS耐性も設計済み |
| 安全性(運用デフォルト) | ★★★☆☆ | Originチェックがデフォルト全許可、WS層のアイドルタイムアウトなし |
| 正当性 | ★★★★☆ | 統合テスト24件パス。close reason切り詰めに軽微なバグあり |
| 性能 | ★★★☆☆ | バイト単位の`push`ループが多く大ペイロードで非効率(正しさ優先の実装) |
| 保守性 | ★★★☆☆ | 層分離は模範的だが、Std内部ループのフォークという構造的リスク |

## 有用性 — 高い

- **アーキテクチャが本質的に優れている**。既存の `ws-lean`(別ポート必須)と異なり、
  `StdExt/Http/Server/Upgrade.lean` は Warp の `responseRaw` / hyper の `OnUpgrade` /
  Cowboy の所有権モデルを明示的に参照した汎用「コネクション手渡し」プリミティブで、
  WebSocket専用ではなく任意のプロトコルスイッチに使える。
- **後方互換**: `instance [Handler σ] : UpgradableHandler σ` により既存ハンドラが
  無変更で動く。
- **preread問題を構造で解決**: HTTPパーサが先読みしたバイトを `Upgraded.recv` が
  最初に再生するため、「101境界をまたぐバイト欠落」が呼び出し側の規律でなく構造で
  防がれる。`test_preread_bytes_survive_handoff` で実証済み。
- API階層(sans-I/Oフレーム層 → メッセージ層 → ハンドシェイク層)はaxum等の
  実績ある設計を踏襲しており、単体テスト可能性が高い。

## 安全性 — プロトコル面は堅牢、運用デフォルトに注意点

### 良い点

- **マスク方向の強制**(`Frame.decode?` の `requireMask`): クライアント→サーバの
  非マスクフレームを1002で拒否。プロキシキャッシュ汚染攻撃への必須防御。
- **DoS耐性**: `payloadTooLarge` はヘッダ解析時点(ペイロード受信**前**)に判定される
  ため、宣言サイズ攻撃でメモリを食わせられない。断片化メッセージも
  `Config.maxMessageBytes`(既定1MB)で組み立て時に制限。受信バッファの成長も有界。
- **非最小長エンコードの拒否**、予約ビット・予約opcode・断片化制御フレーム・
  不正closeコードの検証がすべてフレーム層に集約。
- **ソケットの抽象化**: 継続(continuation)に生ソケットや直接の解放操作を公開しない
  設計は有用。ただし、これだけでは寿命管理を保証しない。標準TCPの `Transport.close`
  はno-opで、継続から派生した独立タスクも追跡しないため、即時切断・待機解除・
  リーク不在という当初の断定を撤回する。下記の寿命管理設計を参照。
- **自作SHA-1**は RFC 6455 §1.3 が強制するハンドシェイク専用で、秘匿性を要さない
  ため問題なし(ドキュメントにもその旨明記)。依存を増やさない判断は妥当。

### 懸念点

1. 🟡 **Originチェックのデフォルトが全許可**(`UpgradeOptions.checkOrigin`)。
   アプリが `checkOrigin` を設定し忘れるとCSWSH(クロスサイトWebSocketハイジャック)に
   無防備。フックとテスト(`test_foreign_origin_rejected`)はあるが、
   secure-by-defaultではない。
2. 🟡 **WS層にアイドルタイムアウトや自動ping送信がない**。死んだピアがコネクション
   (とサーバの接続パーミット)を永久に保持しうる。アプリ側で `ping` を回す必要が
   あるが、その旨の明示がdocsに薄い。
3. ⚪ `Sec-WebSocket-Key` は長さ24のみ検証(Base64妥当性・`==`終端は未検証)。
   RFC上デコード不要なので実害なし。

## 正当性 — 高いが、バグを1件発見

テストは優秀。正常系だけでなく、非マスク→1002、不正UTF-8→1007、過大制御フレーム、
断片間の制御フレーム割り込み、keep-aliveリクエスト後のアップグレード、拒否後の
HTTP接続継続性、突然切断まで24ケースをPython標準ライブラリ製の独立クライアントで
検証しており、実装と検証器が別物という点で信頼できる。

発見した問題:

1. 🟡 **close reason切り詰めのUTF-8境界バグ**(`WebSocket.Connection` の
   `closeFrame`)。外側ループが末尾1バイトを落とし、内側ループが**継続バイトのみ**を
   剥がすため、剥がした結果がちょうど123バイト以下になると**リードバイト
   (例: `0xC3`)がぶら下がったまま残る**。例: 124バイト目が2バイト文字の後半の
   場合、継続バイトだけ除去されて123バイトで停止し、不正UTF-8のclose reasonを
   送信する。厳格なピアは1007で接続を落とす。発生条件は「123バイト超の
   マルチバイト文字入りreason」なので実害は限定的だが、修正推奨。
   **評価後の対応**: 123バイト位置の最初の除外バイトが継続バイトなら、その文字の
   先頭まで切断位置を戻す方式に修正した。これにより不完全な文字を送信せず、
   境界に収まる完全な文字も保持する。公開API `WebSocket.close` が送信したフレームを
   モックトランスポート経由で検査する回帰テストを追加した。空文字列、ASCII、
   2・3・4バイト文字について、123バイト境界の前後、長いreason、UTF-8妥当性、
   closeコードの保持、125バイト制限、closeの冪等性を検証する。
   当初は共有環境のメモリ上限により検証を中断したが、2026-11-02にメモリを増やした
   環境で再検証した。追加テストで予約語 `prefix` を変数名に使っていた点を修正し、
   `lake test`（UTF-8境界の回帰テストを含む）、`lake build leanwebstudy`、
   `python3 -m unittest tests.test_ws_std -v`（24件）がすべて成功した。
2. **close後のデータフレーム競合と寿命管理の保証不足（要設計・未修正）**:
   `sendDataFrame` の `closeSent` チェックと
   送信が非アトミックなため、並行する `close` との競合でcloseフレーム**後**に
   データフレームが出る窓がある(`sendCloseOnce` 自体は `modifyGet` でアトミック)。
   RFC違反に加え、終了と操作権の失効をどう同期するかが未整理である。
   「ピアが無視するだけで無害」という当初の評価を撤回する。メモリ破壊や不正読み出しは
   未確認であり、発生すると断定もしない。送信順序、タスク・接続の終了、
   native資源の生存を別々に検証する必要がある。
   問題定義、証明対象、対応方針を
   [WebSocketの終了・寿命管理設計](websocket-lifetime-design.md)にまとめた。
   [依存先契約と証明の前提調査](websocket-dependency-contracts.md)では対応版のnativeソースと
   libuv契約を確認し、寿命保持の実装根拠と、強制終了・進行性の不足を分けて記録した。
3. ⚪ UTF-8検証がメッセージ完成時のみ(インクリメンタルでない)。RFC準拠だが、
   Autobahnの厳格なfail-fastケース(6.x系)では「可能な限り早く失敗」が期待される。

## 性能 — 正しさ優先、最適化余地あり

- `Frame.applyMask`・SHA-1・Base64がすべてバイト単位の `push` ループ。Leanの
  `ByteArray.push` は償却O(1)だが、1MBペイロードのXORをワード単位化すれば大幅に
  速くなる。ハンドシェイク(60バイト弱のSHA-1)は無視できる。
- 受信は `buffer ++ bytes` と `extract` でコピーが多い。スループット重視の用途では
  リングバッファ化の余地。
- 送信は「1フレーム=1回のトランスポート書き込み」でインターリーブを防ぐ設計。
  正しさとのトレードオフとして妥当。

## 保守性 — 層設計は模範的、フォークが構造的リスク

- **最大のリスク**: `StdExt/Http/Server/Connection.lean` は
  `Std.Http.Server.Connection` のループ全体(600行超)のコピーであり、Stdの更新の
  たびに手動で差分追従が必要。ファイル冒頭で「パッチとして読めるよう意図的に同一」と
  明記し自覚的だが、upstream追従コストは残る。`Serve.lean` も `Server.new`、
  `activeConnections` などStdの内部に依存しており、Stdの非公開化一つで壊れる。
  本質的には**標準ライブラリへの提案PR**であり、docsもそう位置づけている —
  その文脈では妥当な構成。
- フレーム層がsans-I/Oで純粋関数(`decode?` / `encode`)、ハンドシェイク検証
  `checkHandshake` も純粋、という分離は単体テスト・将来のクライアント実装流用の
  両面で模範的。
- docstringの質が高い(各判断にRFC条番号と先行実装の参照付き)。

## 推奨アクション(優先度順)

1. **対応済み**: `closeFrame` のUTF-8境界バグ修正と、123バイト超の
   マルチバイトreasonを含む回帰テスト追加
2. `UpgradeOptions.checkOrigin` のデフォルト全許可について、
   下記「Originポリシーの選択肢とトレードオフ」を踏まえて方針を選ぶ。
   調査と利用ガイドへの警告追加は実施済み。APIの既定値変更は未実施。
3. WS層のアイドルタイムアウト(または定期ping)オプションの追加
4. 余力があれば Autobahn Testsuite での準拠検証と `applyMask` のワード単位化

## Originポリシーの選択肢とトレードオフ

2026-11-02 調査。以下は設計判断のための比較であり、実装変更ではない。

### 現状と防御の範囲

- [WebSocket.lean](../../StdExt/Http/WebSocket.lean) の `UpgradeOptions.checkOrigin` と、
  直接呼び出せる `checkHandshake` の省略時引数は、どちらも `fun _ => true`。
  コールバックが受け取るのは `Option String` だけで、HostやTLS情報ではない。
  拒否すると101に切り替える前に403を返す。
- 一方、[デモの `WebHandler.wsEchoOrigin`](../../LeanWebStudy.lean) は明示設定済みで、
  `http://127.0.0.1:<httpPort>` と `http://localhost:<httpPort>` のみを許可する。
  Origin欠落は許可し、文字列 `"null"` や外部Originは拒否する。
  **ライブラリ既定値の問題と、デモの現在の挙動は区別する必要がある。**
- ブラウザのWebSocket接続は通常のCORSプリフライトによる許可を必要としない。
  Cookie等の暗黙の認証情報が送られる構成でOriginを制限しないと、攻撃者のページから
  認証済み接続を開かれるCSWSHのリスクがある。CookieのSameSite属性は補助策だが、
  same-siteとsame-originは異なるため、Origin検証の代用にはならない。[1][3]
- Originはブラウザ上のスクリプトを制限するための情報であり、クライアント認証ではない。
  非ブラウザクライアントは偽装・省略できる。認証、メッセージ単位の認可、
  接続上限、TLSは別途必要。RFC 6455 §10.2もこの境界を明記する。[1]

### 基本方針の比較

Origin欠落を許可するかは、下記の基本方針とは別に決定する。

| 選択肢 | 利点 | 欠点・トレードオフ | 現行APIでの実現 |
|---|---|---|---|
| A. 全許可を維持し、警告・例を追加 | 後方互換。公開データ配信や多様な非ブラウザクライアントに使いやすい | 設定忘れを防げない。Cookie認証等を後付けした際にも危険を引き継ぐ | 変更不要 |
| B. ポリシー指定を必須にする | 利用者に信頼境界の判断を必ず要求できる。全許可も明示的な選択になる | ソース互換性を壊す。明示的に全許可を選んだ場合の安全性までは保証しない | `UpgradeOptions` と `checkHandshake` の既定値をともに見直す必要あり |
| C. 未設定は全拒否、allowlistを設定して開放 | fail-closed。誤設定で公開するより停止を選べる。scheme・host・portを限定できる | 初回設定が必須。CLI等も欠落許可を設定しない限り拒否。環境ごとの設定管理が必要 | 全拒否や固定allowlist自体は現行コールバックで可能。既定値変更は破壊的 |
| D. same-originを既定にする | 同一サイト構成で設定忘れを減らせる | 別ドメインのフロントエンドやプロキシ構成に例外が必要。外部scheme・host・portの信頼できる取得が難しい | 外部Originを設定値として閉じ込めれば可能。リクエストから自動導出するにはAPI拡張が必要 |
| E. ホスト単位・サブドメイン単位の許可 | 多数のテナントやプレビュー環境をまとめて扱いやすい | 別scheme・portや、管理外・乗っ取られたサブドメインまで信頼しやすい。完全なsame-originより広い | コールバックで可能だが、構文解析とホスト境界の厳密な判定が必要 |

allowlistはBやCと組み合わせる代表的な実装方法。まずは設定済みの完全なOriginへの
一致を優先し、部分文字列一致や無制限のワイルドカードは避ける。[3]

### Origin欠落・`null`・不正値

| 入力 | 許可する理由 | 拒否する理由・推奨する扱い |
|---|---|---|
| Originヘッダなし (`none`) | CLI・サーバー間接続との互換性。RFCは非ブラウザ接続を排除する目的ではない | ブラウザ専用なら拒否が明快。許可しても「信頼済みクライアント」の証明ではなく、別の認証が必要 |
| `Origin: null` (`some "null"`) | opaque originの文脈（例: 一部のsandbox）への対応が必要な場合 | 欠落とは別物。複数の信頼できない文脈が同じ値になるため、原則拒否し、必要なら限定用途として明示設計する |
| 不正構文・複数Origin・重複ヘッダ | 正常なブラウザ利用で受け入れる利点はない | 拒否する。自動選択・部分一致で許可しない。重複ヘッダの扱いはHTTPヘッダ層も含めて検証が必要 |

Originの通常形は `scheme://host[:port]` であり、パスを含まない。`wss://` の接続を
開始したページのOriginは通常 `https://` である。比較にはscheme・host・実効portを
使い、既定port、省略形、ホストの大文字小文字、IPv6、国際化ドメインの扱いを決める。
固定allowlistでシリアライズ済みの値を完全一致させる方法は単純で保守的だが、
同値な別表記を拒否する場合がある。URL解析を導入する場合も、不正値を緩く補正して
許可しない。[2]

### TLS終端・リバースプロキシ・Codespaces

- 外部の `https://app.example` が内部の `http://localhost:8080` に転送される場合、
  内部アドレスからのsame-origin推定では正当な接続を拒否してしまう。
  固定された**外部Originのallowlist**なら、TLS情報を追加取得せず現行APIで扱える。
- `Host` だけとの一致はschemeまで確認するsame-originとは異なる。
  Hostを利用するなら許可ホストの検証も必要で、任意の受信Hostを信頼基点にしない。
  `Forwarded` / `X-Forwarded-Host` / `X-Forwarded-Proto` を使う場合は、
  信頼するプロキシを限定し、外部からの偽装ヘッダを境界で除去する。
- Codespacesの転送先はローカルのOriginとは異なる。現在のデモの固定ローカルOrigin
  ポリシーでは、転送URL上のページからの接続は許可されない。対応するなら、その環境の
  **具体的な外部Origin**を設定に追加する。共有プレビュー用ドメイン全体の許可は、
  他の利用者のページまで信頼することになるので避ける。

### 先行実装から得られる示唆

| 実装・ガイド | 確認できた方針 | このAPIへの示唆 |
|---|---|---|
| Gorilla WebSocket `Upgrader` | `CheckOrigin` 未設定時、Originが存在し、そのhostがリクエストHostと異なると拒否。欠落は許可 [4] | 安全寄りの既定値と非ブラウザ互換性を両立。ただし完全なscheme込みsame-originと呼ばない |
| Python `websockets` | `serve` の `origins` 既定値は `None`。Originの制限は明示設定でき、allowlist要素の `None` で欠落許可を指定する [5] | ポリシー本体と「Origin欠落許可」を分離すると意図を表現しやすい |
| Django Channels | `OriginValidator` による許可集合、`AllowedHostsOriginValidator` による既存の `ALLOWED_HOSTS` 設定の再利用 [6] | アプリの信頼する公開ホスト設定を一元化できる。ただしmiddlewareの明示的な組み込みが必要 |
| OWASP | 全ハンドシェイクで明示的なOrigin allowlistによる検証を推奨 [3] | Cookie認証を伴うアプリの標準的な選択肢としてallowlistを優先する |

### 本リポジトリへの推奨と変更時の確認項目

1. **互換性を維持する段階**ではAとして全許可の警告を明記し、デモの明示的ポリシーは
   維持する。外部公開時は完全な外部Originのallowlistを設定する。
2. **アプリ向けの安全な入口ではB（ポリシー必須化）が候補**。汎用ライブラリには
   公開OriginやTLS終端の知識がなく、呼び出し側に判断を要求する利点がある。
   ただし、これを低レベルAPIまで一律に適用するのがLeanや他言語の標準的な方針と
   確認できたわけではない。下記の外部比較を踏まえ、基盤層とアプリ向け入口を分けて
   判断する。空の設定で安全側に停止させる設計ならCも候補となる。
3. Cookie認証を使うブラウザ専用アプリはallowlist外・欠落・`null`を拒否する。
   CLI混在なら欠落許可を独立に選び、別の認証を必須にする。全許可を選ぶ用途でも、
   ローカルネットワークへの到達性や副作用を含めて公開してよいか確認する。
4. 実装時は `UpgradeOptions` と `checkHandshake` の両経路、デモ、利用例、
   拒否時403と接続継続、移行ガイドをそろえる。既定値変更は意図的な互換性変更として扱う。
5. テストには許可Origin、外部Origin、scheme/port違い、欠落、`null`、不正値・重複、
   既定port・IPv6等の採用した比較規則、信頼するプロキシ経由と転送ヘッダ偽装を含める。
   現在の外部Origin拒否・ローカルOrigin許可テストだけでは、新しい方針全体の検証には足りない。

### 参照資料

すべて2026-11-02参照。先行実装の記述は参照時点の公開ドキュメントに基づく。

1. [RFC 6455 §10.2: Origin Considerations](https://www.rfc-editor.org/rfc/rfc6455.html#section-10.2)
2. [RFC 6454 §6.2: ASCII Serialization of an Origin](https://www.rfc-editor.org/rfc/rfc6454.html#section-6.2)
3. [OWASP WebSocket Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html)
4. [Gorilla WebSocket: Origin Considerations](https://pkg.go.dev/github.com/gorilla/websocket#hdr-Origin_Considerations)
5. [Python websockets: Server (asyncio)](https://websockets.readthedocs.io/en/stable/reference/asyncio/server.html)
6. [Django Channels: Security](https://channels.readthedocs.io/en/latest/topics/security.html)

## 外部視点: Lean 4の設計スタイルと他言語のライブラリ

### 調査範囲と事実・提案の区別

2026-11-02追記。上の比較は、この実装を安全に運用するための内向きの判断だった。
ここでは「どの層のライブラリとして自然か」「upstreamへの提案として何を説明するか」
を別の評価軸とする。

Leanについては本プロジェクトのツールチェーン **Lean 4.35.0の `Std.Http` 実装**と
公式の貢献ガイドを参照する。他言語は公式ドキュメントと公開ソースを参照する。
以下のLeanへの適合性や採用案は、それらからの**本レポートの推論**であり、
Lean開発者の承認済み方針やWebSocketの公式ロードマップを示すものではない。
また、他言語の既定値の紹介はその安全性を無条件に推奨するものではない。

### Lean 4 / Std.Httpから読み取れる方向性

| 観点 | 既存実装で確認できる事実 | 今回のWebSocket APIへの含意 |
|---|---|---|
| 不変条件を型に持たせる | `Header.Name` は文字列の妥当性と小文字化の証明、`Header.Value` はヘッダ値の妥当性の証明を持つ。動的入力は `ofString?` で検証して構築する [L1][L2] | Origin構文と「アプリが信頼するOriginか」は別問題。将来は検証済みOrigin型が自然な候補だが、その型だけで信頼性を保証したとは言えない |
| 型と実行時検証の併用 | `Config.keepAliveTimeout` は正値の部分型。他のサイズ上限は `Nat` と既定値で表す [L3] | Leanだからすべてを証明付きにする必要はない。受信フレームの実行時検証や、ポリシーを関数で渡す現在の方式も整合的 |
| アプリの判断は必須コールバックで渡す | `Handler.onRequest` は必須。`onContinue` は既定で許可、`onFailure` は既定で何もしない。`StatelessHandler` と `Handler.ofFn` が簡便な入口を提供する [L4] | 必須引数も許可的な既定値も先例がある。「LeanのスタイルだからOrigin全拒否／必須化」とは結論できない |
| 資源防御は基盤にも置く | `Config` は接続数1024、ヘッダ受信5秒、ヘッダ64KiB等の上限を既定で持ち、無制限化には警告がある [L3] | プロトコル上限をライブラリで守る現在の設計は合う。ただし一律に決められる資源制限から、配備先依存のOrigin allowlistは導出できない |
| 設定構造体と層間変換 | サーバーの `Config.toH1Config` はHTTP処理層の設定へ変換する [L3] | `Upgraded`、フレーム、メッセージ、WebSocket upgradeの層分離は方向性に合う。配備先のHost/TLS/認証情報をフレーム層へ流し込む理由はない |
| upstreamの判断基準 | 貢献ガイドは機能提案をRFC issueから始め、利用者・保守性・UXを説明し、既存機能の再利用、テスト、ドキュメント、性能を求める [L5] | 「他言語にある」「Leanで書いた」だけでは採用根拠にならない。汎用upgrade primitiveとWebSocketの提案範囲、ループ複製を解消する変更面を説明すべき |

この意味で、今回のsans-I/O層と純粋な `checkHandshake` はLeanの利点を活かす構成である。
一方、`Option String → Bool` は欠落を区別できるが、構文解析と許可判断を利用者が
混在させやすい。まず再利用可能な純粋な検証関数・allowlist helperで重複を減らし、
必要性が確認できてからOrigin型を検討する順序がよい。
「ブラウザが正しいOriginを送った」「プロキシ設定が信頼できる」といった環境上の仮定は、
文字列やフレーム処理を証明するだけでは保証されない。

### 他言語ではどこがOriginポリシーを持つか

| 言語・ライブラリ | 位置づけとOriginの方針 | この実装との比較 |
|---|---|---|
| Go / Gorilla WebSocket | HTTPからupgradeするライブラリ。`Upgrader.CheckOrigin` 未設定時は、OriginがあればそのhostとHostを比較して拒否判定。欠落を許可する [4] | 汎用ライブラリにもブラウザ向けの保護を既定化する先例。ただしschemeを含む完全なsame-originとは異なる |
| Python / `websockets` | プロトコルとサーバーAPIを提供。`origins=None` が既定で、許可集合を明示設定できる。集合内の `None` はOrigin欠落の許可を表す [5] | 全許可を既定にしつつポリシーを標準オプションとして提供する先例。現在のAPIに近い |
| JavaScript / Node.js `ws` | 低レベルのHTTP upgrade統合。`verifyClient` 未設定なら、その検査による拒否をしない。公式資料は `verifyClient` よりHTTPサーバーの `upgrade` イベントで認証する方法を推奨する [E1] | RFCのハンドシェイク検証とアプリ側の受け入れ判断を分離する。Originもupgrade前のアプリ検査に置けるが、組み込み忘れは防げない |
| Rust / tungstenite | 低レベルのハンドシェイク・フレーム処理。通常の経路の `NoCallback` は応答をそのまま許可し、`Callback.on_request` でヘッダ検査・拒否を追加できる [E2] | プロトコル適合性の検査とOrigin認可を分離する先例。安全性の契約を利用者に明示する必要がある |
| Rust / axum | HTTP extractorの `WebSocketUpgrade` でupgradeを構成。確認した `FromRequestParts` はメソッド・upgradeヘッダ等を検査するが、Originの許可判定はしない [E3] | フレームワークでもOriginを自動制限するとは限らない。ハンドラー等でupgrade前に検査する構成が必要 |
| Java / Spring Framework | WebSocketの登録・設定APIではsame-originのみ許可が既定。明示的なOrigin集合や全許可にも切替可能 [E4] | アプリ向け統合層で安全寄りの既定値を提供する先例。既存のHTTP・配備設定と合わせて扱える |
| Python / Django Channels | `OriginValidator` / `AllowedHostsOriginValidator` を明示的に組み込む。後者はアプリの `ALLOWED_HOSTS` を再利用する [6] | 安全なポリシーの部品をフレームワーク側で提供し、アプリが組み合わせる先例。「フレームワークなら自動で安全」とも言えない |

**結論: 「他言語の標準は全許可」「フレームワークはすべてsame-origin」のどちらでもない。**
責務の切り方は一つではなく、同じ汎用upgradeライブラリでもGorillaと `ws` は異なる。
これらの比較で重要なのは、多数決ではなく、利用者がどの設定を既に持ち、
どこでポリシーを確実に適用できるかである。

### Origin以外にも適用できる設計上の評価

- **純粋なプロトコル核とHTTP統合を分ける**: 現在のフレーム層・`Upgraded`・
  `WebSocket.upgrade` の分離は、tungsteniteのプロトコル核とaxumのHTTP統合の
  関係と比較できる。TLS終端やCookie認証までフレーム層に抱え込む必要はない。
- **安全な型と安全な配備を混同しない**: Rustの型安全なAPIもOrigin検証を自動では
  保証しない。Leanの証明付きヘッダ型も同じで、アプリの信頼境界は別途指定する。
- **機構と便利な入口は両立できる**: Stdの `Handler` / `StatelessHandler` と同様、
  小さな基盤APIを保ちながら、アプリ向けhelperで設定の省略を防ぐ構成は可能。
  ただし二つの入口でRFC検証を複製せず、共通の検証処理を呼ぶべきである。
- **保守性は型の選択だけでは解決しない**: サーバーループの600行超の複製は、
  ポリシー型を改善しても残る。upstream化での優先課題はupgrade境界を既存ループへ
  統合し、標準HTTP処理への追従を一本化することである。

### 外部比較を踏まえた推奨の補正

先のB推奨を、**「すべての層でコールバックを必須にすべき」から
「基盤の責務を保ち、アプリ向け入口で明示的な選択を促す」へ限定する**。

| 対象の層 | 推奨する責務 | 今回の判断 |
|---|---|---|
| フレーム・メッセージ層 | RFC検証、サイズ上限、制御フレーム処理 | Origin・Host・認証を持ち込まない |
| 汎用upgrade / ハンドシェイク層 | バイトの移譲、RFCハンドシェイク検証、呼び出し側が与えたポリシーの適用 | 現行の互換性を直ちに壊す根拠は不足。全許可を明記し、明示設定を容易にする |
| ブラウザアプリ向けの入口・利用例 | 外部Originのallowlistと欠落時の方針を決め、認証と組み合わせる | Bによる設定必須化、または明示的なallowlist helperが有力。same-origin自動推定は信頼できる外部URL情報がある場合のみ |
| upstreamへの提案 | APIの配置、機構とポリシーの境界、互換性、利用者の設定負担を合意する | 全許可を変える前にRFCで相談。ここでの推奨をLeanの公式方針として扱わない |

型付きの `OriginPolicy`（全許可・許可集合・独自関数等）は選択を可視化できるが、
それ自体が安全性の証明ではなく、新しい公開型の保守コストもある。
まず現行コールバックと共通helperで十分かを確認し、ブラウザ向けの安全な入口が
実際に必要になった時点で最小限のAPI変更を選ぶ。今回はいずれの実装変更も行わない。

### この節の追加資料

Leanの実装はバージョンを固定し、公式貢献ガイドと他言語の `main` / `latest` 資料は
2026-11-02参照時点のものとして区別する。

- [L1] [Lean 4.35.0: Std.Http.Header.Name](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Data/Headers/Name.lean)
- [L2] [Lean 4.35.0: Std.Http.Header.Value](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Data/Headers/Value.lean)
- [L3] [Lean 4.35.0: Std.Http.Config](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Config.lean)
- [L4] [Lean 4.35.0: Std.Http.Server.Handler](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Handler.lean)
- [L5] [Lean 4: External Contribution Guidelines](https://github.com/leanprover/lean4/blob/master/CONTRIBUTING.md)
- [E1] [Node.js ws: WebSocketServer options / verifyClient](https://github.com/websockets/ws/blob/master/doc/ws.md#new-websocketserveroptions-callback)
- [E2] [tungstenite: server handshake / NoCallback](https://github.com/snapview/tungstenite-rs/blob/master/src/handshake/server.rs) /
  [Callback API](https://docs.rs/tungstenite/latest/tungstenite/handshake/server/trait.Callback.html)
- [E3] [axum: WebSocketUpgrade / FromRequestParts](https://github.com/tokio-rs/axum/blob/main/axum/src/extract/ws.rs) /
  [WebSocket API](https://docs.rs/axum/latest/axum/extract/ws/index.html)
- [E4] [Spring Framework: Allowed Origins](https://docs.spring.io/spring-framework/reference/web/websocket/server.html#websocket-server-allowed-origins) /
  [該当ドキュメントのソース](https://github.com/spring-projects/spring-framework/blob/main/framework-docs/modules/ROOT/pages/web/websocket/server.adoc)

## 総評

標準ライブラリ拡張提案として設計品質・テスト品質ともに高水準で、プロトコル安全性の
要所(マスク強制、サイズ制限の事前判定、ソケット所有権)を押さえた実用に足る実装。
残る懸念は「デフォルト設定の安全性(Origin・タイムアウト)」と「Stdフォークの
追従コスト」に集約される。
