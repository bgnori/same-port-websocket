# Std拡張WebSocketの開発

[二つの取り組みの入口](../README.md) / [派生元のアプリStudy](../application-study/README.md)

## 目的

Lean本体のHTTP・Transport・connectionの慣習と整合し、
使い手に接続移譲・終了管理の不自然な負担を漏らさないWebSocketを、
Std拡張として実装・検証する。

派生元は[アプリ実装から得た問題](../application-study/websocket-risk-return-report.md)。
同一ポートで動けば十分ではなく、並行操作・寿命・下位資源の契約まで扱う。

## 現状を一枚で

2026-11-03時点。これは本トラックの進捗要約であり、保証の詳細は下記の専門文書を参照。

| 区分 | 状態 |
|---|---|
| 現行実装 | StdExtのHTTP/1 upgrade、WebSocketフレーム・メッセージAPI、echo実証がある |
| 修正・検証済み | Close理由のUTF-8切断を修正。既存のLean・通信テストの検証記録がある |
| 採用した設計 | 単一owner、Bの直積状態・操作台帳 + Cの最小保持不変条件 |
| 合意した動作原則 | 正常closeは受理済み列を排出。ピアClose・障害・abortは未着手取消。取消・期限をI/O停止・回収完了と混同しない。終了責任の分担（D2）とsend/closeの利用者向け意味論（D3）は2026-11-03に承認済み |
| 純粋モデル試作 | 七つの局所補題（終端性・write排他の帰納的保存を含む）、30超の入力列、深さ5・20,020ノードの探索。`lake test`成功 |
| 段階B（2026-11-03） | 制御操作（abort・finishSend）を予約・登録・完了・保持の台帳へ拡張。D4初期値を決定。Effectだけを実行する決定的モック実行器が、登録失敗・完了順入替え・待機者消失・半閉鎖/取消待ちを再現し、27コマンド・深さ5・37,305ノードで実行器とモデルの対応を検査 |
| 段階C第1スライス（2026-11-03） | 純粋モデルを実`Std.Async`ランタイムとStd付属mock transportに接続。backend能力をLean Std TCP/libuvの実契約に限定（D1・D5）し、中断不能を成功へ変換しないことを確認。graceful close・write失敗・deadline＋保留readの3シナリオで、実行履歴がモデルへ再生一致 |
| 段階C第2スライス（2026-11-03） | 実TCP(loopback)で能力プローブを実測（依存先契約C8）: ピア半閉鎖で保留recvがEOF解決、素の`recv?`は中断不能で保持責務を維持、**selector化したreadはabortでピア協力なしに速やかに回収できbusyは恒久化しない**、graceful全経路が実TCPで完走し履歴がモデルへ再生一致 |
| まだ未接続 | 接続ループ(`serveUpgradableConnection`)への配線は未着手。既存公開APIは未変更 |
| 保留 | 公開終了API、接続ループ組み込み、HTTP/2接続、結果一意性・容量の帰納的保存証明、並行send向けの受理点実装 |
| 未保証 | native全体の安全性、無条件の有界資源回収、HTTP/2実装全体の適合 |

**段階B（モック実行器）・段階C第1スライス（mock transport接続）・第2スライス
（実TCP能力プローブと実TCPセッション）は2026-11-03に実装済み。結果は
[モック実行器の結果](./websocket-mock-executor-results.md)、
[実Async接続の結果](./websocket-async-executor-results.md)、
[依存先契約C8（実TCP実測）](./websocket-dependency-contracts.md)を参照。
shutdown時の保留recvの扱いは確認済み: gracefulはピア協力で自然に解決し、
素の`recv?`に中断能力はないため保持責務を残し静止扱いしないこと、
selector化したreadならabortがピア協力なしに速やかに回収しbusyが恒久化しないことを
実TCPで実証した。owner論理資源は即時解放・native資源はcallback後解放の二層を維持する。
次の作業は`serveUpgradableConnection`接続ループへの組み込み
（読み待ちのselector化を前提）と、
通常HTTPとupgradeへの同一終了契約の適用検証である。HTTP/2は別adapterとして後続。**

## 読む順序

普段はこの入口と、作業に対応する一文書だけを読む。

| 優先 | 文書 | 役割 |
|---|---|---|
| 1 | [試作結果とTransport接続条件](./websocket-prototype-results.md) | 何を試し、何が不足し、次に何を検証するか |
| 1 | [段階B: 台帳とモック実行器の結果](./websocket-mock-executor-results.md) | 制御操作台帳・実行器の検証結果と、段階Cまでの残義務 |
| 1 | [段階C第1スライス: 実Async接続の結果](./websocket-async-executor-results.md) | 実ランタイム＋mock transport接続、backend能力確認、残る配線作業 |
| 2 | [動作方針](./websocket-behavior-policy.md) | 合意・保留、利用者の期待、HTTP/Transport/connectionとの整合 |
| 必要時 | [現行API・使い方](./std-websocket-extension.md) | 今動いているコードの構成。将来設計とは別 |
| 設計根拠 | [終了・寿命管理](./websocket-lifetime-design.md) | 問題定義、目標定理、安全性と進行性 |
| 設計根拠 | [三つのモデル比較](./websocket-model-proposals.md) | B+Cを選んだ理由と代替案 |
| 依存先確認 | [依存先契約](./websocket-dependency-contracts.md) | Std・native・libuvの証拠、仮定、未保証範囲 |
| 経緯 | [初期実装評価](./websocket-evaluation.md) | 初期評価と追補。現在の全体状態の代用にはしない |

API・動作契約の合意は「動作方針」、検証結果は「試作結果」、
依存先の証拠は「依存先契約」に追記する。全資料へ同じ議論をコピーしない。
コンベンションは実装可能性を必須条件とし、Lean本体（Init・Std）を最優先、
ws-leanと他言語の主要実装を同程度の補完資料とする。

## 実装・検証への入口

- [StdExt](../../StdExt/)：現行upgrade・WebSocket実装と純粋モデル。
- [Lifecycle](../../StdExt/Http/WebSocket/Lifecycle.lean)：通信経路に未接続の試作。制御操作台帳と補題を含む。
- [MockExecutor](../../StdExt/Http/WebSocket/MockExecutor.lean)：Effectだけを実行する決定的モック実行器（段階B）。
- [AsyncExecutor](../../StdExt/Http/WebSocket/AsyncExecutor.lean)：実`Std.Async`でモデルを駆動するセッション（段階C第1スライス）。
- [LifecycleTests](../../LeanWebStudy/LifecycleTests.lean)：決定的なモデル入力と探索。
- [MockExecutorTests](../../LeanWebStudy/MockExecutorTests.lean)：実行器の決定的シナリオと対応関係の探索。
- [AsyncExecutorTests](../../LeanWebStudy/AsyncExecutorTests.lean)：mock transport上のセッションとモデル再生の検証。
- [TcpBackendTests](../../LeanWebStudy/TcpBackendTests.lean)：実TCPの能力プローブと実TCPセッション（段階C第2スライス）。
- [Leanテスト入口](../../LeanWebStudyTests.lean)：アプリのテストと実行単位を共有。
- [通信テスト](../../tests/test_ws_std.py)：現行echo経路の検証。純粋モデルの適合証明ではない。

```sh
lake build LeanWebStudy.LifecycleTests LeanWebStudy.MockExecutorTests LeanWebStudy.AsyncExecutorTests
lake test
```

通信テストの実行方法は[現行API文書](./std-websocket-extension.md)を参照。

## 将来の独立化とLean本家への提案

成功した場合は独立プロジェクト化し、Lean本家へのPRを目指す。
**独立化・PR作成・upstream受入れは、いずれも未実施**。
単にファイルを移せば本家へ採用される、という見込みではない。

その前に確認する項目:

1. Studyの画面・SQLite・native chat等から独立した依存・ビルド・テストに切り出せること。
2. 通常HTTPにも説明可能な終了契約とbackend能力差を明示し、実行器との対応を検証すること。
3. 接続ループの複製を本家へ持ち込むのではなく、必要なupgrade境界・共通変更を整理すること。
4. 汎用のHTTP接続移譲、WebSocket層、寿命モデルを分け、何を本家へ提案するかを相談すること。
5. HTTP/2とも矛盾しないscope、互換性、未保証範囲、保守・検証方法を示すこと。

この文書整理ではソースやLake構成を分離していない。
派生元のアプリは利用・回帰確認の場であり、独立化後も全アプリをライブラリへ含める必要はない。
