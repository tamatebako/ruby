# frozen_string_literal: true

module Tfs
  # Semantic pair check for the msys scenario: a patched GNUmakefile whose
  # rubyw.exe recipe carries $(MUNICODE_FLAG) (-municode) makes the mingw
  # CRT startup call wWinMain, so the same tree MUST carry the
  # winmain_c_wwinmain_msys patch that renames WinMain to wWinMain —
  # and a tree whose recipe predates MUNICODE_FLAG must NOT carry it (the
  # patch does not apply to the old main()-based win32/winmain.c).
  # Upstream paired the two at 3.1.7 / 3.2.7 / 3.3.7. A patchlevel that
  # resolves one side without the other produces a tarball whose rubyw.exe
  # cannot link (the v0.2.22 windows pin-leg failures: 3.1.7, 3.2.9,
  # 3.2.10, 3.3.9, 3.3.10, 3.3.11 fell back to line bases carrying the
  # _7 GNUmakefile variant but no winmain overlay). Manifest-only check —
  # reads patch files, downloads nothing.
  class WinmainPairLint
    GNUMAKE_FEATURE = { 1 => "gnumakefile_in_pass1_msys", 2 => "gnumakefile_in_pass2_msys" }.freeze
    WINMAIN_FEATURE = "winmain_c_wwinmain_msys"
    MUNICODE_NEEDLE = "$(MUNICODE_FLAG)"

    def initialize(versions: Versions.new, selection: PatchSelection.new)
      @versions = versions
      @selection = selection
    end

    # Human-readable violations, one per (version, pass) that resolves the
    # two sides inconsistently. Empty when every msys version is paired.
    def errors
      @versions.select { |entry| entry.scenarios.include?("msys") }.flat_map { |entry| check(entry) }
    end

    def valid?
      errors.empty?
    end

    private

    def check(entry)
      [1, 2].flat_map do |pass|
        feature = GNUMAKE_FEATURE.fetch(pass)
        set = resolve(entry.name, pass)
        gnumake = set.find { |patch| patch.feature == feature }
        next [] if gnumake.nil?

        municode = File.read(gnumake.path).include?(MUNICODE_NEEDLE)
        winmain = set.any? { |patch| patch.feature == WINMAIN_FEATURE }
        next [] if municode == winmain

        ["#{entry.name} (msys pass#{pass}): #{feature} #{municode ? 'carries' : 'lacks'} $(MUNICODE_FLAG) " \
         "but #{WINMAIN_FEATURE} is #{winmain ? 'selected' : 'absent'} — " \
         "the -municode rubyw.exe recipe and the wWinMain patch must come in pairs"]
      end
    end

    def resolve(version_name, pass)
      @selection.for(version_name, platform: "msys", pass: pass)
    rescue PatchSelection::SelectionError => e
      raise PatchSelection::SelectionError.new("#{version_name}: cannot check msys pairing: #{e.message}",
                                               feature: e.feature, version_name: version_name)
    end
  end
end
