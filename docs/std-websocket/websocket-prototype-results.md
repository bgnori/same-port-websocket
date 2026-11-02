# WebSocket純粋モデル試作結果とTransport接続試作の条件

所属: [Std拡張WebSocket開発](./README.md)。純粋モデル試作の検証結果。

2026-11-02。**純粋モデルとテストを実装・検証した。実Transportへの接続は未実施**。
本番WebSocket・HTTP・Transportの動作および公開APIは変更していない。

前提: [設計方針](websocket-lifetime-design.md)、
[モデル比較](websocket-model-proposals.md)、
[動作契約とHTTPとの整合](websocket-behavior-policy.md)、
[依存先契約](websocket-dependency-contracts.md)。

## 1. 実装した範囲

- [Lifecycle](../../StdExt/Http/WebSocket/Lifecycle.lean):
  Bの直積状態・操作記録を小さく実装し、Cの保持義務を保留read/writeの記録として表した。
  汎用のPermit/Leaseフレームワークは作っていない。
- [LifecycleTests](../../LeanWebStudy/LifecycleTests.lean):
  純粋なstepへEvent列を与える決定的テストドライバーと、有界な履歴探索。
  OSのsocket・タスク・タイマーを使わない。並行実行器のモックそのものではない。
- [既存テスト入口](../../LeanWebStudyTests.lean):
  新テストを組み込み、既存テストと同じ `lake test` で実行する。

stepは `Except Error (State × List Effect)` を返す。
要求拒否、容量超過、不明・重複完了、使用中資源の解放要求は明示したエラーになる。
エラーの場合は状態遷移・Effect実行を行わない契約である。
実行器がエラーをどう報告するかは次段階で定義する。

### 状態と操作

| 対象 | 試作での表現 |
|---|---|
| 受付 | accepting。close後のsubmitは拒否 |
| 正常close | 新規受付停止、queue排出、Closeの予約・開始・書込完了 |
| ピアClose | 未着手queueと予約を取消。実行中writeを保持し、Close応答を可能にする |
| abort・期限 | 新規開始を停止。未着手要求を取消。開始済みread/writeは残す |
| write | reservedとwritingを別の枠にし、操作IDで開始・完了を対応付ける |
| read | 一つの操作IDを保持。完了イベントでのみ取り除く |
| 資源保持 | 保留操作がある間はreleaseを拒否。native参照保持自体は対象外 |
| backend終了通知 | backendEnded。これだけではread/writeを消さない |
| 容量 | 未完了要求件数・保持payloadバイト数。予約・実行中writeも含む |
| 結果 | 要求IDと結果を記録し、Effectとして通知。ピア配送の成功は意味しない |

要求ID・操作IDは一つの単調増加Natから発行し、再利用しない。
書込開始の即時登録失敗は、開始済み操作に対する `.failed` 完了として表す。
開始前の失効で予約を撤回できるため、遅れた `.start` は実行されない。
実行器にこの性質が自動で移るわけではない。

## 2. 証明とテストの結果

### 2.1 Leanカーネルで確認した補題

公理追加・`sorry`を使わず、以下の**局所的性質**を証明した。

| 補題 | 主張 |
|---|---|
| release_requires_quiet | release操作の成功にはquietが必要 |
| quiet_has_no_writes | quietなら予約・実行中writeがない |
| stopping_rejects_start | 停止中の書込開始は拒否 |
| revoked_rejects_submit | 受付失効後のsubmitは拒否 |
| close_rejects_data_start | Close開始済みならデータ予約を開始できない（停止等の他条件は引数に明示） |

これらは全到達状態の不変条件保存証明ではない。
設計文書のS1〜S6を完成したとは扱わない。
例えば「結果が全履歴で高々一度」「全到達状態でIDが一意」は、
今回の有界探索では検査するが、一般の帰納的証明は残っている。
releaseの補題も、quietの定義に従うことの証明であり、native資源の安全な解放の証明ではない。

### 2.2 決定的テストと有界探索

`#guard`による入力列で、次を検査した。

- 受理済み二件の順序どおりの排出、Close、下位終了、releaseの全Effect列。
- 受付失効後のsend拒否、予約後のabort、二重readの拒否。
- 不明ID・重複write完了・停止要求前の不正な取消完了の拒否。
- 開始済みwriteが残る間の解放拒否と、取消完了回収後の解放。
- readが残る間は、期限切れとbackend終了通知を受けても解放できないこと。
- ピアCloseで未着手二件を取消してClose応答すること。
- Close書込前／後のピアClose、重複closeでもfinishSendを重複発行しない入力列。
- データ書込失敗、Close書込失敗後の再送禁止、二重release拒否。
- 件数超過、queueだけでなく実行中writeを含めたpayload容量超過。

さらに15種類の候補イベントから深さ5まで探索し、
**13,869ノード（同じ状態へ至る別履歴を含む）**で次を検査した。

- 要求結果IDの重複なし。
- 件数・payload容量の上限を超えない。
- 予約writeと実行中writeを同時に持たない。
- releasedならquiet。
- Close開始後、停止中、ピアClose後のデータwrite Effectなし。
- 重複Close開始なし、release Effect発行前のquiet。

これは有限範囲のモデル検査であり、全入力・全時間に対する証明ではない。
候補イベントのIDは主として現在の操作IDから生成する。
不正ID等は個別入力列で補っており、全ID値を探索したわけではない。

### 2.3 実行した検証

- `lake build LeanWebStudy.LifecycleTests`: 成功。
- `lake test`: 成功。新しい探索と既存のUTF-8 Close・SQLiteテストを含む。

ネットワーク動作を変えていないため、この段階ではPython WebSocket統合テストや
実HTTP/2接続の検証は実行していない。

## 3. 試作から得た具体的な判断

1. **公開の終了待機APIを決めなくても、内部状態と安全性検査は実装できた。**
   HTTP側のAPIとの整合を検討する余地を残せる。
2. **受付失効と送信禁止を同じBoolにできない。**
   正常close後の既存データ排出と、Close開始後の禁止が実際に別条件になった。
3. **予約と開始済みを分けることに意味がある。**
   abortで予約を取り消しても、開始済みwrite/readは残す必要があった。
4. **下位終了通知とI/O静止は独立である。**
   backendDoneを受けても未回収readがあればreleaseできない履歴を再現できた。
5. **ピアCloseが来る順序は両方向のテストが必要。**
   Close書込後にPeerCloseが来る場合にもfinishSendが必要で、
   逆順だけをテストしては下位終了の開始を取りこぼす。

## 4. 今回の簡略化と、接続前に必要な拡張

| 簡略化 | 実Transport接続前の義務 |
|---|---|
| readDoneはID回収だけ | データ、正常EOF、取消、失敗を別Eventへ分け、フレーム解析・配送と接続する |
| backendDoneは抽象入力 | 通常終了・障害の結果と、その通知が実際に保証する範囲を定義する |
| abortBackend・finishSendは意図のEffect | 制御操作自体の予約・登録・完了・保持を台帳に追加する。未実行Effectを残してreleaseしない |
| releaseOwnedは抽象Effect | adapter固有の解放要求・完了確認と区別する。Effect生成だけで解放済みと表示しない |
| 結果通知は論理的な確定 | 通知配送失敗、待機取消、owner例外でも確定・回収責務が残る設計にする |
| 結果履歴を全保存 | 長寿命接続で無限増加しない回収と、古い通知を識別する方式を決める |
| 容量はpayloadだけ | フレーム符号化・制御用バッファ・未受理呼出・受信配送も含む実メモリ予算を確認 |
| Ping/Pong、分割・圧縮は対象外 | 自動応答も同一write経路へ集約。現在単一フレームでも全送信経路を確認 |
| 単一セッションのみ | HTTP/2ではstreamをscopeとし、共有接続の解放を要求しない |

特に現quietは**モデル内のread/writeと要求の静止**であり、
制御I/O・native callback・全子タスクまで含むS6の完成形ではない。
本試作のままreleaseOwnedを実際のsocket解放へ結び付けてはいけない。

## 5. Transport接続試作への作業順序

### 段階A: 共通の終了契約を具体化する

通常HTTPとupgradeの双方について、以下の表を埋める。
WebSocketだけ特別な意味を持つ `Transport.close` を作らない。

| 境界 | 次に確認する事項 |
|---|---|
| I/O開始 | ownerによる開始確定とnative登録の間に、遅れたEffectを実行する隙間がないか |
| 書込完了 | 成功・部分失敗・即時失敗をどう観測し、どの保持を解除できるか |
| 受信終了 | selector解除、Promise drop、EOF、取消をどう区別するか |
| 正常下位終了 | HTTP/1のwrite半閉鎖とHTTP/2 END_STREAMの開始・完了をどう追跡するか |
| 異常中断 | 操作対象、能力の有無、冪等性、完了・遅延callbackの契約 |
| 接続処理の終了 | handler/upgrade継続、owner、body stream、保留I/Oを誰が回収するか |
| 解放 | セッション所有資源と共有資源、参照返却と物理解放の区別 |

### 段階B: 制御可能な非同期モック実行器

先に制御操作の台帳を拡張し、stepのEffectだけを実行するドライバーを作る。
登録・完了を手動で止められるモックで、予約後失効、登録直後例外、
完了順序の入替え、半閉鎖待ち、取消待ち、結果待機者の消失を再現する。
モデルのイベントを直接並べる今回のテストと異なり、
**実行器が作る履歴をモデルに対応付ける**ことを目的とする。
全到達状態の不変条件保存証明もこの段階までに拡充する。

### 段階C: 限定backendを一つ接続する

Std HTTPのmock transport等を候補とし、能力を確認してから選ぶ。
mockでcloseが効いてもTCPで効くとは仮定しない。
通常HTTPとupgradeについて同じ終了契約の検査を適用し、
既存APIや終了待機の意味が変わらないこともテストする。

TCP接続は、未解決の保留recv/writeを解消できるか、
解消できない場合も保持と回収責務を維持できるかを確認してから行う。
中断不能を単に成功へ変換するadapterは不可。
HTTP/2は別adapterとして適合を検証し、共有接続への影響範囲を確認する。

### この次段階での合格条件

- 通常HTTPとupgradeの終了契約の対応と能力差が文書・テストに表れている。
- 未実行・実行中の制御I/Oも含め、静止と保持の不変条件を満たす。
- 全I/O開始が実行器経由で、失効・開始・完了の競合が決定的に再現できる。
- 対応backendで保証できることと、条件付きの進行性・未保証範囲を分けている。
- 公開API変更が必要なら、既存closeの意味とHTTP接続終了との互換性を先に合意する。

この段階でもnative全体のメモリ安全性、有界時間の資源回収、HTTP/2実装全体の適合を
証明済みとは扱わない。
