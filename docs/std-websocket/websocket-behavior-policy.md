# WebSocketの動作方針: 利用者の期待・既存慣習・実装可能性

所属: [Std拡張WebSocket開発](./README.md)。動作契約の合意・保留事項の参照先。

2026-11-02調査。モデル構成は**B（直積状態・操作台帳）+ Cの最小の保持不変条件を採用方針**
とする。動作方針のうち、正常closeでの受理済みデータ排出、
ピアClose・障害・abortでの未着手取消、取消・期限とI/O停止・回収完了の区別は合意済み。
**公開APIの分離は保留**とし、既存HTTPインターフェースとの整合を先に確認する。
詳細な結果型・期限等は未確定。[純粋モデルの限定的試作](websocket-prototype-results.md)は
実施済みだが、実行器・実Transport接続と契約全体の証明は未完了である。

関連: [モデル比較](websocket-model-proposals.md)、
[寿命管理の設計](websocket-lifetime-design.md)、
[依存先契約](websocket-dependency-contracts.md)。

## 1. 判断の順序と調査の限界

1. RFC要件・安全性を守り、現在または合理的な範囲の変更で実装可能であることを必須条件とする。
   他ライブラリにある強制切断能力を、こちらにもあると仮定しない。
2. その範囲で、Lean本体のライブラリ（Init・Std）の契約・慣習を最も強く参考にする。
3. 不足する部分を、ws-leanと他言語の主要なWebSocket API・ライブラリで補う。
   ws-leanはこの段階と同程度の重みとし、Lean製・依存先であることを理由に上位へ置かない。
4. より限定的なライブラリは、代替設計と見落としの確認に用いる。

「Leanらしい」「一般的に期待される」をソース例だけから断定しない。
今回確認したLeanの標本はStdのチャネル・HTTP body・サーバー・Asyncと、
依存固定版ws-leanであり、Lean利用者全体の慣習調査ではない。
他言語の「主要」は比較対象の選定区分であり、ダウンロード数等による順位付けではない。
各文書・ソースは契約を示すが、利用者の期待を直接測定したものでもない。

**結論: 共通するのは終了と完了の区別の必要性であり、`close`という名前の意味は共通しない。**
APIの呼出形態、所有権、I/O駆動方式を揃えて比較する必要がある。

## 2. 最優先の参照: Lean本体のライブラリ

### 2.1 Std（Lean 4.35.0）

| 対象 | 確認した契約 | この設計への示唆 |
|---|---|---|
| `CloseableChannel.close` | 新規送信禁止。既にバッファにある値は受信できる。再closeはエラー [L1] | 失効と既存データの排出は両立する。ただし全種のcloseの冪等性は導けない |
| `CloseableChannel.send` | 容量により待機し、closeとの競合ではエラーになり得る [L1] | キュー投入待ちと受理済み要求を区別し、終了時に待機者を解決する |
| HTTP `Body.Stream.recv` / `closeWithError` | バッファ済みchunkを先に渡し、終端でエラーを通知する [L2] | 正常EOFとエラーを区別し、受信済みデータを黙って捨てない方向 |
| `Server.shutdown` / `waitShutdown` / `shutdownAndWait` | 要求、待機、その合成を分ける [L3] | WebSocketでも開始APIと完了APIを分ける先例になる |
| `ContextAsync` | 明示的な確認を必要とする協調キャンセル [L4] | 呼出側の取消でnative I/Oまで停止したと見なさない |
| `Async.race` | 敗者の処理を自動では取り消さない [L5] | 期限待ちに勝っただけでI/O停止・回収済みにしない |

チャネルの送信成功はチャネル転送の契約であり、ネットワーク送信成功ではない。
また、サーバーのwaitは管理対象処理の終了待ちであり、全FDのnative close callback完了を
証明するものではない。参考にするのは**責務を分けた形**であって、保証範囲の無条件な移植ではない。

## 3. 補完的な参照: ws-leanと他言語

### 3.1 ws-leanと現API

依存固定版ws-lean [L6]には、次の具体例がある。

- `closeWithCancellation` はclose受付前の取消を扱う。状態遷移後のCloseは
  接続側の責任となり、呼出側が観測をやめても撤回しない（ソースの契約コメント）。
- `close` は要求開始だけでなく `wait` を待つ。`requestAbort` は別の操作。
- send要求がwriter側へ移った後は、その実行・結果確定をwriter側が所有する。
- writerはCloseを制御キューで扱い、close開始後の未着手データは拒否する。
  したがって、ローカルclose時に受理済みデータを常に排出する先例ではない。

これは具体的な参照例だが、**コンベンションの根拠としては他言語の主要実装と同程度**
に扱い、Lean本体の慣習より優先しない。
依存先としての実際の能力・制約の調査は引き続き必要だが、
その技術的事実と、利用者向け慣習としての優先度は別である。
特に、そのretirementや期限の実装が今回目標とする静止完了契約を満たすかは、
API名やコメントでは確認できず、別の適合検証が必要である。

一方、現在の本拡張の `WebSocket.close` はCloseの送信開始側で、
利用者が `recv` を続ける契約である [L7]。
同じ `Async Unit` のまま「全I/O静止まで待つ」へ変更すると、
既存利用者には大きな意味変更になる。
**Leanの先例同士でもcloseの意味は揃っていない**ため、互換性と名前の説明が必要である。

### 3.2 他言語の主要な参照

| 対象 | closeと完了待ち | 送信・取消等の契約 | 注意点 |
|---|---|---|---|
| ブラウザWebSocket標準 [W1] | `close()` は開始して戻り、後でcloseイベント | 以前にsendしたメッセージを捨てず、送出後にhandshakeを開始する | 非同期の送信キューがAPIの一部。sendの戻りは配送確認ではない |
| Node.js ws [W2] | `close()` は開始、closeイベントで終了観測。`terminate()` は別 | send callbackは書込完了・エラーを通知。8.18.3のsenderは処理中ならCloseもキューへ入れる [W3] | TCP破棄能力を持つ。こちらのStd TCPと能力が違う |
| Python websockets asyncio [W4] | `await close()` はhandshakeとTCP終了を待つ。冪等。`wait_closed()` もある | 通常recvの取消はデータ喪失なし。sendの取消は非推奨で、closeを推奨 | 分割受信は途中取消すると接続を再利用できない。全recv一般への保証ではない |
| Go Gorilla [W5] | `Conn.Close()` はCloseフレームを送らず下位接続を閉じる | reader一つ・writer一つの並行性はアプリ側責任。CloseとWriteControlは別途並行可 | `Close`という名前だけではgracefulを意味しない |
| Rust tungstenite [W6] | `close()` はCloseをキューへ入れ、その後read/flushで終了を駆動 | writeとflushを分離。バッファ満杯はメッセージ付きエラー。送受信Close後は通常write不可 | 自律的ownerが常に駆動するAPIではない |

browserとwsは「呼ぶと開始」、Pythonは「awaitすると終了待ち」、
Gorillaは「下位切断」、tungsteniteは「終了を駆動する準備」である。
これらを多数決して一つのcloseへ押し込めるのは適切でない。
特にPythonのclose待機契約から、他ライブラリでも未着手sendを必ず排出すると推論しない。

### 3.3 補助例: より限定的なAPI

Rust sokettoのSenderはsend、flush、closeを区別し、closeの説明はClose送信と接続終了 [W7]。
分割された送受信APIも自然な形の一つと分かるが、公開説明だけから、
任意の取消の安全性、全資源の回収期限、共有HTTP/2接続の保持契約までは導けない。
この例を主要API・Leanの先例より優先する理由は、今回の調査ではない。

### 3.4 比較から推定できる期待と、できない期待

**根拠が比較的強い期待**

- 正常終了要求と異常中断を区別できること。
- 新しいsendを受け付けなくなる境界があり、終了後の利用を正常送信に偽装しないこと。
- 既に送信済みのデータを後から取り消せるとは約束しないこと。
- sendのローカルな完了と、ピア受信・アプリ処理・永続化の完了を区別すること。
- バッファ、同時操作、終了待ちの責任が明記されること。

**単一の慣習として採用できない期待**

- closeの戻りが静止完了を意味すること。
- 任意の保留sendを、接続を維持したまま安全に取り消せること。
- 全closeが冪等、または全closeが再実行エラーになること。
- closeに期限を設ければ、下位I/O・メモリもその期限内に必ず回収されること。
- アプリ未受領のバッファを正常終了・異常終了とも必ず同じ方法で扱うこと。

## 4. このライブラリへの動作方針の推奨

以下は合意済みの原則を具体化する案である。公開APIの分離・名前は未決定で、
本書自体は契約案であり、公開API・既存動作は変更していない。
HTTPとの整合条件は第4.5節と第4.6節を優先する。

| 論点 | 推奨案 | 根拠と実装上の条件 |
|---|---|---|
| ローカルのgraceful close | 受理を失効し、受理済みの有限なデータ列を順に排出してからClose | Stdチャネルとbrowserの期待に近い。件数・バイト上限と期限が必要。ws-leanの取消方針とは異なる |
| ピアClose・致命的障害・abort | 未着手データを取消。開始済みI/Oは追跡を続ける | ローカルcloseの排出契約とは別。ピアClose応答や障害処理をキュー排出の後へ回さない |
| 開始の観測 | 受付失効の確定をClose書込成功・静止完了と区別する | `requestClose` 等を公開するかは保留。内部状態の区別は維持する |
| 完了の観測 | セッションの静止と終了結果を確認する | `waitClosed` 等を公開するかは保留。サーバーの管理スコープから回収責務を外さない |
| 合成API | `closeAndWait` 相当も選択肢 | Stdの先例はあるが、API追加の決定ではない。既存closeとの互換性を先に確認 |
| 重複close | 最初の有効なローカル要求の理由を採用し、終了結果を共有する | browser・Python・ws-leanに近い。後続の正常closeでエラーやabortを上書きしない |
| sendの成功 | 対象データのbackend書込が契約上完了した時点 | キュー投入成功をsend成功としない。書込成功もピアの受信確認ではない |
| sendの取消 | 受理前は取消可能。受理後は原則として要求をownerへ引き渡す | Stdの協調キャンセル・raceの契約を踏まえて操作と待機を分離する。ws-lean・Pythonは補助的な先例。結果待機の取消を送信の撤回としない |
| 期限 | 期限到来を明示し、能力があればabortを要求する | abort要求だけで静止完了にしない。能力不足なら回収未確認を成功として返さない |
| 受信済みデータ | 完成済み・バッファ済みメッセージは順に配送し、最後に正常終端またはエラーを示す | Std HTTP bodyに近い。不完全メッセージを正常データとして配送しない |
| 背圧 | 有界の受付待ちと受理前取消。終了制御はデータ容量と分離 | Stdチャネルを参考にする。大量の待機呼出が保持する入力まで自動的に総量制限されるわけではない |

graceful closeで受理済みsendを順に排出する方針は、個々のsendの成功を保証するものではない。
closeの呼出し・復帰後に、先行するsendの書込失敗が判明・通知されることは許容する。
失敗を成功として扱わず、結果を通知する責任と、利用者が通知を待って処理する責任は別である。
ライブラリは後者を強制できない。既存の`close`の戻りをsend結果すべての完了待ちへ変更することもしない。

Lean本体を最優先とし、ws-leanは他言語の主要実装と同程度の補完資料として扱う。
Stdの責務分離・残存データの扱いをまず参照し、WebSocket固有の未決部分を他言語で補った。
とりわけ排出方針はLeanの統一慣習としての結論ではなく、
Stdの類例とbrowserの明確な契約を重視した提案である。
実行器の検証でこの契約が過大と分かった場合は、取消型のcloseを明示的に設計する方が、
排出を約束しながら実際には捨てるよりよい。

### 4.1 「受理済み」の境界は利用者に説明する

ownerが要求を台帳へ記録した点を受理点とする。
キュー投入待ちや、投入済みだがowner未受理の要求までgraceful排出を保証しない。
shutdownをデータキュー外で通知する場合、その通知が未受理sendを追い越す可能性も明記する。
並行呼出の壁時計上の先後ではなく、ownerが確定した順序に従う。

利用者が `await send(A); requestClose()` とすれば、Aの書込完了を先に観測する。
sendとcloseを並行起動した場合は、sendが失効前に受理されたかで結果が決まる。
成功を観測していないsendについて、呼出開始時刻だけから配送保証を推測させない。
必要なら受理と完了を分けたticket APIを検討できるが、初版から導入を必須とはしない。

### 4.2 gracefulとabortを分ける理由

gracefulは可能な範囲で既存の仕事を維持し、abortは終了を優先する。
close要求時に理由なく既存sendを捨てるのも、shutdownが巨大な送信待ちに無期限に塞がれるのも、
使い手にとって悪い驚きになり得る。
したがって「有限な受理済み列の排出 + 期限到来の明示 + 能力に応じた異常中断」を推奨する。
期限はClose書込後だけでなく、ローカルclose受理からの排出待ちも対象にする方向とする。
相手の停止・ピアClose・エラーにより排出できない場合、該当sendは失敗し得る。

開始済みフレームのbyte列へCloseを割り込ませない。
部分送信で失敗したデータを、別の正常sendとして勝手に再送しない。
分割メッセージ対応時には、残りのfragmentを送る条件も追加の契約にする。

### 4.3 取消は「待機」と「操作」に別の意味を持つ

受理前の取消なら、要求からI/Oを開始しないことを保証対象にできる。
受理後に呼出側が結果の待機をやめても、送信が起こらなかったとは保証しない。
この場合は「未送信と確定」ではなく「呼出側では結果未観測」と説明する。
ownerは結果とI/Oを回収し、呼出側が消えても保持資源を放棄しない。
接続全体のabortなら、未着手要求を取消結果へ確定できるが、開始済みI/Oの保持義務は残る。

通常recvの待機取消で次のメッセージを失わない契約は、Pythonの実例からも有用である。
ただしチャネルから値を取り出した直後の待機取消まで含めた対応が必要なので、
実行器・配送方式を検証するまでは保証しない。native recvの停止とは分けて実装する。

### 4.4 受信バッファと制御フレーム

受信済みデータを終了結果より先に配送する場合でも、利用者が読むまでowner終了を止めない。
管理された有界の結果バッファへ所有を移せるなら、セッションのI/O静止と両立する。
そのバッファが残ることを「全メモリ解放済み」とは表示しない。
明示的な破棄が必要なら、通常のcloseへ黙って混ぜず、別の利用契約にする。

新しいアプリ由来pingはclose受理後に拒否する方向。
RFC 6455 §5.5.2のPingへの応答義務はClose受信前に残る [W8]。
ローカルclose受理だけで自動pongを一律に止めず、ownerの直列化経路で処理する。
制御フレームも飽和・無制限蓄積を起こさない設計が必要で、
データを止めたから制御用の資源管理が不要になるわけではない。

### 4.5 HTTPとの整合: 状態の分離と公開APIの分離は別

終了要求と静止完了を**モデル内部で区別することは必要**だが、
利用者に二つの公開APIを必ず使わせる必要はない。
先の提案はこの二点を近づけ過ぎていた。公開方法は以下の三層で判断する。

| 層 | 既存インターフェース | 整合させる条件 |
|---|---|---|
| HTTPサーバー全体 | `shutdown` / `waitShutdown` / `shutdownAndWait` [L3] | 既に要求と管理対象の終了待ちを分けている。WebSocket利用時にも既存のサーバー終了手順を使えるようにする |
| HTTP接続・upgrade継続 | `serveUpgradable` は同じ `Server` を返す。継続は `Async Unit` [L8][L9] | アプリに接続ごとの追加waitを義務付けず、接続側がセッションownerの終了を回収する |
| 下位Transport | `close : α → IO Unit`。標準TCPではno-op [L10] | 静止待機APIと同一視せず、シグネチャを変えて全Transportへ能力を要求しない |

現在の `performUpgrade` は継続を待ち、キャンセル時には `Transport.close` を呼んでから
継続を待つ。しかし継続が生成した任意の子タスクは追跡せず、標準TCPのcloseはno-opである。
従って、**既存の所有の形は再利用できるが、そのままで静止完了が保証されるわけではない**。

今後の統合案は、WebSocketの管理スコープが終了時に受付を失効し、ownerとI/Oを回収してから
HTTP接続の管理処理を完了させること。継続の正常return・例外・サーバーキャンセルを
この後始末へ集約する。これは未実装であり、キャンセル伝播と中断能力の検証が必要である。
ownerを未追跡の独立タスクとして残したまま継続だけを完了させない。
そうすれば、利用者の既存の `shutdownAndWait` を迂回する別の必須終了手順を作らずに済む。
同APIの保証を全FDの物理解放完了へ黙って拡張することもしない。

当面、既存のWebSocket `close` を静止待ちへ黙って変更せず、
「終了処理を開始する」意味を保つ方向を優先して検討する。
ただし戻りがClose書込完了か受付失効かは互換性上の別論点であり、勝手に弱めない。
現APIは利用者がrecvを続けるので、closeがピア応答まで待つようになると、
同じタスクの後続recvへ進めず停止する可能性がある。
新ownerが受信を駆動する場合でも、終了後の受信データ配送との整合を確認する。

公開の完了待機は、個別セッションの終了観測に必要なら追加を検討する補助機能に留める。
安全な回収の責任を「利用者がwaitを呼んだ場合だけ」にしない。
HTTP/2ではこのスコープは当該ストリームに限り、共有接続の終了と混ぜない。

### 4.6 Transport・connectionも含む終了契約の整合

サーバー全体の待機APIに合わせるだけでは不十分である。
**通常HTTPとupgrade後で、同じTransportのcloseを別の意味に解釈したり、
connection終了後の保留I/Oの責任を片方だけ宙に浮かせたりしないこと**を設計条件にする。
「既存シグネチャを変えない」は必要な互換性検討の一部であって、整合性の証明ではない。

| 層 | 現在確認できる終了の意味 | 揃えるべき点 |
|---|---|---|
| HTTP/1プロトコル機械 | メッセージ処理・出力を終え、haltする | haltをnative I/O静止・FD解放と同一視しない |
| HTTP/1接続ドライバー | body streamを閉じ、`Transport.close` を呼んで処理を終える [L11] | 通常HTTP・upgradeの両経路で、保留処理の所有者と後始末の責任を明示する |
| HTTP Transport | `close` はbackend固有の後始末。標準TCPではno-op [L10] | 同じ呼出からWebSocket側だけ「全I/O中断・回収完了」を導かない |
| TCP | `shutdown` はwrite側の半閉鎖 [L12] | read停止・全方向切断・finalizer完了に読み替えない |
| HTTP/2 Tunnel | `closeSend` はEND_STREAM、`cancel` はRST_STREAM、`wait` は両半分の終了または終端障害 [L13] | 当該streamの終了と、接続共有資源・callbackの静止を分ける |
| WebSocket | Close交換はアプリケーションプロトコルの終了手順 | Close交換後の下位終了をownerへ引き継ぎ、下位の保証を勝手に強めない |

ここで求める整合は、全層のcloseを同じ操作にすることではない。
正常終了、送信方向終了、異常中断、I/O静止、所有資源解放のそれぞれについて、
**上位の要求が下位のどの操作に対応し、その完了で何が成立するか**を一貫させることである。
HTTP/1の再利用終了とWebSocketのClose交換に固有の手順があること自体は不整合ではない。

従って、WebSocket専用の強い終了完了APIを先に設計して、
最後に既存 `Transport.close` へ押し込む進め方は採らない。
先に以下を接続終了契約として確認する。

1. 通常HTTPとupgradeについて、開始し得るI/O・管理対象タスク・保持資源と終了責任を列挙する。
2. EOF、正常完了、例外、キャンセル、期限切れごとに、
   新規I/O停止・保留操作回収・Transport後始末の順序と実行主体を対応付ける。
3. 追加能力が必要なら、通常HTTPにも適用可能な接続終了能力またはadapterの契約として
   定義できるかを検討する。全Transportへの一律追加やStd本体の変更を決定したわけではない。
4. 強い契約を満たせない既存backendは明示的に区別する。
   no-op closeを強制切断に見せるfallbackを作らず、共通の未保証範囲として扱う。
5. 通常HTTPの既存動作を維持するか、共通部分を変更する必要があるかを判断してから、
   WebSocket公開APIと静止完了の定理の前提を確定する。

現時点では通常HTTPの終了を欠陥と断定せず、その限定的な契約とWebSocketで増える並行性を
区別する。一方、「HTTPの方も強い保証がないからよい」として寿命問題を残す理由にもしない。
共通の契約を満たすか、追加要件と能力差を明示できることが、実行器の設計確定の条件である。

## 5. 合理的に実装できる範囲の線引き

| 能力・性質 | 現時点の扱い |
|---|---|
| 失効、受理順序、未着手要求の取消、結果の高々一度確定 | Bの純粋モデルで定式化する対象 |
| 開始済みI/Oと保持義務の追跡 | B + Cの不変条件。実参照保持との対応検証が必要 |
| 受理済み列をgraceful排出する方針 | 有界キュー・送信順管理でモデル化可能。開始登録との対応は未検証 |
| 終了要求・静止完了の区別 | 内部モデルでは必須。公開API分離は保留し、HTTPの所有・待機スコープと統合する |
| recv/sendの待機中も終了制御を進める実行器 | 必須。非同期登録と完了追跡の実現方法を次に検証 |
| TCP writeの強制中断、期限内の確実な静止 | 現行Std TCPでは根拠不足。提供可能と表示しない |
| HTTP/2のstream abortと完了待ち | Tunnel APIは参考になるが、実装適合確認前には保証しない |

期限切れの結果と静止完了は、公開APIの数によらず型・説明で区別する。
静止を確認できなければownerの回収責務は残り、サーバーの終了待ちが遅れる可能性も残る。
観測用の時間制限を設けても、その後の処理を未管理タスクへ捨てない。
この不足を解決するためのbackend変更が大きすぎる場合は、
保証を狭めたAPIを選ぶか、当該保証を必要とする提供自体を延期する。

## 6. 次に合意する範囲

本書で合意済みなのはモデル構成、参照の優先順位、冒頭の三つの動作原則である。
次はTransport・connectionを含む終了契約の対応、第4節の残る詳細、既存closeの互換性、
期限・結果型を合意してから、
純粋モデルのEvent・Effect・台帳の型を作る。
タイムアウト値やキュー上限は他ライブラリの既定値をそのまま輸入せず、
対象用途・保持量・backend能力から決める。

S2「Close開始後はデータ開始なし」は維持するが、
ローカルcloseで排出するなら「close受理後は一切データ開始なし」は定理にしない。
S3は「失効後に到着したsendは新規受理せず、それを原因とするI/Oなし」とし、
失効前に受理した有限列の排出とは両立させる。
期限切れや取消結果だけでS6の静止完了へ到達させない。

## 参照

すべて2026-11-02参照。Std・ws-leanとwsソースは固定版。
stable/latestおよびWeb標準は更新され得る公開契約であり、固定版の適合証明ではない。
今回新たなライブラリの実行テストはしていない。

- [L1] [Lean 4.35.0: CloseableChannel（new/send/close/recv）](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Sync/Channel.lean#L660)
- [L2] [Lean 4.35.0: HTTP Body.Stream（recv/closeWithError）](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Data/Body/Stream.lean#L299)
- [L3] [Lean 4.35.0: Server.shutdown/waitShutdown/shutdownAndWait](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server.lean#L94)
- [L4] [Lean 4.35.0: ContextAsync](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/ContextAsync.lean#L15)
- [L5] [Lean 4.35.0: Async.race](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/Basic.lean#L940)
- [L6] [ws-lean固定版: Connection](https://github.com/pb64-lean/ws-lean/blob/2a6665a120993533122bcbfa076ef35c17025bea/Ws/Connection.lean)（submitDataOpenIO: 279行、submitClose: 390行、writerLoop: 584行、close/wait: 1377行以降）
- [L7] [本拡張: Connection](../../StdExt/Http/WebSocket/Connection.lean)
- [L8] [本拡張: serveUpgradable](../../StdExt/Http/Server/Serve.lean)
- [L9] [本拡張: upgrade継続の型](../../StdExt/Http/Server/Upgrade.lean)、[performUpgradeと接続終了処理](../../StdExt/Http/Server/Connection.lean)
- [L10] [Lean 4.35.0: Transport.close](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Transport.lean#L45)
- [L11] [Lean 4.35.0: HTTP接続の終了処理](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Http/Server/Connection.lean#L530)
- [L12] [Lean 4.35.0: TCP.Client.shutdown](https://github.com/leanprover/lean4/blob/v4.35.0/src/Std/Async/TCP.lean#L220)
- [L13] [http2-lean固定版: ExtendedConnect.Tunnel](https://github.com/pb64-lean/http2-lean/blob/82fc066025f3e5fdec54c836f4e9659c2f8176ab/lean/Http2/ExtendedConnect.lean#L30)
- [W1] [WHATWG WebSockets: close](https://websockets.spec.whatwg.org/#dom-websocket-close)
- [W2] [Node.js ws: API](https://github.com/websockets/ws/blob/master/doc/ws.md)
- [W3] [ws 8.18.3: WebSocket](https://github.com/websockets/ws/blob/8.18.3/lib/websocket.js)、[Sender.close](https://github.com/websockets/ws/blob/8.18.3/lib/sender.js)
- [W4] [Python websockets: asyncio ClientConnection](https://websockets.readthedocs.io/en/stable/reference/asyncio/client.html#websockets.asyncio.client.ClientConnection)
- [W5] [Gorilla websocket: Conn.CloseとConcurrency](https://pkg.go.dev/github.com/gorilla/websocket)
- [W6] [tungstenite: WebSocket read/write/flush/close](https://docs.rs/tungstenite/latest/tungstenite/protocol/struct.WebSocket.html)
- [W7] [soketto: Sender](https://docs.rs/soketto/latest/soketto/connection/struct.Sender.html)
- [W8] [RFC 6455 §5.5.2: Ping](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.5.2)
