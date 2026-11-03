# 実Asyncランタイム接続（段階C 第1スライス）の実装結果

所属: [Std拡張WebSocket開発](./README.md)。
[試作結果](./websocket-prototype-results.md)5節「段階C: 限定backendを一つ接続する」の
最初のスライスの記録。前提は
[段階Bの結果](./websocket-mock-executor-results.md)。

2026-11-03。**純粋モデルを実`Std.Async`ランタイムとStd付属のmock transportに接続した。
公開API（`WebSocket`・`serveUpgradableConnection`等）と実通信経路は変更していない。**
実TCP・HTTP/2への接続はこのスライスの範囲外。

## 1. 実装した範囲

[AsyncExecutor](../../StdExt/Http/WebSocket/AsyncExecutor.lean)は、
`Lifecycle`純粋モデルを`Backend`能力レコード越しに実行する単一ownerのセッションである。
段階Bのモック実行器（純粋）と異なり、ここでは**実I/Oを`Async`タスクとして起動し、
その完了・失敗をモデルイベントとして戻す**。

- `Backend`: write / read / finishSend / abort の4能力。各能力は対象backendが
  実際に提供する操作に対応し、**成功を装うno-opを禁止する（D5）**。
- 全I/Oはまず`step`を通る。モデルが拒否したイベントではbackend I/Oを起こさない
  （`dispatch`の遅れたreserveは登録されない）。backend完了は必ずモデルへ戻す。
- payload（送信バイト列）は受理から**write完了まで保持**し、`.result`エフェクト
  （成功・失敗・取消）が出た要求の分だけ解放する。libuvのbuffer保持契約
  （[依存先契約](./websocket-dependency-contracts.md) C1）の対応物。
- `history`に全モデルイベントを記録し、`replay`で純粋モデルへ再生できる。
  **実backend上の実行が有効であることの判定を、純粋モデルの再生一致で定義する**。
- `release`はモデルの`quiet`成立時のみ成功し、加えてアダプタがタスク・payloadを
  保持していないことを表明する（残っていればバグとして例外）。

接続先は`Std.Http.Internal.Mock`（`CloseableChannel`双方向）。
試作結果5節が候補に挙げたStd HTTPのmock transportである。

## 2. backend能力の確認（D1・D5）と、成功偽装の排除

対象backendをLean Std TCP/libuvとし（D1）、使用能力をその実際の契約に限定した（D5）。
mock transportは各能力を実際に実行し、能力のない操作をfallbackで補わないことを
テストで確認した。

| 能力 | 対象backendでの実体 | 根拠 | mockでの検証 |
|---|---|---|---|
| write | `uv_write`。登録済みバッファは完了callbackまで保持。**一般のTCP writeは`uv_cancel`で中断不可** | [依存先契約](./websocket-dependency-contracts.md) C1・[U4]（uv_cancelの対象にuv_write_tは無い） | write成功はawaitWriteの完了で確定。送信直列化は`wireLog`で検査（段階B） |
| read | `recv?`。pending recvはsocketを生存させる | 同 C4 | beginRead/awaitReadで登録・完了。EOFは`none` |
| finishSend | TCP `shutdown`（write側半閉鎖）、HTTP/2 END_STREAM | 同 [L12]・[L13] | mockでは送信方向chを閉じ、clientがEOFを観測することを確認 |
| abort | `cancelRecv`相当でpending readを解放。**送信中writeの強制中断は約束しない** | 同 C5・[U4] | mockでは両方向chを閉じ、pending readが解放されることを確認。writeの強制中断は主張しない |

**中断不能を成功へ変換しない**: write失敗は`.failed`として確定し、
closeやabortの成功で覆い隠さない（D3・試作結果6.3）。
abortは「できる範囲の中断」であり、`release`はabort発行だけでは成立せず、
保留I/Oの完了イベントを受けて初めて`quiet`になる。
mock transportの`close`が効いてもTCPで同じ中断が効くとは仮定していない。

## 3. 検証結果

[AsyncExecutorTests](../../LeanWebStudy/AsyncExecutorTests.lean)で、
実`Async`ランタイム（`Async.block`）上の3シナリオを検査した。
各シナリオは実行後、記録した履歴を純粋モデルへ`replay`し、最終状態の一致を確認する。

| シナリオ | 検査内容 |
|---|---|
| graceful close | 受理2件を順に排出→Close書込→ピアClose→finishSend半閉鎖→pending read解放→release。clientが各frameとClose後EOFを実際に受信。履歴がモデルへ再生一致 |
| write失敗 | 送信方向を事前に閉じてdispatch。writeが`.failed`になり成功偽装しない。wireに何も出ない。abort→backendEnded→release。失敗が結果として確定 |
| deadline＋保留read | deadlineで未着手要求を取消。遅れたdispatchは`.closed`で拒否されbackendに届かない。abortがpending readを解放。release |

既存の`lake test`に組み込み、全テスト成功（lifecycle探索20,020・実行器探索37,305・
本スライス3シナリオ・既存UTF-8 Close・SQLite）。

## 4. 通常HTTPとupgradeの終了契約の整合（段階A）

試作結果5節段階Aと[動作方針4.6節](./websocket-behavior-policy.md)の要請に対する現状整理。

- **Transport.closeの意味を分けない**: 本アダプタは`Transport.close`に
  「全I/O中断・回収完了」の意味を負わせない。標準TCPの`close`はno-opであり
  （[依存先契約](./websocket-dependency-contracts.md) [L10]）、
  finishSend（半閉鎖）とabort（できる範囲の中断）を別能力として明示的に分けた。
  これは通常HTTPの接続終了（body stream close→Transport.close）と同じ前提に立つ。
- **所有の分担（D2）**: セッションの開始済みI/O・要求の回収はowner（`Session`）が行い、
  Transport/body/接続境界の後始末はHTTP connectionに残す、という試作結果6.2節の分担を
  アダプタ構造に反映した。`Session`はTransportを所有せず`Backend`能力だけを受け取る。
- **残る義務**: 本スライスは`serveUpgradableConnection`の実接続ループへは未配線である。
  通常HTTPとupgradeの両経路で同一の終了契約表（試作結果5節段階A）を適用する作業と、
  shutdown時の保留recvの扱いの実証は、実TCP接続時に行う。

## 5. 今回の簡略化と残る義務

| 簡略化 | 残る義務 |
|---|---|
| 単一owner・逐次駆動（dispatch/awaitを呼び手が順に呼ぶ） | 並行send向けのmailbox/lock規律。利用者向け直列化（D3）はモデルが既に強制するが、複数呼出の受理点の実装は未着手 |
| readの完了はデータ有無のみ（EOF・エラーをともに`none`→backendEnded） | データ・正常EOF・取消・失敗の区別と、フレーム解析・配送への接続 |
| registration失敗は`async`タスクの失敗として観測 | libuvの同期的`uv_write`エラーと完了callback失敗の区別。純粋な区別は段階Bの`MockExecutor`で検査済み |
| backendは抽象能力レコード | 実TCP(`Socket.Client`)・HTTP/2 Tunnelへの配線。mock closeが効いてもTCPで効くと仮定しない |
| 接続ループ未配線 | `serveUpgradableConnection`からの駆動、通常HTTPとupgradeの終了契約の同一適用 |
| 公開終了API未定 | `requestClose`/`release`等は内部メソッド。公開APIと既存`close`の互換性（D6）は未変更・未決 |

本スライスはnative全体のメモリ安全性、有界時間の資源回収、HTTP/2適合を
証明済みとはしない。mock transportでの成功はlibuv/TCPでの同一挙動を意味しない。

## 6. 次の作業

[試作結果6.4節](./websocket-prototype-results.md)の台帳を正とする。
残りは実TCP(`Socket.Client`)への`Backend`配線と、
`serveUpgradableConnection`の実接続ループへの組み込みである。
その前に、shutdown時の保留recvがLean Std TCPで解消できるか（解消できない場合も
保持・回収責務を維持できるか）を確認する。HTTP/2は別adapterとして後続で検証する。
