#!/bin/sh

git config --global --unset commit.template
git config --global --add safe.directory /home/vscode/app
git config --global fetch.prune true
git config --global --add --bool push.autoSetupRemote true
git config --global commit.gpgSign false
git config --global user.signingkey $(gpg --list-secret-keys --with-colons | grep -B 3 "uid.*$(git config user.name)" | cut -d: -f5 | sed ':a;N;$!ba;s/\n//g')
git branch --merged|egrep -v '\*|develop|main|master'|xargs git branch -d

# .zshrc にシェル初期化を追加 (venv activate, .env 読み込み, alias)
if ! grep -q '# >>> app shell init >>>' ~/.zshrc 2>/dev/null; then
  cat >> ~/.zshrc << 'SHELL_INIT'

# >>> app shell init >>>
source /home/vscode/app/.venv/bin/activate
set -a; source /home/vscode/app/.env 2>/dev/null; set +a
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config user.name)}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email)}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git config user.name)}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git config user.email)}"
# Theos toolchain (otool, lipo, ldid, install_name_tool 等を PATH に通す)
# iOS バイナリ解析を行う agent-iossolve の recon エージェント等が要求
export PATH="\$HOME/theos/toolchain/linux/iphone/bin:\$PATH"
alias frida-trace="frida-trace -H \$ANDROID_HOST --ui-port \$UI_PORT"
alias frida-ps="frida-ps -H \$ANDROID_HOST"
# <<< app shell init <<<
SHELL_INIT
fi

