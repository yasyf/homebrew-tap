# Fixed FuseKit holder for cc-notes. GENERATED per release from this template.
cask "cc-notes-holder" do
  version "0.37.1"
  sha256 "2838fbf17989cd907c90476c178392af56b557623fc752b6206d50ff90f4771f"

  url "https://github.com/yasyf/cc-notes/releases/download/v#{version}/cc-notes-holder-v#{version}-darwin.zip"
  name "cc-notes Holder"
  desc "Fixed signed FuseKit holder for cc-notes repositories"
  homepage "https://github.com/yasyf/cc-notes"

  depends_on macos: :sequoia
  depends_on cask: "macos-fuse-t/homebrew-cask/fuse-t"
  depends_on formula: "cc-notes"

  app "CCNotesHolder.app"

  preflight do
    executable = "/Applications/CCNotesHolder.app/Contents/MacOS/CCNotesHolder"
    system_command executable, args: ["--stop-service"], must_succeed: true if File.executable?(executable)
  end

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "/Applications/CCNotesHolder.app"],
                   must_succeed: false
    system_command "/Applications/CCNotesHolder.app/Contents/MacOS/CCNotesHolder",
                   args: ["--install-service"],
                   must_succeed: true
  end

  uninstall_preflight do
    system_command "/Applications/CCNotesHolder.app/Contents/MacOS/CCNotesHolder",
                   args: ["--stop-service"],
                   must_succeed: true
  end

  zap trash: "~/.cc-notes/fusekit-v1"

  caveats <<~EOS
    The fixed signed holder service exposes provisioned cc-notes tenants through FuseKit.
    Its derived runtime state lives under ~/.cc-notes/fusekit-v1.
  EOS
end
