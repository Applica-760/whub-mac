# リモートGit Storeの要求仕様

## RGITSTORE-F-001：通知を受けて表示中の差分を更新する
- 前提：Hostが接続され、変更一覧とファイル差分を表示している。
- 操作：リモートから変更通知が届く。
- 期待結果：変更一覧と表示中の差分を再取得し、最新の結果を保持する。
- 対応テスト：`whubTests/Features/Files/Store/RemoteGitStoreTests.swift / RemoteGitStoreTests.refreshesChangesAndVisibleDiffOnNotification()`

## RGITSTORE-F-002：Host切断中は監視を停止し再接続時に再取得する
- 前提：Hostが接続され、リモートGitを監視している。
- 操作：Hostを切断し、再び接続する。
- 期待結果：切断中は監視と取得を行わず、再接続後に監視を開始して差分を再取得する。
- 対応テスト：`whubTests/Features/Files/Store/RemoteGitStoreTests.swift / RemoteGitStoreTests.stopsWhileDisconnectedAndReloadsOnReconnect()`

## RGITSTORE-F-003：古い接続の取得結果を反映しない
- 前提：差分取得が進行中である。
- 操作：Hostを切断して再接続した後、古い取得を完了させる。
- 期待結果：古い結果を破棄し、現在の接続で取得した結果だけを保持する。
- 対応テスト：`whubTests/Features/Files/Store/RemoteGitStoreTests.swift / RemoteGitStoreTests.discardsResultFromPreviousConnection()`
