# whub-mac のビルド＆起動 / Archive

## 対象

BasePath から対象ディレクトリに移動し、以降はそこで実行する。

- `projects/whub-mac`：Debug ビルド＆起動、Archive。
- `worktrees/whub-mac-ISSUE`：Debug ビルド＆起動のみ。

対象が不明なら実行前に確認する。
`-scheme 'whub (whub project)'` は、XcodeでGUIアプリをビルドする設定を選ぶ指定。

## Debug ビルド＆起動

```sh
xcodebuild build \
  -project whub.xcodeproj \
  -scheme 'whub (whub project)' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/DerivedData"
```

終了コードが 0 のときだけ、別のツールリクエストで起動する。ビルドのみの依頼なら起動しない。

```sh
open -n "$PWD/DerivedData/Build/Products/Debug/whub.app"
```

既存のアプリは終了しない。`open -n` は新しいインスタンスを起動する。
画面・機能の確認はユーザに依頼する。

## Archive（projectのみ）

```sh
mkdir -p .build/archives
xcodebuild archive \
  -project whub.xcodeproj \
  -scheme 'whub (whub project)' \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  -archivePath "$PWD/.build/archives/whub-$(date +%Y%m%d-%H%M%S).xcarchive"
```

成功と成果物の存在を確認する。`.xcarchive` の作成までとし、`/Applications/whub.app` は置き換えない。
`DerivedData/` と `.build/` は Git ignore 対象で、成果物は削除してよい。

## 結果

対象・成否・成果物のパスを報告する。失敗したら後続操作を止め、原因を報告する。

projectでDebugビルド・起動・ユーザによる画面確認済み。Archiveとworktreeでの実行は未検証。
