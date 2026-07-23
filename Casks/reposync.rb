# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/reposync@1dd28bd50a5618be7be1c91c50b49f73f6eb4668 (.goreleaser.yaml)
cask "reposync" do
  version "0.22.0"

  on_macos do
    on_intel do
      sha256 "e55b062b099c6bb6b29fdd584da3ad83b168799c0b0f5ac806cb922cd3bb7356"
      url "https://github.com/yasyf/reposync/releases/download/v0.22.0/reposync_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "d825e4aaaef5ebe077371172cd41335700ec268e1ace161650f3fd050acbde56"
      url "https://github.com/yasyf/reposync/releases/download/v0.22.0/reposync_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "04e0c5e78a0f8899d2ee8cd83922a42c077601c96cdb875075abc34c84d886c8"
      url "https://github.com/yasyf/reposync/releases/download/v0.22.0/reposync_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "f4bc87b5ee7a2c61eb5f1146455212ee253e99f3246b7c49b1d0cfa6102b7a88"
      url "https://github.com/yasyf/reposync/releases/download/v0.22.0/reposync_linux_arm64.tar.gz"
    end
  end

  name "reposync"
  desc "Keep git repos in sync across your remote hosts."
  homepage "https://github.com/yasyf/reposync"

  livecheck do
    skip "Auto-generated on release."
  end
  depends_on formula: "jj"

  binary "reposync"

  # No zap stanza required
end
