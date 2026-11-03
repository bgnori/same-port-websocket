# WebSocketの依存先契約と証明の前提

所属: [Std拡張WebSocket開発](./README.md)。依存先の調査根拠・外部仮定の台帳。

2026-11-02調査。[終了・寿命管理の設計案](websocket-lifetime-design.md)の前提調査。
対象は `StdExt → Std.Http.Transport → Std.Async.TCP → Lean native runtime → libuv`
のTCP経路。プロジェクトの全依存ライブラリを網羅した監査ではない。
実装変更・形式証明・sanitizerによる検証は行っていない。

## 1. 結論

「依存先に期待する性質」は、まず**契約（contract）、仕様（specification）、
前提条件／事後条件（precondition / postcondition）**と呼ぶのが適切である。
証明では、**環境仮定（environment assumptions）と保証（guarantees）**として
記述し、実装がその仕様を満たすことを**適合性／精緻化（conformance / refinement）**
の問題として扱う。「期待する」と「実際に満たす」の間を埋める根拠が必要である。

今回確認できた重要な点:

- native送信はsocketと送信配列を完了コールバックまで保持する処理を持つ。
  寿命保持について、前回の「nativeソース未確認」から一段根拠が進んだ。
  ただしランタイム全体のメモリ安全性を証明したわけではない。
- libuvの内部状態を守る同期と、WebSocketのsend/closeを順序付ける同期は別。
  前者の仕組みがあっても、後者の競合は残る。
- `Transport.close` は標準TCPではno-op。`Client.shutdown` も書き込み側の半閉鎖で、
  pending writeの完了を待つ。受信解除・即時解放・有界時間内の終了と同一ではない。
- タイムアウト、待機の打切り、キャンセル要求、native処理の完了、資源解放を
  区別しないモデルでは、正しい証明をしても実際の処理に対応しないおそれがある。
- したがって、**データ送信順序の安全性は進められるが、強制終了・資源解放まで含む
  無条件の保証を、現在のTransport契約から導くことはできない。**

## 2. この問題を表す一般的な用語

| 用語 | 意味と今回の使い方 |
|---|---|
| Contract / specification | 呼び出し側と提供側の責任を記述する契約／仕様。型シグネチャだけでは、非同期の寿命・順序・中断意味論までは表せない |
| Preconditions / postconditions / invariants | 操作前に満たす条件、完了後に成立する条件、全到達状態で保つ不変条件。「recvを重ねない」「完了までバッファを保持する」等 [T1] |
| Assume-guarantee reasoning | 環境への仮定Aの下で部品が保証Gを満たす、として合成する考え方。各部品の仮定を、他の部品が実際に満たすか確認する |
| Rely-guarantee reasoning | 特に並行プログラムで、他の処理による状態変化への仮定（rely）と、自分が許す状態変化の保証（guarantee）を分ける考え方。単なる順序付き関数契約より干渉を明示しやすい |
| Refinement / conformance | 具体的な実装の振る舞いが抽象仕様の許す範囲に収まること。状態機械の証明を実行器・native境界へつなぐ課題 [T2] |
| Proof obligation | 全体の主張を成立させるために証明・根拠付けが必要な個々の義務。証明に未着手の事項と、意図的に信頼する仮定を分ける |
| Trusted computing base (TCB) | 主張の正しさ・安全性を依存させる信頼基盤。何を主張するかで範囲が変わる [T3] |
| Trust boundary / semantic gap | 信頼境界／モデルと実動作の意味論上の隔たり。FFIを越えると、Leanの型だけではC++側の所有権遵守を保証しない |
| Memory safety / temporal safety | メモリ安全性／寿命に関する安全性。解放後利用や二重解放の不在は、論理的なclose後の操作拒否とは別 |
| Ownership / lifetime / quiescence | 保持・解放責任／生存期間／処理が静止した状態。参照が残ること、操作可能であること、保留I/Oがないことを区別する |
| Linearizability | 並行操作に、呼び出しから応答までの間の一貫した効力発生点を与える性質。要求の受付順とnative書き込み登録順がずれない設計に関係する |
| Safety / liveness | 「悪いことが起きない」と「いつか処理が進む」。バッファを保持する安全性は、いつか解放する進行性を意味しない |
| Cancellation safety | 中断されてもデータ・資源・結果通知の整合性が壊れない性質。APIごとに定義が必要で、キャンセル機能の有無だけでは判断できない |

assume-guarantee / rely-guaranteeの代表的な文献として、
Cobleighほか *Learning Assumptions for Compositional Verification*（2003）[T4]、
Jones *Tentative steps toward a development method for interfering programs*（1983）[T5]
がある。書誌情報とDOIを確認したが、今回両論文の全文は取得しておらず、
個別の定理・適用条件まで調査したとはしない。
本プロジェクトでまず整備するものは**依存先契約・環境仮定・根拠の台帳**であり、
これらの証明手法を既に導入済みという意味ではない。

## 3. 調査対象と根拠の強さ

- 実行環境: Linux x86_64、Lean 4.35.0、
  `lean --version` のrevisionは `eb6cafb7290e8bd5f2937522d8d804f58f02bafc`。
- Lean宣言は同梱ソースを確認。nativeソースは公開リポジトリの `v4.35.0` を取得し、
  `tcp.cpp` が上記revisionの内容と同じSHA-256であることを確認した:
  `8b5c7d10b4391ad41a07b56becb84d14bda84793d499aa26cc5fcbe82f75ba5a`。
- インストール済み `libleanshared.so` の `uv_version_string()` を呼び、
  **libuv 1.48.0**を確認した。OSの `libuv` パッケージ版で代用していない。
- 対応するlibuv **v1.48.0の仕様文書**を確認した。Leanの非Emscriptenビルドは
  CMakeでlibuvを検出するため、Lean版だけからlibuv版を一意に決めない [S9]。
- リリースソースと実行バイナリの完全な再現ビルド照合、libuv内部とOSの全経路、
  他プラットフォームは未検証。

以下では **D: 文書化された契約、S: ソースで確認した処理、
M: この環境で測定した事実、P: 形式的に証明済み**を区別する。
Sはレビューした範囲の根拠であって、あらゆる実行・例外経路の正しさの証明ではない。
この調査で新たなPはない。既存のテスト成功も、依存先全体のPへ昇格させない。

## 4. 依存関係と責任の境界

```text
StdExt.WebSocket / Upgraded     要求の受理・失効・Closeの順序・タスク管理
          ↓
Std.Http.Transport             抽象I/O（意味論上の法則は型クラスに含まれない）
          ↓
Std.Async.TCP / Promise        I/O完了の待機、selector、協調キャンセル
          ↓ FFI
Lean runtime C++               参照保持、バッファ所有権、event loopへの同期
          ↓
libuv                         ハンドル、保留要求、コールバック、OS I/O
          ↓
OS / TCP peer                 ソケット動作、通信・スケジューリングの環境
```

LeanのIO論理モデルと実際の副作用実行は区別され、外部関数はランタイムが実行する [S1]。
FFIの借用引数 `@&` は型システム上の線形所有権ではなくABI上の取り決めである。
借用した値を呼び出し後も使うなら、native側が `lean_inc` 等で保持責任を負う。
所有引数はRC tokenを受け取り、消費または解放する責任を負う [S2]。

純粋な定理の検査についての信頼基盤と、実行システムの安全性の信頼基盤は異なる。
前者の定理を検査できても、コンパイラ・FFI・参照カウント・libuv・OSがそのモデルを
実現することは別の義務である。検証済みシステムでも外部仮定を明示する実例がある [T6]。

## 5. 依存先契約・実装の台帳

### C1. 非同期送信のバッファとsocketの生存

- **libuvが要求する前提 (D)**: `uv_write` に渡すバッファは完了コールバックまで
  有効である必要がある。`uv_write_t` も完了前に再利用してはいけない [U1]。
- **Lean側の処理 (S)**: `lean_uv_tcp_send` は `tcp_send_data` に送信配列・socket・
  Promiseを記録し、socketとPromiseを `lean_inc` する。配列は所有引数を保持し、
  `mark_mt` する。完了コールバックでそれぞれを `lean_dec` し、要求と
  `uv_buf_t` 配列を解放する。`uv_write` が即時エラーを返す経路にも清掃処理がある。
  根拠: [tcp.cpp:194](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L194)。
- **使える根拠**: 呼び出し元の参照や送信待ちタスクがなくなっただけで、
  pending writeのバッファ・socketが直ちに解放される実装ではない。
- **残る仮定**: RCと `mark_mt`、配列の共有・変更規則、コールバック、native生成コードが
  契約どおり動くこと。これらの全体証明や全異常経路の検証は今回行っていない。

### C2. 最終解放とFD再利用

- **libuvの契約 (D)**: ハンドルのメモリは `uv_close` のclose callback以後に解放する。
  進行中のwrite/connect要求はcloseによりキャンセルされ、そのcallbackが呼ばれる [U2]。
- **Lean側の処理 (S)**: socket finalizerは読み取り等のpending欄が空であることを
  assertし、`uv_close` を呼び、close callback内でnative構造体を解放する。
  根拠: [tcp.cpp:31](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L31)。
  C1のpending writeはsocketの参照を保持する。
- **含意**: 「WebSocket.closeが呼ばれた直後にFDが解放され、残存sendが別FDを使う」
  という直接的な説明には、この経路では根拠がない。
  一方、これだけでUAF・FD誤用の全可能性を排除したとはしない。
  最終参照がいつなくなるかは、ユーザー参照と保留I/Oにも依存する。

### C3. libuv操作の同期と書き込み順序

- **libuvの前提 (D)**: event loopとハンドル操作は、明記された例外以外thread-safeではない [U3]。
- **Lean側の処理 (S)**: `event_loop.cpp` はmutex、`uv_async_send` による割り込み等で
  ループと呼び出し側のアクセスを調停する。sendの `uv_write` 登録もこのロック内で行う。
  根拠: [event_loop.cpp:10](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/event_loop.cpp#L10)、
  [tcp.cpp:255](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L255)。
- **libuvの保証 (D)**: streamへの登録済みバッファは順番に書かれる [U1]。
  ただし独立タスクがどの順で登録を行うかはWebSocket側の責任。
- **制限**: mutexの公平性・無飢餓性や、WebSocketフラグ確認と送信登録の一体性は
  ここからは導けない。任意の `Transport` でも1回のsendがフレーム単位で直列化される、
  という法則は型クラスからは得られない。

### C4. recvの排他と保留中の生存

- **Leanの契約 (D)**: 同一socketでrecv同士、recvとwaitReadableを並行実行しない。
  根拠: [UV/TCP.lean:52](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Internal/UV/TCP.lean#L52)。
- **処理 (S)**: native recvはloopロック下で二重読み取りを検査し、socketとPromiseを
  保持する。受信バッファはsocketのpending欄で管理し、読取callbackで状態を外して
  結果を渡し、参照を解放する。
  根拠: [tcp.cpp:290](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L290)。
- **含意**: pending recvはsocketを生存させる。受信データも中断も来なければ、
  アプリ参照を落とすだけでfinalizerが受信を止めてくれる、と期待してはいけない。
  生存保持による安全性と、資源を回収できる進行性は別。

### C5. recv中断とPromiseの意味

- 内部の `cancelRecv` は危険な操作として公開TCP APIから隠され、誤用による
  データ損失の注意書きがある (D)。実装はロック下で `uv_read_stop` を呼び、
  pending Promise・バッファ・socketの保持参照を解放する (S)。
  根拠: [tcp.cpp:432](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L432)。
- コメントの「Promiseをnoneにする」を、TCPの正常EOFと解釈してはいけない。
  実装はここで `Promise.resolve (.ok none)` を呼ばず、Promiseをdropする。
  **最終Promise保持がなくなった場合**、`Promise.result?` が外側の `none` になる [S3]。
  `Async.ofPromise` はこれをエラーに変換する [S4]。`some (.ok none)` のEOFとは異なる。
  別の所有参照が残れば、最後のdropまでは同じ完了を仮定できない。
- `TCP.recvSelector` はwaitReadableを使い、unregisterでcancelRecvする。
  `Selectable.one` の登録経路は `finally` でunregisterする [S5]。
  ただしこれはselectorの後始末であり、独立して開始したrecv/sendや子タスク全体の
  キャンセルではない。

### C6. shutdown・close・キャンセルは別操作

| 操作 | 確認できる意味 | 仮定してはいけない意味 |
|---|---|---|
| `WebSocket.close` | Closeフレームを送る | TCPの解放・全参照失効 |
| 標準TCPの `Transport.close` | no-op。FD解放はfinalizerに依存 [S6] | 即時切断・受信解除 |
| `Client.shutdown` / `uv_shutdown` | pending writeの完了を待って書き込み側を半閉鎖 [S7][U1] | 受信中断・即時解放・強制切断 |
| 内部 `cancelRecv` | 読み取り停止と保持参照の清掃 | FD解放・送信中断 |
| `uv_close` | ハンドルを閉じ、完了callbackでメモリを回収可能にする [U2] | 現行の公開TCP APIから任意に実行できる操作 |
| `uv_cancel` | 対象の限られたrequestの中断 [U4] | TCPの `uv_write_t` を汎用に中断できる操作 |
| 待機タスクの放棄・タイムアウト | 呼び出し側が待機をやめる | native I/Oが止まり、バッファが解放可能になったこと |

native shutdownは重複要求を拒否するフラグを持ち、完了までsocketを保持する (S)。
`uv_cancel` の対応request一覧に `uv_write_t` はない (D)。
したがって「タイムアウト後にuv_cancelでsendを止めればよい」という案も使えない。

### C7. 協調キャンセルと進行性

`ContextAsync` は協調キャンセルで、処理側が状態確認・selector等で応答する必要がある。
`Async.race` は敗者を自動キャンセルしない、と明記されている [S8]。
`performUpgrade` が待つ継続は `Async Unit` であり、
サーバーのキャンセル通知だけで内部のpending recvまで取り消される契約はない。

相手・OSが応答する、ループが進む、callbackが実行される、といった条件なしに
「保留writeが必ず一定時間内に完了する」とは今回の資料から言えない。
タイマーを加えても、物理的解放の保証は別途必要である。

### C8. 実測: 実TCPでの保留recvの解決とabort能力（2026-11-03）

[TcpBackendTests](../../LeanWebStudy/TcpBackendTests.lean)で、loopback上の実socket対に
対して以下を実行・確認した（`lake test`に組み込み）。実測は当該環境・当該版での
挙動確認であり、全プラットフォームの保証ではない。

| 確認 | 結果 |
|---|---|
| ピアの`shutdown`（write半閉鎖）と保留recv | 保留中の`recv?`が`none`（EOF）で解決する。逆方向の送受信は生存する（C6の「shutdownは半閉鎖」の実測) |
| selector経由の読み待ち放棄 | `Selectable.one`で敗者になったrecvSelectorのunregister（`cancelRecv`経路、C5）後も、socketは使用可能で後続データを受信できる |
| 沈黙するピアの保留recv（素の`recv?`） | 公開APIに保留中の素の`recv?`やin-flight writeを中断する操作はない。abort能力を失敗として正直に報告し（D5）、sessionの`release`は`.busy`で拒否され続け、ピアEOFのみが解決した（保持責務の維持、C4の帰結） |
| selector化したreadのabort回収 | readを`Selectable.one`（recvSelector＋cancel channel）経由にすると、abortがピアの協力なしに保留readを速やかに解決し、sessionは有界時間で`quiet`に達してreleaseできた。busyは恒久化しない。回収はrace解決（＝操作の完了）後であり、保持中の強制解放はしない |
| graceful close全経路 | 受理済み排出→Close書込→半閉鎖→ピアEOF→release が実TCPで完走し、記録履歴が純粋モデルへ再生一致した |

含意: gracefulな終了はピアの協力（Close応答またはEOF）だけで保留recvが自然に解決するため、
追加の中断能力を要求しない。期限後のabort経路では、**readはselector化すれば自前で回収できる**
（素の`recv?`のままでは不可）。in-flight writeは中断できないが、kernel bufferへの受理で
完了するため、実際の未解決期間は短い。いずれの場合も、取消は「操作を速やかに完了させる」
手段であって、backendが保持中の資源をタイマー等で先に解放する手段ではない（C1のUAF回避）。
owner所有の論理資源（queue・payload・待機者・新規受付）はabort時に即時解放し、
native資源はcallback（race解決）を待って解放する、という二層の解放順序が実測と整合する。
接続ループ組み込みでは読み待ちをselector経由にすることを前提とする。

## 6. 証明へ取り込む前提と未解決の義務

| ID | 前提・義務 | 現在の根拠／不足 | 設計上の扱い |
|---|---|---|---|
| A1 | native処理中は対象socket・バッファが生存する | C1/C4にS。RC・callbackの全体保証は未証明 | 対象backendに限定した外部仮定として明記 |
| A2 | 実行器の登録順でフレームを書き、書き込みを混ぜない | TCP経路にC3のD/S。任意Transportへの保証なし | adapterの契約とし、モデルから順序を制御する |
| A3 | recvの保留は一つだけ | C4のD/S | 所有タスク・実行器が守る不変条件として証明する |
| A4 | キャンセル通知と正常EOFを区別する | C5/C6のD/S | 別Event・結果としてモデル化し、異常終了を正常closeに偽装しない |
| A5 | 終了後の要求はnative操作を開始しない | 現行には不足 | ハンドル失効と要求受付順を拡張側で実装・証明 |
| A6 | 終了完了には保留I/Oがない | 現行のno-op closeでは導けない | cancel/drain完了を追跡。タイムアウトだけで完了状態へ進めない |
| A7 | 有界時間内に全資源を回収する | 強制切断能力・進行性根拠が不足 | 未保証。必要ならbackend能力を追加し、その契約を先に確認 |
| A8 | native実装がモデルに適合する | 部分的なSと版測定Mのみ | 精緻化の証明、コードレビュー、決定的テスト等で別途裏付ける |

例えば証明の主張は「A1/A2を満たすadapterと実行器が、モデルのEffectだけを実行する
なら、失効後に新規データ送信を開始しない」のように条件を表面化する。
これを「LeanでTCPメモリ安全性を証明済み」と言い換えない。
仮定をPropとして渡すことは、その仮定の実世界での成立を証明することではない。

## 7. Std.Httpのpersistent connection管理

Lean 4.35.0の**サーバー側HTTP/1.x**のソースを追跡した結果。
クライアントの接続プール、HTTP/2、TCP keepaliveの調査ではない。
この節はソース上の確認（S）であり、各ケースを新たに実行検証した結果ではない。

### 7.1 再利用の単位は「接続ごとの状態機械」

`Server.serve` は接続を受理すると、その接続用の `serveConnection` を起動する。
`Connection.handle` は同じsocketと `H1.Machine .receiving` を保持し、次を反復する:

1. `machine.step` で読み取り・書き込みの状態を進める。
2. 生成された出力を `Transport.sendAll` で送信完了まで待つ。
3. ヘッダ完了・要求完了・失敗等のイベントを処理する。
4. ハンドラーをタスクとして起動し、結果をチャネルで受け取る。
5. socket、要求bodyへの関心、応答body、ハンドラー結果、キャンセル等をselectする。

通常のHandlerにはsocketを渡さず、要求bodyと応答bodyを介して通信する。
**HTTP本体は接続操作を単一ループに集約している**ので、
ハンドラー同士が直接socketへ競合して書く構造ではない。
ただし、任意に生成した子タスク全体のjoinや、無条件の終了時間保証を意味しない。
根拠: [Connection.lean:309](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L309)、
[Connection.lean:468](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L468)。

### 7.2 接続を継続するかの判定

| 条件 | 実装上の扱い |
|---|---|
| `Config.enableKeepAlive` | 既定true。状態機械のkeepAlive初期値になる |
| HTTP/1.1 | `Connection: close` がなければ継続候補 |
| HTTP/1.0 | `Connection: keep-alive` があれば継続候補 |
| 不正なConnectionヘッダ | `shouldKeepAlive` はfalseを返す |
| 応答側のConnection方針 | 要求側と同様にkeepAliveの更新に反映する |
| 要求数の上限 | `maxRequests` 既定100がH1の `maxMessages` へ渡り、上限に達する応答では継続を止める |
| close-delimited body | 境界がEOFに依存するので継続を止める |
| HTTP/1.0でサイズ不明の応答body | chunkedを使わず接続終了によるframingへ切り替え、継続を止める |

`updateKeepAlive` は `old ∧ condition` なので、同じ接続で一度falseになった方針を
後からtrueには戻さない。応答ヘッダは状態機械がConnection値を整理し、
継続しない場合は `Connection: close`、HTTP/1.0の継続時は `keep-alive` を付ける。
根拠: [Message.lean:113](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1/Message.lean#L113)、
[H1.lean:208](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L208)、
[H1.lean:690](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L690)、
[H1.lean:711](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L711)。

### 7.3 次の要求へ移る境界とbodyの後始末

単に「応答ヘッダを送ったら次の要求へ進む」わけではない。
readerとwriterの完了を見て `resetForNextMessage` し、`.next` イベントを出す。
未消費の入力と既に生成した出力は保持し、要求数を増やし、要求ごとのreader/writer状態を
初期化する。サーバーループも古いbody streamを閉じ、新しい要求stream・応答チャネルを
作り直す。

応答を送り終えた後に要求bodyが残っている場合、`drainBodyInternally` により
状態機械がbodyを内部で消費する。これにより、残りのbodyを次の要求ヘッダと誤認しない。
bodyが揃わなければ入力を待つ必要があり、無条件に次の要求へ進めるわけではない。

入力に複数要求が先行して含まれるpipeliningを扱えるが、ここで確認した処理は、
接続上で要求・応答の境界を順に進めるもの。同じ接続の複数要求ハンドラーを並列に起動し、
後から応答順を並べ替える構成ではない。
根拠: [H1.lean:404](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L404)、
[H1.lean:593](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L593)、
[H1.lean:1054](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L1054)、
[Connection.lean:272](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L272)。

### 7.4 タイムアウトは段階別。ただし万能のdeadlineではない

| 段階 | 既定値・扱い |
|---|---|
| 初回入力待ち／要求間のidle | `keepAliveTimeout = 12000ms`。期限で `.close` を選びループ終了へ進む |
| idle後の最初のバイト受信からヘッダ完了まで | `headerTimeout = 5000ms` の絶対時刻を設定。受信のたびに期限を延長する方式ではない |
| ヘッダ完了後の入力待ち等 | `currentTimeout` を `lingeringTimeout = 10000ms` に切替 |
| ヘッダ等のtimeoutイベント | `closeWithError 408`。既に応答に着手している場合はwriterを閉じる経路になる |
| サーバーのキャンセル | `closeWithError 503`。状態に応じエラー応答またはreader/writer終了へ進む |

重要な制限として、これらのsocket待機用タイマーは `pollNextEvent` にsocketが
含まれる場合にだけ登録される。ハンドラー結果だけを待つ場面では、その待機に
自動で10秒のdeadlineがかかるとは限らない。
また `Transport.sendAll` 自体はこのselectの外で待機するので、
pending write中のshutdown・送信タイムアウトをこのタイマーが強制的に処理するわけではない。
応答body等の別イベントでpollへ再入すれば相対タイマーも作り直される。
したがって「すべての要求が10秒以内に終了する」「shutdownは必ず一定時間内に終わる」
という契約には読み替えない。
根拠: [Connection.lean:99](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L99)、
[Connection.lean:353](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L353)、
[Connection.lean:439](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L439)。

### 7.5 論理的な終了と物理的な解放の区別はHTTPにもある

`H1.Machine.halted` はreaderとwriterがclosedで、出力バッファが空であることを判定する。
ループ終了時はbody streamを閉じ、`Transport.close socket` を呼ぶ。
標準TCPではC6で確認した通りno-opであり、socketのfinalizerに解放を委ねる。
通常HTTPではアプリにsocketを渡さず、selectの後始末もあるため、
ループが終わり参照が不要になればfinalizerによる回収へ進める構成である。
ただし「全native資源の解放完了通知」を待つAPIではない。

`Server` の接続上限は既定1024。接続処理から戻る際の `finally` でpermitを返し、
active counterを減らす。acceptループ自身も同じcounterで追跡されるため、
これは厳密には純粋な「開いているFD数」ではない。
`shutdownAndWait` はキャンセル後、この管理対象が終了して通知するのを待つ。
各FDのclose callback完了や、アプリが独立に起動した全タスクの終了を数えてはいない。
根拠: [H1.lean:523](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Protocol/H1.lean#L523)、
[Connection.lean:529](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L529)、
[Server.lean:135](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server.lean#L135)。

### 7.6 WebSocket設計への含意

**Std.Httpが接続の寿命を考えていない、という理解は修正すべきである。**
HTTPの要求境界、単一の接続ドライバー、bodyの消費、再利用可否、idle期限、管理対象の
終了という仕組みが既にある。一方、それは任意の双方向プロトコルの終了保証ではない。

| HTTP本体が持つ仕組み | upgrade後に拡張側が引き受けること |
|---|---|
| reader/writer完了後の `.next` | メッセージ・Close・保留I/Oを含む独自の状態遷移 |
| socketへ書く単一の接続ループ | 複数send、受信由来の自動pong/Closeをまとめる所有タスク |
| HTTP bodyの明確な境界と内部drain | WebSocketのフレーム境界と、終了時の受付・排出方針 |
| keep-alive idle/headerのselect | WebSocket用のidle、shutdown、完了待機の多重化 |
| HTTP処理の終了counter | 接続操作権の失効と終了通知の意味を明確にする |

従って、単一所有タスク案はStdの方針を捨てるというより、
**HTTPドライバーが担っていた責務を、upgrade後のプロトコル用に再構成する案**
と位置付けるのが自然である。native強制終了能力の不足はHTTPにも残る別問題なので、
HTTPから継承してよい契約と、新たに必要な契約を分けて扱う。

## 8. 次の作業と判断ゲート

1. この台帳を基に、公開APIだけで実現する保証と、backendの追加能力が必要な保証を決める。
   **全資源の強制回収を必須にするなら、能力不足を解決する前に終了モデルを確定しない。**
2. 失効、終了開始、要求結果の確定、I/O静止、native解放完了を別々に定義する。
   論理的な失効の完了を先に返すAPIは可能だが、資源回収済みとは表示しない。
3. selector中断、Promise drop、EOF、pending send、同時shutdownを制御可能なテストで
   確認する。保持・解放のカウンタやnative計測でC1/C4を補強する。
4. native寿命については対応ソースのレビューと必要なsanitizer検証を行う。
   libuv内部・OSまで含む全体証明がない部分は残存仮定にする。
5. Lean・libuv・backend・OSを変更したら、版測定とC1〜C7の適合確認をやり直す。
   既存テストの成功だけで、契約の再確認を省略しない。

証明の価値は仮定をゼロと称することではなく、**どこまでを証明し、どこからを信頼し、
その信頼を何で裏付けたかを追跡できること**にある。

## 参照資料

すべて2026-11-02参照。GitHubの行番号は固定版を対象とする。
Leanのオンライン言語リファレンスは `latest` の一般説明であり、実装根拠には
Lean 4.35.0のソースを優先した。

- [T1] [Design by contract](https://en.wikipedia.org/wiki/Design_by_contract)
- [T2] [Refinement (computing)](https://en.wikipedia.org/wiki/Refinement_(computing))
- [T3] [Trusted computing base](https://en.wikipedia.org/wiki/Trusted_computing_base)
- [T4] [Learning Assumptions for Compositional Verification, DOI](https://doi.org/10.1007/3-540-36577-x_24)
- [T5] [Tentative steps toward a development method for interfering programs, DOI](https://doi.org/10.1145/69575.69577)
- [T6] [seL4: Verification assumptions](https://sel4.systems/Verification/assumptions.html)
- [S1] [Lean: IO logical model](https://lean-lang.org/doc/reference/latest/IO/Logical-Model/)
- [S2] [Lean: FFI / Borrowing](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/#ffi-borrowing)
- [S3] [Lean 4.35.0: Promise](https://github.com/leanprover/lean4/blob/v4.35.0/src/Init/System/Promise.lean#L22)
- [S4] [Lean 4.35.0: Async.ofPromise](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/Basic.lean#L872)
- [S5] [Lean 4.35.0: TCP.recvSelector](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/TCP.lean#L187) /
  [Selectable.one](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/Select.lean#L183)
- [S6] [Lean 4.35.0: Transport](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Transport.lean#L45)
- [S7] [Lean 4.35.0: Client.shutdown](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/TCP.lean#L224) /
  [native shutdown](https://github.com/leanprover/lean4/blob/v4.35.0/src/runtime/uv/tcp.cpp#L634)
- [S8] [Lean 4.35.0: ContextAsync](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/ContextAsync.lean#L15) /
  [Async.race](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/Basic.lean#L941)
- [S9] [Lean 4.35.0: libuv build configuration](https://github.com/leanprover/lean4/blob/v4.35.0/src/CMakeLists.txt#L353)
- [U1] [libuv 1.48.0: stream API](https://github.com/libuv/libuv/blob/v1.48.0/docs/src/stream.rst)
- [U2] [libuv 1.48.0: handle API](https://github.com/libuv/libuv/blob/v1.48.0/docs/src/handle.rst)
- [U3] [libuv 1.48.0: design](https://github.com/libuv/libuv/blob/v1.48.0/docs/src/design.rst)
- [U4] [libuv 1.48.0: request / uv_cancel](https://github.com/libuv/libuv/blob/v1.48.0/docs/src/request.rst)
