class GitPromisor < Formula
  desc "Distributed revision control system"
  homepage "https://git-scm.com"
  url "https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.56.0.tar.xz"
  sha256 "26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3"
  revision 2
  license all_of: [
    "GPL-2.0-only",
    "GPL-2.0-or-later",
    "LGPL-2.1-or-later",
    "BSD-3-Clause",
    "MIT",
  ]
  compatibility_version 1
  head "https://github.com/git/git.git", branch: "master"

  stable do
    # MIDX preference is not physical promisor membership: https://github.com/yasyf/cc-context/actions/runs/41204979999
    patch :DATA
  end

  livecheck do
    url "https://mirrors.edge.kernel.org/pub/software/scm/git/"
    regex(/href=.*?git[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/yasyf/homebrew-tap/releases/download/git-promisor-2.56.0_2"
    sha256 arm64_sequoia: "7d9d8b4425916cb62720476932cff0022e7726b442dc1a6157858659e052c4e1"
  end

  depends_on "gettext" => :build
  depends_on "pkgconf" => :build
  depends_on "pcre2"

  uses_from_macos "curl"
  uses_from_macos "expat"


  on_macos do
    depends_on "gettext"
  end

  on_linux do
    depends_on "openssl@3"
    depends_on "zlib-ng-compat"
  end

  resource "Authen::SASL" do
    url "https://cpan.metacpan.org/authors/id/E/EH/EHUELS/Authen-SASL-2.2000.tar.gz"
    sha256 "8cdf5a7f185448b614471675dae5b26f8c6e330b62264c3ff5d91172d6889b99"
  end

  resource "html" do
    url "https://mirrors.edge.kernel.org/pub/software/scm/git/git-htmldocs-2.56.0.tar.xz"
    sha256 "c20a04cffce877e29ec532c5453f3fd2ce1f3daaf7f3b65d1f2fa73e95986d11"

    livecheck do
      formula :parent
    end
  end

  resource "man" do
    url "https://mirrors.edge.kernel.org/pub/software/scm/git/git-manpages-2.56.0.tar.xz"
    sha256 "1f62a7fabaa36a0469c4d51fe247d12e7e246b890d2b8b49aec91df610f417c7"

    livecheck do
      formula :parent
    end
  end

  resource "Net::SMTP::SSL" do
    url "https://cpan.metacpan.org/authors/id/R/RJ/RJBS/Net-SMTP-SSL-1.04.tar.gz"
    sha256 "7b29c45add19d3d5084b751f7ba89a8e40479a446ce21cfd9cc741e558332a00"
  end

  allow_network_access! :test

  def install
    odie "html resource needs to be updated" if build.stable? && version != resource("html").version
    odie "man resource needs to be updated" if build.stable? && version != resource("man").version

    ENV["NO_FINK"] = "1"
    ENV["NO_DARWIN_PORTS"] = "1"
    ENV["PYTHON_PATH"] = which("python3")
    ENV["PERL_PATH"] = which("perl")
    ENV["USE_LIBPCRE2"] = "1"
    ENV["INSTALL_SYMLINKS"] = "1"
    ENV["LIBPCREDIR"] = formula_opt_prefix("pcre2")
    ENV["V"] = "1"

    perl_version = Utils.safe_popen_read("perl", "--version")[/v(\d+\.\d+)(?:\.\d+)?/, 1]

    if OS.mac?
      ENV["PERLLIB_EXTRA"] = %W[
        #{MacOS.active_developer_dir}
        /Library/Developer/CommandLineTools
        /Applications/Xcode.app/Contents/Developer
      ].uniq.map do |p|
        "#{p}/Library/Perl/#{perl_version}/darwin-thread-multi-2level"
      end.join(":")
    end

    args = %W[
      prefix=#{prefix}
      sysconfdir=#{etc}
      CC=#{ENV.cc}
      CFLAGS=#{ENV.cflags}
      LDFLAGS=#{ENV.ldflags}
      NO_TCLTK=1
      NO_RUST=1
    ]

    args += if OS.mac?
      %w[NO_OPENSSL=1 APPLE_COMMON_CRYPTO=1]
    else
      openssl_prefix = formula_opt_prefix("openssl@3")

      %W[NO_APPLE_COMMON_CRYPTO=1 OPENSSLDIR=#{openssl_prefix}]
    end

    inreplace "Makefile", /(-DFALLBACK_RUNTIME_PREFIX=")[^"]+/, "\\1#{opt_prefix}"

    system "make", "install", *args

    git_core = libexec/"git-core"
    rm git_core/"git-svn"

    if OS.mac?
      cd "contrib/credential/osxkeychain" do
        system "make", *args
        git_core.install "git-credential-osxkeychain"
        system "make", "clean"
      end
    end

    cd "contrib/diff-highlight" do
      system "make"
    end

    cd "contrib/credential/netrc" do
      system "make", "test"
      git_core.install "git-credential-netrc"
    end

    cd "contrib/subtree" do
      system "make", "CC=#{ENV.cc}",
                     "CFLAGS=#{ENV.cflags}",
                     "LDFLAGS=#{ENV.ldflags}"
      git_core.install "git-subtree"
    end

    cd "contrib/git-jump" do
      git_core.install "git-jump"
    end

    bash_completion.install "contrib/completion/git-completion.bash"
    bash_completion.install "contrib/completion/git-prompt.sh"
    zsh_completion.install "contrib/completion/git-completion.zsh" => "_git"
    cp "#{bash_completion}/git-completion.bash", zsh_completion
    cp "#{bash_completion}/git-prompt.sh", zsh_completion

    (share/"git-core").install "contrib"

    man.install resource("man")
    (share/"doc/git-doc").install resource("html")

    chmod 0644, Dir["#{share}/doc/git-doc/**/*.{html,txt}"]
    chmod 0755, Dir["#{share}/doc/git-doc/{RelNotes,howto,technical}"]

    resource("Net::SMTP::SSL").stage do
      (share/"perl5").install "lib/Net"
    end

    resource("Authen::SASL").stage do
      (share/"perl5").install "lib/Authen"
    end

    perl_dir = prefix/"Library/Perl"
    rm_r perl_dir if perl_dir.exist?

    if OS.mac?
      (buildpath/"gitconfig").write <<~EOS
        [credential]
        \thelper = osxkeychain
      EOS
      etc.install "gitconfig"
    end
  end

  def caveats
    <<~EOS
      The Tcl/Tk GUIs (e.g. gitk, git-gui) are now in the `git-gui` formula.
      Subversion interoperability (git-svn) is now in the `git-svn` formula.
    EOS
  end

  test do
    system bin/"git", "init"
    %w[haunted house].each { |f| touch testpath/f }
    system bin/"git", "add", "haunted", "house"
    system bin/"git", "config", "user.name", "'A U Thor'"
    system bin/"git", "config", "user.email", "author@example.com"
    system bin/"git", "commit", "-a", "-m", "Initial Commit"
    assert_equal "haunted\nhouse", shell_output("#{bin}/git ls-files").strip

    refute_match HOMEBREW_CELLAR.to_s, shell_output("#{bin}/git --exec-path")

    return unless OS.mac?

    %w[foo bar].each { |f| touch testpath/f }
    system bin/"git", "add", "foo", "bar"
    system bin/"git", "commit", "-a", "-m", "Second Commit"
    assert_match "Authentication Required", pipe_output(
      "#{bin}/git send-email --from=test@example.com --to=dev@null.com " \
      "--smtp-server=smtp.gmail.com --smtp-server-port=587 " \
      "--smtp-encryption=tls --confirm=never HEAD^ 2>&1",
    )
  end
end

__END__
--- a/odb/source-packed.c
+++ b/odb/source-packed.c
@@ -351,1 +351,1 @@
-	if (m) {
+	if (m && !(opts->flags & ODB_FOR_EACH_OBJECT_PROMISOR_ONLY)) {
@@ -358,1 +358,1 @@
-		if (e->pack->multi_pack_index)
+		if (e->pack->multi_pack_index && !(opts->flags & ODB_FOR_EACH_OBJECT_PROMISOR_ONLY))
--- a/revision.c
+++ b/revision.c
@@ -1652,0 +1653,16 @@
+}
+
+static int for_each_ref_excluding_hidden(struct ref_store *refs,
+					refs_for_each_cb fn, void *cb_data)
+{
+	struct all_refs_cb *cb = cb_data;
+	struct strvec excludes = STRVEC_INIT;
+	struct refs_for_each_ref_options opts = {
+		.exclude_patterns = get_namespaced_exclude_patterns(
+			hidden_refs_to_excludes(&cb->all_revs->ref_excludes.hidden_refs),
+			get_git_namespace(), &excludes),
+	};
+	int ret = refs_for_each_ref_ext(refs, fn, cb_data, &opts);
+
+	strvec_clear(&excludes);
+	return ret;
@@ -2847,1 +2863,1 @@
-		handle_refs(refs, revs, *flags, refs_for_each_ref);
+		handle_refs(refs, revs, *flags, for_each_ref_excluding_hidden);
--- a/refs/ref-cache.c
+++ b/refs/ref-cache.c
@@ -4,0 +5,1 @@
+#include "../strvec.h"
@@ -279,6 +280,11 @@
-/*
- * Load all of the refs from `dir` (recursively) that could possibly
- * contain references matching `prefix` into our in-memory cache. If
- * `prefix` is NULL, prime unconditionally.
- */
-static void prime_ref_dir(struct ref_dir *dir, const char *prefix)
+static int ref_dir_is_excluded(const char *dirname,
+			       const struct strvec *excluded_prefixes)
+{
+	for (size_t i = 0; i < excluded_prefixes->nr; i++)
+		if (starts_with(dirname, excluded_prefixes->v[i]))
+			return 1;
+	return 0;
+}
+
+static void prime_ref_dir(struct ref_dir *dir, const char *prefix,
+			  const struct strvec *excluded_prefixes)
@@ -295,5 +301,5 @@
-		if (!(entry->flag & REF_DIR)) {
-			/* Not a directory; no need to recurse. */
-		} else if (!prefix) {
-			/* Recurse in any case: */
-			prime_ref_dir(get_ref_dir(entry), NULL);
+		if (!(entry->flag & REF_DIR) ||
+		    ref_dir_is_excluded(entry->name, excluded_prefixes))
+			continue;
+		if (!prefix) {
+			prime_ref_dir(get_ref_dir(entry), NULL, excluded_prefixes);
@@ -308,1 +314,1 @@
-				prime_ref_dir(get_ref_dir(entry), NULL);
+				prime_ref_dir(get_ref_dir(entry), NULL, excluded_prefixes);
@@ -311,1 +317,1 @@
-				prime_ref_dir(get_ref_dir(entry), prefix);
+				prime_ref_dir(get_ref_dir(entry), prefix, excluded_prefixes);
@@ -376,0 +383,1 @@
+	struct strvec excluded_prefixes;
@@ -418,0 +426,2 @@
+			if (ref_dir_is_excluded(entry->name, &iter->excluded_prefixes))
+				continue;
@@ -453,1 +462,1 @@
-		prime_ref_dir(dir, prefix);
+		prime_ref_dir(dir, prefix, &iter->excluded_prefixes);
@@ -487,1 +496,1 @@
-			prime_ref_dir(dir, refname);
+			prime_ref_dir(dir, refname, &iter->excluded_prefixes);
@@ -554,0 +564,1 @@
+	strvec_clear(&iter->excluded_prefixes);
@@ -566,1 +576,2 @@
-					      int prime_dir)
+					      int prime_dir,
+					      const char **exclude_patterns)
@@ -578,0 +590,7 @@
+	strvec_init(&iter->excluded_prefixes);
+	if (exclude_patterns)
+		for (size_t i = 0; exclude_patterns[i]; i++) {
+			const char *pattern = exclude_patterns[i];
+			if (!has_glob_specials(pattern) && !strchr(pattern, '\\'))
+				strvec_push(&iter->excluded_prefixes, pattern);
+		}
--- a/refs/ref-cache.h
+++ b/refs/ref-cache.h
@@ -204,7 +203,0 @@
-/*
- * Start iterating over references in `cache`. If `prefix` is
- * specified, only include references whose names start with that
- * prefix. If `prime_dir` is true, then fill any incomplete
- * directories before beginning the iteration. The output is ordered
- * by refname.
- */
@@ -214,1 +207,2 @@
-					      int prime_dir);
+					      int prime_dir,
+					      const char **exclude_patterns);
--- a/refs/files-backend.c
+++ b/refs/files-backend.c
@@ -1098,1 +1098,2 @@
-					      prefix, ref_store->repo, 1);
+					      prefix, ref_store->repo, 1,
+					      exclude_patterns);
@@ -1494,1 +1495,1 @@
-					refs->base.repo, 0);
+					refs->base.repo, 0, NULL);
@@ -1534,1 +1535,1 @@
-					refs->base.repo, 0);
+					refs->base.repo, 0, NULL);
