# WebSocket実装の独立リポジトリ化計画

所属: [Std拡張WebSocket開発](./README.md)。
[README「将来の独立化」](./README.md)の確認項目と
[互換性テスト外部ツール調査](./websocket-conformance-tools.md)を前提に、
分離の範囲・手順・完了条件を定める計画書。2026-11-03作成、同日6節の5項目を決定。
**本書は計画であり、分離は未実施。** 着手条件は満たされている。

## 1. 目的と方針

- Webアプリの書き方を調査する本リポジトリ（Study）から、WebSocket実装
  （`StdExt`とその検証一式）を独立リポジトリへ移す。
- 動機: (1) 本家Autobahn|TestsuiteをCIでフル実行できる環境（GitHub Actions）を
  WebSocket専用に持つ、(2) Lean本家への提案単位を明確にする、(3) Studyアプリの
  依存（SQLite・native・lithe等）から切り離した最小のビルド・テストにする。
- 方針: **モジュール名（`StdExt.*`・`Std.Http.*`名前空間）は変えない**。
  本家upstreamがファイル改名で済む現設計を維持し、Study側の利用コードも
  importを変えずlakefileの`require`追加だけで移行できるようにする。
- 分離の実現性は確認済み: `StdExt`のimportはStdと自前モジュールのみで、
  MapleSQL・lean-html・lithe・ws-lean・nativeコード（sqlite.c/chat.c）に依存しない。

## 2. 新リポジトリの構成

```
same-port-websocket/
  lean-toolchain            # leanprover/lean4:v4.35.0（Studyと同一から開始）
  lakefile.lean             # 下記
  StdExt.lean               # 現行のまま（ルートdoc）
  StdExt/Http/Server/{Upgrade,Connection,Serve}.lean
  StdExt/Http/WebSocket.lean
  StdExt/Http/WebSocket/{Crypto,Frame,Connection,Lifecycle,
                         MockExecutor,AsyncExecutor,FrameAdapter,
                         LifecycleUpgrade}.lean
  Tests.lean                # test_driver入口（旧LeanWebStudyTestsのWS部分）
  Tests/{Lifecycle,MockExecutor,AsyncExecutor,TcpBackend,
         FrameAdapter,LifecycleUpgrade}Tests.lean
  Main.lean                 # 最小echoサーバー（lean_exe wsecho、後述）
  tests/test_ws_std.py      # stdlibプロトコル結合試験
  tests/test_ws_autobahn.py # stdlib準拠スイート
  tests/autobahn.sh
  tools/autobahn/{fuzzingclient.json, fuzzingclient-full.json, README.md}
  docs/                     # 現docs/std-websocket/の全文書
  .github/workflows/ci.yml
  LICENSE                   # Apache-2.0（6節C）
  README.md                 # 現docs/std-websocket/README.mdを入口に再構成
```

lakefileの骨子（Studyのsqlite/chat関連・外部requireはすべて不要）:

```lean
package «same-port-websocket» where
  version := v!"0.1.0"

lean_lib StdExt

@[test_driver]
lean_exe Tests where
  root := `Tests

@[default_target]
lean_exe wsecho where
  root := `Main
```

### 最小echoサーバー（`wsecho`）

Python結合試験と本家Autobahnの対象。Studyの`leanwebstudy`バイナリの置き換えとして、
次だけを提供する: `/health`（200）、`/ws-echo/socket`（既存`WebSocket.upgrade`のecho、
現Studyと同じOrigin方針）、`/ws/socket`（`Lifecycle.Upgrade.upgrade`のecho）。
引数は `wsecho <port> [maxMessageBytes]`。第二引数はAutobahnフル実行ジョブ
（9.xの16 MiBケース）向けに上限を引き上げるためのもの。
Python側の変更は起動コマンドの定数のみ（`ROOT/.lake/build/bin/wsecho`）。

## 3. 移すもの・残すもの・変えるもの

| 対象 | 行き先 | 変更 |
|---|---|---|
| `StdExt/`一式・`StdExt.lean` | 新repo | 無変更 |
| [LeanWebStudyTests.lean](../../LeanWebStudyTests.lean)の`section WebSocketTests`（SHA-1/Base64/accept key/フレーム/ハンドシェイク/Close理由） | 新repo `Tests.lean` | sectionの切り出しのみ |
| `LeanWebStudy/{Lifecycle,MockExecutor,AsyncExecutor,TcpBackend,FrameAdapter,LifecycleUpgrade}Tests.lean` | 新repo `Tests/` | namespace接頭辞の変更のみ（`LeanWebStudy.` → `StdExtTests.`等） |
| `tests/test_ws_autobahn.py`・`tests/autobahn.sh`・`tools/autobahn/` | 新repo | サーバーバイナリ名を`wsecho`へ。フル実行用設定`fuzzingclient-full.json`を追加 |
| `tests/test_ws_std.py` | **Studyに残し、新repoへは適合コピー** | Study版はアプリの`/ws-echo`（Origin方針・同一ポートHTTP共存を含む）の結合回帰として維持。新repo版は`wsecho`向けに起動部のみ変更 |
| `docs/std-websocket/`全文書 | 新repo `docs/` | コード相対リンクを一段付け替え（`../../StdExt`→`../StdExt`）。[application-study](../application-study/README.md)への参照はStudyリポジトリへの絶対URLに変更 |
| `/ws-echo`エンドポイント・`WebHandler`のupgrade分岐・`Main.lean`の配線 | Studyに残す | lakefileに新repoを`require`（コミット固定）。importは無変更 |
| `WsChat`（ws-lean）・chat/pong（libwebsockets native） | Studyに残す | 無変更（本実装と無関係） |
| `docs/std-websocket/` | Studyからは削除し、入口READMEだけ残す | 移転先への案内と、application-study側の経緯文書への逆リンク |
| CI（Study側） | `test_ws_std.py`ステップを**残す** | Studyは利用側としての回帰確認を続ける（/ws-echoが依存更新後も動くこと）。`test_ws_autobahn.py`のステップは新repoへ移す |

履歴の扱い: `git filter-repo`（または`git subtree split`）で
`StdExt/ docs/std-websocket/ tests/test_ws_autobahn.py tools/autobahn/`のパス履歴を
抽出して新repoの初期履歴とする。履歴抽出が難しければ、初期コミットに本計画と
Study側の最終コミットハッシュを記録する形でも可とする（6節B）。

## 4. 新リポジトリのCI設計

[外部ツール調査](./websocket-conformance-tools.md)4節の構成を実装する。

| ジョブ | 内容 |
|---|---|
| build-and-test | `leanprover/lean-action`（`lake build` + `lake test`: モデル探索・実行器・実TCPプローブ・フレーム層・接続ループe2e） |
| protocol-tests | `python3 -m unittest discover -s tests -p 'test_ws_*.py'`（stdlibのみ） |
| autobahn | 本家Docker image（ダイジェスト固定）を`--network host`で実行。既定設定（1 MiB、9.x大型を除外）に対する`wsecho 8090` |
| autobahn-full | `wsecho 8090 16777216`に対し`fuzzingclient-full.json`（除外は12.x/13.xのみ）で実行 |
| 成果物 | 両autobahnジョブのHTMLレポートをartifactとして保存。失敗判定はレポートJSONの`behavior`が`OK`/`INFORMATIONAL`以外のケースの有無で行う |

## 5. 移行手順（各段に検証ゲート）

1. **新repo作成と骨格**: 空repo（`bgnori/same-port-websocket`）＋`lean-toolchain`＋
   lakefile＋LICENSE（Apache-2.0）。
   ゲート: `lake build`が空ライブラリで通る。
2. **ソース移設**: `StdExt/`と`StdExt.lean`を履歴ごと移す（6節B）。
   ゲート: `lake build StdExt`成功。
3. **テスト移設**: Leanテスト（`Tests/`）とPythonテスト・`wsecho`実装。
   ゲート: `lake test`と`python3 -m unittest discover -s tests -p 'test_ws_*.py'`が全通過。
4. **CI整備**: 4節のworkflow。ゲート: 4ジョブ全緑。autobahn-fullのレポートで
   9.x大型ケースのPassを確認（初のフル実行結果を`docs/`に記録する）。
5. **docs移設**: 文書とリンク付け替え。ゲート: リンク検査スクリプト全通過。
6. **Study側の切り替え**: lakefileへ
   `require «same-port-websocket» from git "<url>" @ "<commit>"`を追加し、
   `StdExt/`・WSテスト・`tools/autobahn/`・`docs/std-websocket/`本文を削除、
   入口READMEを残す。ゲート: Studyの`lake build`・`lake test`・
   `python3 -m unittest discover -s tests -p 'test_ws_std.py'`（/ws-echo回帰）・
   既存CIが全緑。**このコミットまでStudy側のWebSocket実装へ変更を加えない（凍結）。**
7. **凍結解除と運用開始**: 以後の実装変更は新repoのみで行い、Studyは
   コミット固定の更新で追従する（既存のMapleSQL等と同じ運用）。

手順2〜5の間、Study側の`StdExt`へ変更が必要になった場合は移行を中断して
Study側へ先に入れ、手順2からやり直す（二重管理を作らない）。

## 6. 決定事項（2026-11-03 承認済み）

当初の未決A〜Eは以下のとおり決定した。

| ID | 事項 | 決定 | 根拠 |
|---|---|---|---|
| A | リポジトリ名 | **`same-port-websocket`**（lib名・名前空間は`StdExt`のまま） | 名前空間・ファイル名は本家マージを目指す都合上`StdExt`で必然であり、他実装（ws-lean等は別ポートで自前サーバーを立てる）との差異を一言で示せる場はリポジトリ名だけ。最大の特徴である「HTTPと同一ポートで、サーバー所有の接続をUpgradeで引き渡して使い回す」ことを利用者目線で名乗る |
| B | 履歴の抽出方法 | **`git filter-repo`** で `--path StdExt --path docs/std-websocket --path tests/test_ws_autobahn.py --path tools/autobahn` の履歴を抽出。失敗時はスナップショット初期化＋出所コミット記録へフォールバック | 約55コミットからWS関連の経緯を保全できる |
| C | ライセンス | **Apache-2.0** | Lean本家・Stdと同一。upstream提案時の摩擦が最小 |
| D | 置き場所 | **bgnori配下**（`bgnori/same-port-websocket`） | 既存依存（MapleSQL等）と同じ運用 |
| E | Study側docsの残し方 | **入口READMEのみ残す**（移転先案内とapplication-study経緯への逆リンク） | 「同じ議論を複数文書へコピーしない」既存方針と整合 |

## 7. 完了条件

- 新repoのCI 4ジョブが全緑で、autobahn-fullのレポートが保存・記録されている。
- Studyが新repoをコミット固定で`require`し、importの変更なしにビルド・全テストが通る。
- Studyから移設対象のソース・文書が削除され、入口READMEから新repoへ辿れる。
- 両repoのREADMEが「どちらに何があるか」「変更はどちらへ入れるか」を明記している。
- [試作結果のチェックリスト](./websocket-prototype-results.md)等、進行中の台帳の
  正本が新repo側であることが宣言されている。

6節の決定により着手条件は満たされている。最初の外部アクションは
`bgnori/same-port-websocket` の空リポジトリ作成（GitHub上の操作）である。
