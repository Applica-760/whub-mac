# SwiftとSwiftUIの用語集
Swiftのコードを読み、設計意図を正確に伝えるための簡潔な参照資料。
SwiftUI：画面構造を宣言的に記述し、状態に応じて画面を更新するAppleのUIフレームワーク。
AppKit：macOS向けのUIフレームワーク。`NSView`などの画面部品やウィンドウ機能を提供する。
UIKit：iOS・iPadOS向けのUIフレームワーク。`UIView`などの画面部品や操作機能を提供する。


## 型と宣言
- **型（type）**：値の種類と、その値に使える機能を定義するもの。
- **インスタンス（instance）**：型に基づいて作られた実際の値。
- **`struct`**：値として扱う型を定義する。一般にコピーして受け渡すデータに向く。
- **`class`**：参照として扱う型を定義する。同じインスタンスを複数箇所から共有できる。
- **`enum`**：取り得る値を有限のケースとして定義する型。
- **Protocol**：型が提供すべき機能や要件を定める約束。
- **適合（conformance）**：型がProtocolの要件を満たすこと。
- **継承（inheritance）**：Swiftではクラスが別のクラスの機能や特性を引き継げる。`struct` と `enum` はクラス継承をしない。
`struct MyView: View` は継承ではなく、「MyViewがView Protocolに適合する」という意味。Protocolは抽象クラスと似た用途もあるが、継承とは別の仕組み。


## プロパティと関数
- **プロパティ**：型やインスタンスに属する値。
- **保存プロパティ**：値を保持するプロパティ。
- **計算プロパティ**：アクセス時に処理して値を返すプロパティ。`page.label` のように参照し、括弧は付けない。
- **関数（function）**：呼び出して処理を実行するもの。
- **メソッド（method）**：型の中に定義された関数。
- **返り値の型**：関数では `->` の後、プロパティでは `:` の後に書く。
- **イニシャライザ（initializer）**：インスタンスを初期化する `init`。他言語のコンストラクタに近い。
- **Property Wrapper**：`@State` のように、プロパティの保存・共有などの振る舞いを付加する仕組み。

- **`some Protocol`**：具体的な型名を隠しつつ、値がそのProtocolに適合することを示す型指定。
- **`some View`**：Viewに適合する具体型の値を返す型指定。View関数やProtocol自体を返す意味ではない。
- **`@ViewBuilder`**：分岐などの複数のView記述を、SwiftUIが扱えるView構造にまとめる仕組み。


## SwiftUIの画面構造
- **`View`**：画面要素の型が適合するSwiftUIのProtocol。クラスや `struct` そのものではない。
- **View値**：画面の構造を記述する値。SwiftUIがその記述を実際の画面へ反映する。
- **`body`**：Viewが画面構造を返す計算プロパティ。関数ではない。
- **`App`**：SwiftUIアプリの構成を定義するProtocol。
- **`@main`**：プログラムの起動点を示す属性。
- **`Scene`**：SwiftUIがライフサイクルを管理するUI単位で、View階層のルート。
- **`WindowGroup`**：同じ構成のウィンドウ群を管理するSwiftUI組み込みScene。
- **View modifier**：ViewやSceneに設定を加えた構成を返すもの。例：`.padding(...)`、`.toolbar { ... }`。


## 状態と共有
- **State（状態）**：時間とともに変化する値。特定のクラスや設計方式の名前ではない。
- **`@State`**：SwiftUIのViewが所有する状態を保持するProperty Wrapper。
- **`Binding`**：状態の所有元への読み書き可能な接続。
- **`$value`**：Property WrapperからBindingなどの投影値を取り出す記法。
- **`ObservableObject`**：オブジェクトの変更を監視可能にするProtocol。
- **`@Published`**：プロパティの変更を購読側へ知らせるProperty Wrapper。
- **`@StateObject`**：ViewがObservableObjectのインスタンスを所有するためのProperty Wrapper。
- **`@ObservedObject`**：外から渡されたObservableObjectを監視するProperty Wrapper。
- **`@EnvironmentObject`**：View階層の環境からObservableObjectを受け取るProperty Wrapper。
- **`@Observable` / `@Bindable`**：`ObservableObject` とは別のObservation方式で、変更の監視とBinding作成に使う。
- **依存（dependency）**：ある型の処理に必要な別の値や機能。
- **依存の注入**：必要な依存をinitializer引数や環境などから受け取ること。
- **Store**：Swift言語の特別な型ではなく、機能の状態と、それを変える操作をまとめる役割を表す慣習的な名前。


## 永続データとContainer
- **永続データ**：アプリ終了後も保存されるデータ。メモリ上の一時的な画面状態とは異なる。
- **`ModelContainer`**：SwiftDataのクラス。モデル構成と永続ストレージを管理し、ModelContextと保存先を仲介する。
- **`ModelContext`**：SwiftDataでモデルの検索・追加・削除・保存などを行うオブジェクト。
- **`.modelContainer(...)`**：対象のSceneまたはViewの環境にModelContainerとModelContextを設定するmodifier。
- **`Container`**：一般用語であり、特定のSwift型やDB方式を意味しない。プロジェクト内の型名なら宣言と戻り値を確認する。


## 順序とメニュー
- **`CaseIterable`**：全ケースを `allCases` で列挙できるProtocol。関連値のないenumは宣言順に列挙される。
- **`Hashable`**：等価性の判定とハッシュ値の生成を可能にするProtocol。ハッシュ値は永続IDや安定IDとは異なる。
- **`ForEach`**：コレクションの各要素からViewを作るSwiftUI構造。表示順は元のコレクション順に従う。
- **`CommandGroup`**：標準メニュー内のグループに項目を追加・置換する。
- **`CommandGroupPlacement`**：標準メニューで追加・置換する位置を指定する名前。
- **`CommandMenu`**：アプリ固有のトップレベルメニューを作る。


## 言い方の対応
- 「Viewを継承する」→「View Protocolに適合する」
- 「body関数」→「body計算プロパティ」
- 「some ViewはView関数」→「Viewに適合する具体型を隠して返す型指定」
- 「変数返し／関数返し」→「プロパティ参照／関数・メソッド呼び出し。どちらも値を返せる」
- 「StoreはStateと同じ」→「Stateは状態、Storeは状態や操作を管理する役割名」
- 「Containerがデータ」→「Containerは保存構成やアクセスを管理し、データはストレージに保存される」



