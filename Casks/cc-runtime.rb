# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/cc-runtime@d7c7fa95e56e9c199f31021e18d9f575f11451f5 (.goreleaser.yaml)
cask "cc-runtime" do
  version "0.11.0"

  on_macos do
    on_intel do
      sha256 "c645cfe57cfdc89f1f37a51a5028d52cd8457780ed2a232f2381594afb2127d5"
      url "https://github.com/yasyf/cc-runtime/releases/download/v0.11.0/cc-runtime_0.11.0_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "cae823c45837257f08e00c5ca461f0ba9596d7da730040d4b629fb6c9861029c"
      url "https://github.com/yasyf/cc-runtime/releases/download/v0.11.0/cc-runtime_0.11.0_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "3da913a616ebe2f317034e803752752cffc3a7f1d1173cb5cf3f377e497a1db7"
      url "https://github.com/yasyf/cc-runtime/releases/download/v0.11.0/cc-runtime_0.11.0_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "073b187285152de3f01e849839a5d765d3eb124f0da61ae2ad9e0ed590bb8cb6"
      url "https://github.com/yasyf/cc-runtime/releases/download/v0.11.0/cc-runtime_0.11.0_linux_arm64.tar.gz"
    end
  end

  name "cc-runtime"
  desc "Persistent remote delivery for Claude Code questions and notifications."
  homepage "https://github.com/yasyf/cc-runtime"

  livecheck do
    skip "Auto-generated on release."
  end
  binary "cc-runtime"

  # No zap stanza required
end
