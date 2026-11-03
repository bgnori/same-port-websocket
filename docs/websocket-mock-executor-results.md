# 制御操作台帳とモック実行器（段階B）の実装結果

所属: [Std拡張WebSocket開発](./README.md)。
[試作結果](./websocket-prototype-results.md)5節「段階B: 制御可能な非同期モック実行器」と
6節の承認済み契約（D2・D3）に基づく実装の記録。

2026-11-03。**純粋モデル内の作業であり、公開API・実通信経路は変更していない。**
実Transport・実TCPへの接続（段階C）は未実施。

## 1. 実装した範囲

### 1.1 制御操作の台帳化（モデル拡張）

[Lifecycle](../StdExt/Http/WebSocket/Lifecycle.lean)を拡張し、
`abortBackend`・`finishSend`を「意図のEffect」から、writeと同じ台帳管理の操作へ変えた。

| 段階 | 表現 |
|---|---|
| 予約 | モデルが`controls`台帳へ追加し、`.control id kind` Effectで実行器へ通知 |
| 登録 | `controlStart`イベント。実行器がbackendへの登録を確定した時点 |
| 完了 | `controlDone id outcome`イベント。backend callbackまたは撤回 |
| 保持 | 台帳に残る間は`quiet`が成立せず、releaseを拒否する |

未登録の制御操作は`.cancelled`でのみ撤回でき、登録済みの操作は
任意のoutcomeで完了できる。操作IDはwrite・readと同じ単調増加Natから発行する。

付随して**releaseを終端状態にした**。従来のモデルではrelease後の`peerClose`が
`finishSend`を発行し得る穴があった（releaseOwned後に新規I/O意図が生まれる）。
release後は`release`以外の全イベントを`.closed`で拒否する。

### 1.2 容量上限の初期値（D4）

既存実装の既定値調査と採用判断は
[動作方針4.7節](./websocket-behavior-policy.md)に記録し、
採用値（未完了要求32件・保持payload 1 MiB）を
`Lifecycle.Limits.default`として実装した。

### 1.3 モック実行器

[MockExecutor](../StdExt/Http/WebSocket/MockExecutor.lean)は、
利用者呼出・owner判断・backend callbackを別々のCommandとして受け取り、
モデルの`step`が返すEffectだけを実行する純粋・決定的なdriverである。

- `Backend`台帳: 登録済みwrite/read/control。登録順のwireLog（送信直列化の観測点）。
  完了callbackを受けるまで操作は台帳から消えない（buffer保持の対応物）。
- 待機者台帳: `.accepted`で待機者を登録し、`.result`を配送（delivered）または
  待機者消失後の確定（orphaned）として記録する。
- 登録失敗の注入: `injectRegistrationFault`後の登録は、backendに何も保持させず、
  開始済み操作への`.failed`完了をその場でモデルへ返す。
- `consistent`: backend台帳とモデルの`writing`/`reading`/`controls`の一致、
  結果が`State.results`とちょうど一度ずつ対応すること、wireLogで
  Close frame後にdata frameがないこと・data frameが受理順であること（D3）、
  release済みなら未実行Effect・登録済みI/Oが残っていないことを、
  コマンドごとに検査する。

実行器の各runはモデルEvent列（`history`）を生成する。
**モデルが拒否するイベントでは実行器はbackendに何も登録しない**ため、
予約撤回後の遅れたdispatchが実I/Oにならないことが構造的に成立する。
一方、登録済み操作のcallbackをモデルが拒否した場合は、
刈り込みではなく`mismatch`（バグ）として報告する。

## 2. 検証結果

### 2.1 Leanカーネルで確認した補題

既存5補題を維持し（`quiet`の変更に追随）、以下を追加した。
公理追加・`sorry`はない。

| 補題 | 主張 |
|---|---|
| quiet_has_no_controls | quietなら制御操作の台帳が空 |
| released_is_terminal | release済み状態では**いかなるイベントも成功しない**（S5の遅延完了で終端状態を再開しない、の一般形） |
| step_preserves_write_exclusion | 予約writeと実行中writeを同時に持たない性質を、**全イベントのstepが保存する**（S1型の帰納的保存証明の最初の一つ） |

`released_is_terminal`と「release遷移がquietを要求しquietを保存する」ことから、
到達可能状態での「released → quiet」は帰納的に従う。
残りの不変条件（結果の高々一度、ID一意性等）の保存証明は未完で、
有界探索での検査に留まる。

### 2.2 決定的テストと有界探索

- [LifecycleTests](../StdExtTests/LifecycleTests.lean):
  入力列を制御操作台帳へ追随させ、制御操作の誤用（未登録完了・二重登録・
  未完了でのrelease・release後のpeerClose拒否）を追加。
  探索は制御イベントを加えた23種・深さ5で**20,020ノード**。
  不変条件に操作ID（write・read・control）の全体一意性を追加した。
- [MockExecutorTests](../StdExtTests/MockExecutorTests.lean):
  Commandレベルの決定的シナリオ12件と、27コマンド・深さ5の
  **37,305ノード**の探索。全ノードで`consistent`を検査し、
  mismatchゼロを確認した。

決定的シナリオは段階Bの目標だった履歴を含む:
予約後失効（遅れたdispatchは登録されない）、登録直後例外、
完了順序の入替え（abort control・cancelled writeの両順、backend終了後のcallback）、
半閉鎖待ち（finishSend完了までrelease拒否、peerCloseとClose書込の両順）、
取消待ち（登録済みread/abort controlの回収までrelease拒否）、
結果待機者の消失（結果は一度だけ確定・保持される）。

### 2.3 実行した検証

`lake test` 成功（lifecycle探索・実行器探索・既存のUTF-8 Close・SQLiteテストを含む）。
ネットワーク動作は変更していないため、Python統合テスト・実HTTP接続の再検証は行っていない。

## 3. 既存実装を参考にした選択と理由

| 選択 | 参考にした実装 | 理由 |
|---|---|---|
| 実行器をsans-I/O（純粋状態＋明示入力）にする | Python websockets の sans-io `Protocol`（`events_received`/`data_to_send`）、本repoのフレーム層 | I/Oなしで履歴を決定的に再現・探索でき、実backend接続時はadapterを差し替えるだけにする |
| 登録済み操作はcallbackまで台帳に保持 | libuv `uv_write` のbuffer生存契約（[依存先契約](./websocket-dependency-contracts.md) C1） | timeoutやshutdownを理由に「完了したことにしない」。保持義務の対応物を実行器側に持つ |
| 登録失敗は「開始済み操作の同期的`.failed`完了」 | libuvの`uv_write`即時エラー（登録されなければ何も保持されない） | 失敗をsend成功やcloseの成功で覆い隠さない（D3）。wireLogにも残らない |
| スケジュールの有界全探索 | Rust `loom` の bounded model checking | 代表例だけでなく、深さ内の全コマンド交互配置で対応関係を検査する |
| 件数・バイト上限の初期値 | Python websockets `max_queue`/`max_size`（詳細は[動作方針4.7節](./websocket-behavior-policy.md)） | 無制限既定（Lean Std channel・ws等）は台帳の有界性と両立しない。既存`Config`の1 MiBメッセージを受理できる値にする |
| 待機者消失でも結果を確定・保持 | 本repoの[動作方針](./websocket-behavior-policy.md)（通知配送失敗・owner例外でも確定・回収責務が残る） | 「待機者がいない＝結果を捨ててよい」にしない。orphanedとして観測可能にした |

## 4. 今回の簡略化と残る義務

| 簡略化 | 残る義務 |
|---|---|
| mock backendのcallbackは常に手動コマンド | 実backendでは完了が自発的に届く。段階Cでlibuv/Std TCPの実際の完了・失敗経路と照合する |
| readの完了はID回収のみ（従来どおり） | データ・EOF・取消・失敗の区別とフレーム解析への接続は未着手 |
| `finishSend`完了の意味は抽象 | HTTP/1半閉鎖・HTTP/2 END_STREAMへの対応付けは段階A/Cの契約表で確定する |
| `releaseOwned`はExecutor内のフラグ | adapter固有の解放要求・完了確認との区別は未実装。実socket解放へ直結してはいけない |
| 探索は深さ5・固定コマンド集合 | 全入力・全時間の証明ではない。不変条件の帰納的保存証明はwrite排他のみ |
| 結果履歴は全保存のまま | 長寿命接続での回収方式は未決（従来からの継続課題） |

## 5. 次の作業

[試作結果6.4節](./websocket-prototype-results.md)の台帳を正とする。
残りは「HTTP/1 backendへ接続する」（段階C）と、必要な場合のcloseの反例記録である。
段階Cの前に、D7の暫定合格条件（試作結果5節）を本結果に照らして見直すこと。
特に「全到達状態の不変条件保存証明」はwrite排他と終端性のみ完了しており、
結果の一意性・容量不変条件の帰納的証明は段階Cまでの残作業として明示する。
