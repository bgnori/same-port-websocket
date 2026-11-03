# WebSocket互換性テストの外部ツール調査と利用判断

所属: [Std拡張WebSocket開発](./README.md)。
リポジトリ独立化（README「将来の独立化」）の準備として、
Autobahn|Testsuite以外の外部互換性テストを調査し、独立後のテスト構成を定めた記録。
調査日: 2026-11-03。Web上の公開情報に基づく（各項の参照先を明記）。

## 1. 結論

- **プロトコル準拠の外部スイートはAutobahn|Testsuiteが実質唯一**であり、独立後リポジトリの
  CI（GitHub Actions）で本家をDockerでフル実行する。GitHub Actionsの`ubuntu-latest`は
  Dockerを備えるため、devcontainerで不可能だった本家実行がCIでは無理なく可能になる。
- 本リポジトリに実装済みの資産はそのまま独立後も使う:
  [stdlib準拠スイート](../../tests/test_ws_autobahn.py)（Docker不要の高速フィードバック）、
  [tools/autobahn/](../../tools/autobahn/README.md)（本家の設定と除外根拠）。
- その他の候補は準拠スイートとしては不採用（下表）。一部は相互運用スモークや
  将来のHTTP/2段階の補完として採用余地を記録する。

## 2. 調査した候補と判断

| 候補 | 内容 | 状態（2026-11-03時点） | 判断 |
|---|---|---|---|
| [Autobahn\|Testsuite](https://github.com/crossbario/autobahn-testsuite) | RFC 6455準拠ファジング約500ケース。server試験=fuzzingclient、client試験=fuzzingserver | 維持されている（v25.10.1、2025-10のDocker image更新）。ただし実装はPython 2/PyPy2に意図的に凍結され、公式のPython 3後継は無い | **採用（主）**。独立後CIでDockerフル実行。凍結リスクは3節 |
| コミュニティPy3移植（例: autobahn-testsuite-py3） | 本家のPython 3移植の試み | 非公式・検証実績不明 | 不採用。本家Docker imageが動く限り不要。本家が動かなくなった場合の代替候補として記録のみ |
| [K3PO](https://github.com/k3po/k3po)（Kaazing） | スクリプト駆動のプロトコル試験。RFC 6455のシナリオ集を含む | 数年更新がなく実質放置 | 不採用。歴史的参照のみ。Autobahnに対する独自の価値（台本式の異常系）はあるが、保守されないJavaツールチェーンの導入コストに見合わない |
| [web-platform-tests websockets/](https://github.com/web-platform-tests/wpt/tree/master/websockets) | ブラウザのWebSocket API（クライアント側）準拠試験 | 活発に維持 | 不採用。**試験対象がブラウザ実装**であり、テストはWPT専用サーバーの挙動に依存する。第三者サーバーの検証用途ではない |
| Jakarta WebSocket TCK（旧JSR 356） | Java API仕様の適合試験 | 維持 | 不採用。Java APIの適合試験であり、ワイヤプロトコルの試験ではない |
| wscat / websocat / curl `--ws`（8.x、実験的） | 対話・スクリプト用クライアント | 維持 | 準拠スイートとしては不採用。**相互運用スモーク**（実在クライアント実装との疎通）として独立後に少数ケースを採用検討（4節） |
| Postman / Apidog等の商用・GUI | 機能試験・監視 | 維持 | 不採用。プロトコル準拠・ファジングの深さがない |
| 公開のWSファザー | 独立のプロトコルファザー | 汎用の公開スイートは見当たらない（各ライブラリが内製fuzzerを持つ） | 外部採用なし。本リポジトリは既にモデルの有界探索を持ち、フレーム復号器への入力ファジング（Lean `plausible`等）は内製の将来項目とする |

関連だが対象が異なるもの:

- [h2spec](https://github.com/summerwind/h2spec): HTTP/2サーバーのプロトコル準拠試験。
  WebSocketではなく、**将来のHTTP/2 adapter段階**（RFC 8441 Extended CONNECT）に入った際の
  HTTP/2層の検証として採用候補に記録する。

## 3. Autobahn採用に伴うリスクと手当て

- **Python 2凍結**: 本家はPyPy2ベースのDocker imageを意図的に凍結しており、
  ベースimage更新は想定されていない。imageが取得・実行できる限り問題はないが、
  供給が途絶えた場合に備え、(1) 使用imageのダイジェスト固定、
  (2) [stdlib準拠スイート](../../tests/test_ws_autobahn.py)の維持（本家のケースクラスを
  追えるだけ広げる）、を手当てとする。
- **採点とポリシーの不一致**: 1 MiB上限（D4）を超える9.x大型ケースは、サーバーが正しく
  `1009`を返してもwstestは失敗と採点する。独立後CIでは、既定設定の実行に加えて
  **上限を引き上げた専用設定のサーバーに対するフル実行**（除外なし、12/13のみ除外）を
  別ジョブで走らせ、両方の結果を成果物として保存する。
- **12.x/13.x（permessage-deflate）**: 未実装のため除外を継続。実装するまで
  「Unimplemented」をREADMEに明記する。

## 4. 独立後リポジトリのテスト構成（準備メモ）

独立化チェックリスト（[README](./README.md)「将来の独立化」）の
「独立した依存・ビルド・テストに切り出せること」に対応するテスト面の整理。

| 層 | 内容 | 移設元 |
|---|---|---|
| Lean純粋モデル・実行器 | `lake test`（lifecycle探索・mock実行器・実TCPプローブ・フレーム層・接続ループe2e） | [LeanWebStudyTests](../../LeanWebStudyTests.lean)からWebSocket関連のみ抽出 |
| プロトコル結合試験 | stdlib Pythonの[test_ws_std.py](../../tests/test_ws_std.py)・[test_ws_autobahn.py](../../tests/test_ws_autobahn.py) | そのまま（アプリ依存なし。サーバー起動部のバイナリ名のみ変更） |
| 本家Autobahn | GitHub ActionsでDocker実行（`--network host`、レポートをartifactに保存）。既定設定＋上限引き上げ設定の2ジョブ | [tools/autobahn/](../../tools/autobahn/README.md)を移設し、CI workflowを追加 |
| 相互運用スモーク（任意） | 実在クライアント実装（curl `--ws`、Python `websockets`、Node `ws`）でecho・close往復のみ確認 | 新規。準拠はAutobahnに委ね、ここは「現実のクライアントと話せる」ことの確認に限定 |

アプリ（chat・SQLite・lithe等）に依存するテストは移設しない。
SQLite・native chat等へのリンク（`lakefile`の`moreLinkArgs`）はWebSocketと無関係なので、
独立後のlakefileはStd依存のみで構成できる見込みである（`StdExt`はStd + 自前のCrypto/Frame/
upgrade実装のみに依存しており、MapleSQL・lean-html・lithe・ws-leanへの依存はない）。

## 参照

すべて2026-11-03参照。

- [Autobahn\|Testsuite リポジトリ](https://github.com/crossbario/autobahn-testsuite)（v25.10.1リリース、Docker imageの凍結方針はdocker/Dockerfileのコメントに明記）
- [AutobahnTestsuite ドキュメント](https://autobahn-testsuite.readthedocs.io/)
- [K3PO](https://github.com/k3po/k3po)
- [web-platform-tests websockets/](https://github.com/web-platform-tests/wpt/tree/master/websockets)、[WPT実行ガイド](https://web-platform-tests.org/running-tests/from-local-system.html)
- [curl WebSocketサポート（--ws、8.x実験的）](https://curl.se/docs/manpage.html)
- [h2spec](https://github.com/summerwind/h2spec)
