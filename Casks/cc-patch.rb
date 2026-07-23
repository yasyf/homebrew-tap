# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/cc-patch@e68e97a52e2e38cfd5bce6393d22b8a12dab25cc (.goreleaser.yaml)
cask "cc-patch" do
  version "0.6.0"

  on_macos do
    on_intel do
      sha256 "bfaab1017f2b05b2dd1025ebc8a571b218dc979a207ade3286bbae268d2142c0"
      url "https://github.com/yasyf/cc-patch/releases/download/v0.6.0/cc-patch_0.6.0_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "df260f9ac76108be240915d27ed822b0a3a5ee78dc76007bd0c41efc9cabd8ca"
      url "https://github.com/yasyf/cc-patch/releases/download/v0.6.0/cc-patch_0.6.0_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "26e5769afad131c83d0a25b81e1a804e9f2be79840c9f796d1a2c7a30ba240a6"
      url "https://github.com/yasyf/cc-patch/releases/download/v0.6.0/cc-patch_0.6.0_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "3fec1e9862c1857c21a385633834e59f03af75db22f9c480ebe1697c3ce44ba6"
      url "https://github.com/yasyf/cc-patch/releases/download/v0.6.0/cc-patch_0.6.0_linux_arm64.tar.gz"
    end
  end

  name "cc-patch"
  desc "Fast mode for Claude Code's delegated agents, re-applied automatically on every update."
  homepage "https://github.com/yasyf/cc-patch"

  livecheck do
    skip "Auto-generated on release."
  end
  binary "cc-patch"

  postflight do
    if OS.mac?
      system_command "#{staged_path}/cc-patch", args: ["install-daemons"], must_succeed: false
    end
  end

  # No zap stanza required
end
