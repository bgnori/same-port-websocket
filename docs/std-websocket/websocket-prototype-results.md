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

## 6. 次段階の作業チェックリストと判断台帳

この節は、次の実装に入る前に判断漏れや前提の食い違いを防ぐための作業台帳である。
契約の根拠は[動作方針](websocket-behavior-policy.md)、依存先の証拠は
[依存先契約](websocket-dependency-contracts.md)を正とし、ここへ詳細を複製しない。
各項目の状態を明示し、未決の項目は推奨案を採用済みの契約として扱わない。

### 6.1 判断項目

| ID | 状態 | 判断・決めること | 影響する作業 |
|---|---|---|---|
| D1 | 方針決定 | 次段階は制御可能なmockだけで終えず、特定のHTTP/1 backend接続まで進める。対象backendはLean Std TCP/libuvとし、HTTP/2はこの段階の対象外とする | mockとadapterの設計、完了条件 |
| D2 | 契約案を整理・確認待ち | 終了理由ごとの回収主体は、開始済み処理を所有するsession ownerと、最終的なTransport後始末を行うHTTP connection/serverに分ける。各経路の対応案は6.2節 | mockの終了イベントとrelease条件 |
| D3 | 意味論案を整理・実装適合確認待ち | 利用者から見た送信の直列化とclose競合時の結果を定義する。直列化の実装方式は内部事項だが、現行実装・Transportと両立するか確認する。整理案は6.3節 | 実行器のイベント・Effect・台帳 |
| D4 | 制約を決定 | 上限値は大規模実験から最適値を求めず、既存実装の制限・既定値から妥当な初期値を見積もる。値は運用実績が得られれば見直す。send受理・取消・結果の詳細契約は引き続き決める | 要求キュー、通知方式、容量テスト |
| D5 | 制約を決定 | libuvとLean Std TCPで実装可能な能力だけを使う。特に、根拠のない強制中断や期限内回収は約束しない | timeout経路、abort・回収テスト、終了保証 |
| D6 | 方針決定 | 既存`WebSocket.close`の意味を変えない。変更を再検討するのは、現行のままでは満たせない具体的な反例が示された場合に限る | 公開APIと互換性の検証 |
| D7 | TBD | 次段階の合格条件は未定。対象backendの能力を確認した後、必要な不変条件・正常系履歴・検査範囲を定める | モデル完了判定と実Transport接続への移行 |

### 6.2 D2の整理: 終了理由ごとの回収責任

現行コードでは、`serveUpgradableConnection` が接続処理を所有し、HTTPループ後にrequest/response bodyを閉じ、
upgrade継続の終了後に `Transport.close` を呼ぶ。サーバーshutdown時もTransport.close後に継続完了を待つ。
一方、WebSocketは単独のsession ownerやsend queueを持たず、継続が作った子タスクもHTTP側では追跡しない。
したがって下表は、現状の保証と次段階の責任分担案を分けて示す。

| 終了理由 | 現行で起きること・制約 | 次段階での責任案 |
|---|---|---|
| handler/upgrade継続が正常return | HTTP接続処理が継続完了を観測し、最後にTransport.close。WebSocketの未追跡子タスクは残り得る | 継続がsession ownerをスコープ内に保持し、return前に新規受付を止め、開始済みI/Oとsession資源を回収する。HTTP connectionがbodyとTransportの後始末を行う |
| アプリがローカルclose | `WebSocket.close` がClose frameを一度送る。アプリがrecvを続けるか継続をreturnする。sendとの直列化・残存I/O回収はない | session ownerが受付を失効し、合意したgraceful方針で既受理要求とCloseを処理する。書込失敗を成功に偽装せず、継続終了時はHTTP側へ所有sessionを返す |
| ピアClose受信 | recvがCloseを検証し、closeSentを立てて応答を送る。応答失敗は握りつぶされ得る | session ownerが未着手データを取消し、応答writeの完了・失敗まで追跡する。結果確定後にsession終了をHTTP connectionへ返す |
| プロトコル違反・recv/write例外 | protocol errorではClose送信を試みるが失敗を握りつぶして例外。upgrade継続例外はonFailureへ通知され、その後HTTP側がTransport.close | protocol/transport結果をsession ownerが終端結果として確定し、未着手要求を失敗または取消にする。開始済み操作のcallbackと保持を回収し、最後にHTTP connectionがTransportを後始末する |
| 相手のEOF | recvはClose handshakeなしのEOFも`none`として返す。ハンドラがreturnすればHTTP側でTransport.close | EOFを正常Close交換と混同せず異常終了としてownerに渡す。未完了sendの失敗を確定し、session後始末後にHTTP側へ戻す |
| サーバーshutdown/cancellation | connectionContextを選択した後、HTTP側がTransport.closeを呼んで継続完了を待つ。標準TCPのTransport.closeはno-opで、pending recvを確実に解除するとは限らない | HTTP connectionがshutdown理由をsession ownerへ通知し、ownerは新規受付を止めて回収可能な操作を処理する。libuv/Std TCPで完了を強制できないI/Oは保持責務を残し、静止・解放済みと報告しない。継続完了を待つ最終責任はHTTP connectionに残す |
| HTTP通常経路のEOF/例外/timeout/shutdown | HTTP接続ループがbody streamを閉じ、接続処理後にTransport.close。通常request/responseにWebSocket sessionはない | body streamはHTTP connectionが閉じる。Transportの意味はupgrade経路と同じ契約表で扱い、WebSocket固有のsession処理を持ち込まない |

この案では「誰が回収するか」は理由そのものから抽象的に割り当てるのではなく、
**session操作を始めて保持しているownerがsessionのI/O・要求を回収し、HTTP connectionがhandler/body/Transportの境界を閉じる**
という既存の所有階層から導く。Transport.closeがno-opであるbackendでは、それを強制中断や完了通知として使えない。
従ってD2の責任分担は整理できたが、実装適合とshutdown時の保留recvの扱いはbackend接続時に検証が必要である。

### 6.3 D3の整理: 利用者に見える直列化と実装適合

D3の本質はlockや台帳ではなく、**同じWebSocket上の送信操作が利用者からどう見えるか**である。
実装にlock、owner、queueのどれを使うかは利用者には関係しない。一方、その方式が既存の
WebSocketコードとTransportの完了・順序・寿命の契約に適合するかは実装側で検証が必要である。
現行実装に直列化モデルがないまま新しい意味論を導入すると、今まで利用者が暗黙に頼っていた挙動と
食い違い、驚きや新たな競合を生む可能性がある。

特に確認すべきなのは、並行send同士の順序をどこまで保証するか、closeとの競合でsendが成功・失敗の
どちらになるか、closeの復帰と個別send結果の前後関係である。既存実装にその順序モデルがない以上、
内部の直列化を追加するだけでは利用者向け契約が自動的に定まるわけではない。

#### 利用者向け意味論の整理案（確認待ち）

利用者向け契約案は、outbound frameが一つの論理的な送信列に並び、frame同士のbyteが混ざらず、
Close frameより後にdata frameが送られないこと。`await send(A); close()`ならAのwrite結果を先に観測する。
sendとcloseを並行に開始した場合は、呼出しの壁時計順ではなく直列化された送信列の順序で結果が決まる。
close前に送信列へ入ったsendは送信を試みるが、closeの復帰後に失敗が判明・通知されることがある。
sendやcloseの成功はpeerの受信・アプリ処理を保証せず、失敗を無視する利用者がいても、
ライブラリは失敗を成功として報告しない。

利用者に説明すべきなのはこの観測可能な動作であり、内部の受理点・lock・owner・queueではない。
並行呼出のどれが先になるかをwall-clock上の開始順で保証しないことも、必要ならAPI文書に示す。

実装側では、利用者の操作からbackend完了までを混同しない。
たとえばsendには、少なくとも次の段階がある。

1. 利用者がsendを呼び出す。
2. send要求がownerへ届く（キュー待ちを含む）。
3. ownerが要求を受理し、順序と結果を管理する責任を引き受ける。
4. ownerがwriteを開始し、backend/libuvへ登録する。
5. backendからwrite完了または失敗が通知される。

現行`sendDataFrame`はcloseSentを確認した後に直接 `io.send` を呼ぶ。確認とwriteは原子的でなく、
send queue・要求ID・結果台帳もない。したがって「send関数を呼び出した時点」を受理点にすると、
closeとの競合や呼出側の待機キャンセルに対する順序を定義できない。また、libuvに登録したwriteは
完了callback前にbufferを解放できず、`uv_cancel`で一般的なTCP writeを中断できるとも仮定できない。
実際、closeSentの読み取りとsendCloseOnceの原子的な更新は一つの同期区間ではないため、
既存評価ではclose frame後にdata frameが出る競合を記録している。

| 実装上の段階 | 競合・互換性への注意 |
|---|---|
| API呼出 | 非同期処理の実行・スケジュール順は呼出しの壁時計順とは限らない。開始時刻をそのまま競合順にする保証はない |
| 直列化 | 利用者に見える送信列の順序を実装する箇所。ownerかlockか等は内部選択だが、現行コードにはsend/close間の直列化がない |
| queue・台帳 | 直列化後の要求・結果・保持義務を記録する仕組み。記録自体が利用者向け順序を作るわけではない |
| backend write登録 | 登録順に依存する送信順とbuffer寿命を確認する。登録後はcallbackまでbuffer保持が必要。任意Transportに同じ保証があるとは限らない |
| write完了 | 個別sendの成功・失敗を決める。write成功はpeerの受信確認ではなく、受理やcloseの意味とも別である |

closeSentの読み取りとsendCloseOnceの原子的な更新は一つの同期区間ではないため、既存評価では
close frame後にdata frameが出る競合を記録している。libuvに登録したwriteは完了callback前にbufferを
解放できず、`uv_cancel`で一般的なTCP writeを中断できるとも仮定できない。

実装側では、利用者から見える直列化順をどこで確定するかと、その結果をqueue・台帳へ記録することを分ける。
ownerのmailbox順序かlockかは内部選択である。単独のatomic flag更新と後続の台帳appendだけでは、
複合したsend/close判断に割り込みが生じ得る。
受理とwrite成功も別である。close前に送信列へ受理した要求は送信を試みるが、write失敗ならsend失敗として記録し、
close自身の成功で覆い隠さない。backend登録後のwriteはcallbackまで保持し、timeoutやshutdownを理由に
完了したことにしない。これによりclose後の失敗通知は許容しつつ、結果の帰属とbuffer保持を保つ。

実装上どの制御I/Oを同じ送信列へ含めるか、queue投入時の待機／拒否、
送信失敗を既存`Async`呼出へどう対応付けるかは実装側の未決事項である。
これらは利用者向け意味論を確認した後、既存実装・Transportとの適合性に基づいて決める。

現時点の方針として、closeの呼出し・復帰後に、先行するsendの失敗が判明・通知されることを許容する。
graceful closeで受理済みsendの排出を試みても、それは送信成功の保証ではない。
失敗したsendを成功扱いにせず結果として保持・通知する必要はあるが、ライブラリは
利用者がその通知を実際に待ち、処理したことまでは保証できない。現行APIでもsendは`Async`の失敗となり得る。
ただし、close前の受理をAPI利用者がいつ観測できるか、受理前のsendをclose後にどう拒否するか、
失敗結果をどう確定・保持するかは未決である。

これらの互換性と驚きのリスクを明記したうえで、意味論案をmock実行器の履歴へ落とし込む。

### 6.3 依存順の進め方

- [ ] **対象backendの契約を確認する (D1, D5)**: Lean Std TCP/libuvで実装できる終了・中断能力を
  依存先契約と照合する。能力がない操作を仮定やsuccess-shaped fallbackで補わない。
- [x] **終了責任の初回照合を記録する (D2)**: 6.2節の理由別対応をベースにし、backend接続で実証・修正する。
- [ ] **send/closeの利用者向け意味論を確認する (D3, D4)**: 直列化された送信列、close前後のsendの結果、
  並行操作時に保証しない順序を合意する。実装方式は既存コード・Transportとの適合を検証して選び、
  既存実装から容量上限を見積もる。
- [ ] **mock実行器を作る**: Effectを実行するdriverの履歴をモデルに対応付け、
  遅延・逆順完了、登録失敗、待機者消失、期限・取消、制御I/Oを決定的に再現する。
  全到達状態の不変条件と必要な正常履歴を検査する。D7の合格条件はこの結果を見て定める。
- [ ] **HTTP/1 backendへ接続する**: mockの履歴とlibuvの実際の完了・失敗経路を照合する。
  通常HTTPとupgrade双方の終了責任を確認し、HTTP/2はこの段階の合格に含めない。
- [ ] **closeの反例を記録する (必要な場合のみ)**: 既存closeを変えないと具体的な要件を満たせない
  履歴が見つかった場合、その最小反例と代替案を示してからD6を再検討する。

各チェック項目は、判断と根拠を所定の記録先へ反映し、対応するテストまたは未保証事項を
示してから完了にする。判断が実行可能性を変えた場合は、後続項目を確定する前に本台帳へ戻る。
判断の履歴を残す必要がある場合は「決定」「根拠」「影響する項目」「検証」を記録し、
古い案を合意済みの契約として残さない。
