# whub-mac のビルド＆起動 / Archive

## 対象

BasePath から対象ディレクトリに移動し、以降はそこで実行する。

- `projects/whub-mac`：Debug ビルド＆起動、Archive。
- `worktrees/whub-mac-ISSUE`：Debug ビルド＆起動のみ。

対象が不明なら実行前に確認する。
`-scheme 'whub (whub project)'` は、XcodeでGUIアプリをビルドする設定を選ぶ指定。同名のパッケージ側スキームとの衝突を避けるため、プロジェクト名を含めて指定する。

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

## 保存モデル変更時のCLI再ビルド（projectのみ）

GUIとCLIは同じ `workspace.store` を開く。WhubCoreの保存モデルを変更した場合は、GUIとCLIを両方再ビルドし、利用する成果物を揃える。
古いCLIで新しい保存モデルのDBを開くと、GUIのHost取得時などにSwiftDataが停止する場合がある。

`projects/whub-mac/Packages/WhubPackage` に移動して実行する。

```sh
xcodebuild build \
  -scheme whub-mac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/.build/out" \
  CONFIGURATION_BUILD_DIR="$PWD/.build/out/Products/Debug"
```

終了コードが0であることと、`command -v whub-mac` が更新した `.build/out/Products/Debug/whub-mac` を指すことを確認する。
利用中のGUIはユーザに再起動を依頼し、`whub-mac host` でSSH接続後に⌘Tで新規タブを開いて停止しないことを確認してもらう。
このCLIのビルドと動作確認は2026-10-04にprojectで実施済み。

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
