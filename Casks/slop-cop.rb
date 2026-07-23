# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/slop-cop@63361f75f45e40fefc0484861a1c05937d3d9035 (.goreleaser.yaml)
cask "slop-cop" do
  version "0.1.55"

  on_macos do
    on_intel do
      sha256 "0925816154b929fb02792f08abd9356a1b2e4c08c2fd30d6193a477814978205"
      url "https://github.com/yasyf/slop-cop/releases/download/v0.1.55/slop-cop_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "968928a0f7b41f5acbdfde585eeab95fe9929640f6fe78545c6b025238eab39d"
      url "https://github.com/yasyf/slop-cop/releases/download/v0.1.55/slop-cop_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "5146f15937aebe0dadcf37e2ef0017fb39db6bd1c0ebb060b3f0d93c36c05b49"
      url "https://github.com/yasyf/slop-cop/releases/download/v0.1.55/slop-cop_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "df9c99224df0ba3afd3b423a549ae8f7e963e23d65bd64201d52fa64a402987f"
      url "https://github.com/yasyf/slop-cop/releases/download/v0.1.55/slop-cop_linux_arm64.tar.gz"
    end
  end

  name "slop-cop"
  desc "Detect the rhetorical and structural tells of LLM-generated prose and emit a structured JSON report."
  homepage "https://github.com/yasyf/slop-cop"

  livecheck do
    skip "Auto-generated on release."
  end
  binary "slop-cop"

  # No zap stanza required
end
