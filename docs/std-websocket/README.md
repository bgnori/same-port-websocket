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
| 純粋モデル試作 | 五つの局所補題、20件の入力列、深さ5・13,869ノードの探索。`lake test`成功 |
| まだ未接続 | 純粋モデルは実通信経路で使用していない。現行のsend/close競合を解決済みとはしない |
| 保留 | 公開終了API、承認済み契約の実装適合検証、backend能力の実証、一般の不変条件保存証明 |
| 未保証 | native全体の安全性、無条件の有界資源回収、HTTP/2実装全体の適合 |

**終了責任（D2）とsend/close意味論（D3）は承認済みのため、次の作業は
[チェックリストと判断台帳](./websocket-prototype-results.md#6-次段階の作業チェックリストと判断台帳)の
承認済み契約に基づき、制御I/Oも含むモデルと非同期モック実行器（段階B）を実装すること。
実TCPへ直結する段階ではない。**

## 読む順序

普段はこの入口と、作業に対応する一文書だけを読む。

| 優先 | 文書 | 役割 |
|---|---|---|
| 1 | [試作結果とTransport接続条件](./websocket-prototype-results.md) | 何を試し、何が不足し、次に何を検証するか |
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
- [Lifecycle](../../StdExt/Http/WebSocket/Lifecycle.lean)：通信経路に未接続の試作。
- [LifecycleTests](../../LeanWebStudy/LifecycleTests.lean)：決定的なモデル入力と探索。
- [Leanテスト入口](../../LeanWebStudyTests.lean)：アプリのテストと実行単位を共有。
- [通信テスト](../../tests/test_ws_std.py)：現行echo経路の検証。純粋モデルの適合証明ではない。

```sh
lake build LeanWebStudy.LifecycleTests
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
