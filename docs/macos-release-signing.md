# macOS配布用の署名・公証の初期設定

SlotPickが起動する前に表示される「Appleは悪質なソフトウェアが含まれていないことを確認できません」という警告は、アプリ内の設定リンクでは解消できません。Developer ID署名とAppleの公証を行った新しいDMGを配布します。初回の通常のダウンロード確認や、カレンダーへのアクセス許可は引き続き表示される場合があります。

## ユーザーが行う初期設定

1. [Apple Developerアカウント](https://developer.apple.com/account/)で、Apple Developer Programの有効なメンバーシップを確認します。未加入なら加入が必要です。
2. Xcodeの **Settings → Accounts** にそのApple Accountを追加し、対象Teamの **Manage Certificates** から **Developer ID Application** 証明書を作成します。作成権限がない場合はAccount Holderに依頼してください。Apple DevelopmentやDeveloper ID Installerではありません。
3. **キーチェーンアクセス → 自分の証明書** で、そのDeveloper ID Application証明書に秘密鍵が付いていることを確認し、証明書と秘密鍵をパスワード付きの `.p12` として書き出します。
4. [Apple Account](https://account.apple.com/)の **サインインとセキュリティ → アプリ用パスワード** で、公証用のパスワードを作成します。2ファクタ認証が必要です。普段のApple Accountパスワードは使用しません。
5. [SlotPickのActions Secrets設定](https://github.com/taako-502/slotpick/settings/secrets/actions)で、次のRepository secretsを登録します。既存の `SPARKLE_PRIVATE_KEY` はそのまま維持します。

| Secret名 | 登録する値 |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | `.p12` ファイルをBase64に変換した内容 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` 書き出し時に付けたパスワード |
| `APPLE_TEAM_ID` | DeveloperアカウントのMembership detailsにある10文字のTeam ID |
| `APPLE_ID` | Developer Programで使用するApple Accountのメールアドレス |
| `APPLE_APP_SPECIFIC_PASSWORD` | 手順4で作成したアプリ用パスワード |

`.p12` の内容は、ターミナルで次のように直接Secretへ登録できます。パスは実際の保存先に置き換えてください。GitHub CLIにログイン済みである必要があります。

```sh
base64 -i '/証明書の保存先/DeveloperID.p12' | gh secret set DEVELOPER_ID_CERTIFICATE_BASE64 --repo taako-502/slotpick
```

秘密鍵・証明書のパスワード・アプリ用パスワードは、チャット、PR、Gitに貼り付けず、Secretsに直接登録してください。書き出した証明書は安全にバックアップし、作業用コピーは登録後に削除します。

## 設定後のリリース

PRをmainへマージした後、**Actions → Release DMG → Run workflow** で新しいバージョンを発行します。既存の公開済みDMGが後から公証済みに変わるわけではありません。

リリースでは次を必須とします。

- 一時キーチェーンに証明書を読み込み、Team IDに一致する有効なDeveloper ID Application証明書を確認。
- Hardened Runtimeを有効にしてArchive/Export。Sparkleの補助アプリ・XPCサービスも配布用に再署名。
- アプリをAppleへ公証申請し、Acceptedになった場合だけ公証チケットを付与・検証。
- DMGも署名・公証し、チケットを付与。マウントしたアプリをGatekeeperで検証。
- 最終DMGからSHA-256とSparkle更新署名を生成してからGitHub Releaseを公開。

認証情報の不足、公証の拒否・タイムアウト、署名・Gatekeeper検証の失敗時は公開しません。未公証版への自動フォールバックもありません。公証は1回につき最大20分待ち、タイムアウト後もApple側の処理は継続する可能性があります。問題を解消してワークフローを再実行してください。キーチェーン操作のエラーは認証情報をログに漏らさないよう詳細出力を省略します。証明書の有効期限、秘密鍵の有無、パスワード、Team IDを確認してください。

一時キーチェーンは通常終了・例外時に削除し、元のキーチェーン検索リストを復元します。CIの強制終了時はGitHubホストランナー自体の破棄に依存します。

最初の署名済みリリース後は、ブラウザからDMGをダウンロードし、Applicationsへコピーして起動を確認してください。現在の未公証版からは、このDMGで手動更新できます。Sparkleの既存鍵は変更しませんが、署名方式を切り替える最初のアプリ内更新は別途実機確認が必要です。

## ローカル確認

通常のXcodeでの開発・テストは従来どおりローカル署名で実行できます。配布用DMG作成には上記5項目を同名の環境変数として用意し、次を実行します。ローカルではSparkleの鍵を既存のキーチェーンから読み込めます。

```sh
python3 scripts/signed-release.py 0.2.2 5 /tmp/slotpick-release-assets
```

## 参考

- [Apple: Developer ID証明書](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple: 公証のワークフロー](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: アプリ用パスワード](https://support.apple.com/102654)
- [Sparkle: 補助プロセスのコード署名](https://sparkle-project.org/documentation/sandboxing/#code-signing)
