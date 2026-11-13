# Claude Codeの要求仕様

## 機能要件

### 受信

#### CC-F-001：部分応答を確定した応答で置き換える
- 前提：Claude Codeが応答を生成している
- 操作：部分応答の後に、確定した応答を受信する
- 期待結果：同じ本文が1つだけ表示され、確定した内容になる
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeReceivingTests.swift / ClaudeCodeReceivingTests.streamedTextIsReplacedByCompletedAssistant()`（1つのテキストブロックの置き換えと回答の推定を検証）

#### CC-F-002：ツールの結果を対応する呼び出しに表示する
- 前提：1つの応答で複数のツールが呼び出されている
- 操作：各ツールの結果を、呼び出しと異なる順序で受信する
- 期待結果：結果がそれぞれの呼び出しに表示され、エラーの結果は失敗として表示される
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeReceivingTests.swift / ClaudeCodeReceivingTests.toolResultCompletesMatchingToolUse()`

### 履歴

#### CC-F-003：現在の作業フォルダの会話を一覧に表示する
- 前提：作業フォルダでClaude Codeの会話をしたことがある
- 操作：`/resume`を入力する
- 期待結果：その作業フォルダの会話だけが、新しい順に表示される
- 対応テスト：未作成（手動確認済み）

#### CC-F-004：一覧の表示名は利用者が付けた名前を優先する
- 前提：会話に、利用者が付けた名前と自動生成された名前がある
- 操作：会話の一覧を表示する
- 期待結果：利用者が付けた名前が表示される。名前も最後のプロンプトもない会話は表示されない
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.historyEntryUsesNewestNamesAndSkipsUnnamedSessions()`

#### CC-F-005：再開した会話に並列ツールの結果を欠落させずに表示する
- 前提：並列にツールを呼び出した会話がある
- 操作：会話を再開する
- 期待結果：すべてのツールの結果が表示される
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.conversationRecoversParallelToolResults()`（会話の経路の組み立てを検証）

#### CC-F-006：巻き戻した会話は最後の枝を表示する
- 前提：途中から巻き戻して続けた会話がある
- 操作：会話を再開する
- 期待結果：最後に続けた枝のやり取りが表示され、破棄した枝は表示されない
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.conversationFollowsLastBranchInFile()`

#### CC-F-007：Skillの実行を入力として表示し、CLI内のコマンドは表示しない
- 前提：Skillの実行と`/model`などのCLI内のコマンドを含む会話がある
- 操作：会話を再開する
- 期待結果：Skillの実行は入力として表示され、CLI内のコマンドとその出力は表示されない
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.exchangesKeepSkillsAndSkipLocalCommands()`

#### CC-F-008：中断したやり取りを中断として表示する
- 前提：ツールの実行中に中断した会話がある
- 操作：会話を再開する
- 期待結果：そのやり取りと、結果のないツールが中断として表示される
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.interruptedExchangeMarksUnfinishedTools()`

#### CC-F-009：画像の入力を表示し、未対応の入力を含む会話は再開しない
- 前提：画像、または未対応の種類の入力を含む会話がある
- 操作：会話を再開する
- 期待結果：画像は入力として表示される。未対応の入力を含む会話は、入力を欠落させずにエラーになる
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.historyInputConvertsImagesAndRejectsUnknownTypes()`

#### CC-F-010：再開した会話で文脈を引き継いで送信する
- 前提：一覧から会話を再開した
- 操作：メッセージを送信する
- 期待結果：以前のやり取りを踏まえた応答が返る
- 対応テスト：未作成（手動確認済み）

#### CC-F-011：切断後の送信で同じ会話に再接続する
- 前提：会話中にClaude Codeとの接続が終了した
- 操作：メッセージを送信する
- 期待結果：同じ会話に再接続し、文脈を引き継いだ応答が返る
- 対応テスト：未作成（手動確認済み）

### 要求への回答と送信

#### CC-F-012：承認と複数選択の質問に回答する
- 前提：Claude Codeから承認の要求、または複数選択の質問が届いている
- 操作：承認・拒否する、または複数の選択肢を選んで回答する
- 期待結果：回答がClaude Codeに届き、要求は回答済みになる。未回答の質問がある場合は送信できない
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.questionsAndApprovalsKeepProtocolSpecificResponses()`（回答の送信形式への変換を検証）

#### CC-F-013：Skillを指定して送信する
- 前提：利用できるSkillの一覧を取得している
- 操作：Skillを1つ指定して送信する
- 期待結果：Skillが実行される。Skillを2つ以上指定した場合と、利用できないSkillを指定した場合は送信できない
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeHistoryAndRequestTests.swift / ClaudeCodeHistoryAndRequestTests.skillInputIsSentAsSlashCommand()`（送信形式への変換を検証）

### モデルと状態

#### CC-F-014：effortの選択肢に「指定なし」を含める
- 前提：モデルの一覧を取得している
- 操作：モデルの選択肢を表示する
- 期待結果：各モデルに「指定なし」が既定として含まれ、effortに対応するモデルだけに各effortが並ぶ
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeModelTests.swift / ClaudeCodeModelTests.optionsAddDefaultEffortBeforeSupportedLevels()`

#### CC-F-015：状態表示に接続先アドレスを出さず、取得できない項目を明示する
- 前提：Claude Codeに接続している
- 操作：`/status`を入力する
- 期待結果：バージョン・作業フォルダ・effort・残りの制限などが表示され、接続先アドレスは表示されない。取得できない項目は取得できないと表示される
- 対応テスト：`whubTests/Features/Agent/Store/ClaudeCodeStatusTests.swift / ClaudeCodeStatusTests.showsSessionValuesAndRemainingLimitsWithoutPeerAddress()`、`ClaudeCodeStatusTests.failuresAndUnavailableLimitsAreShownExplicitly()`
