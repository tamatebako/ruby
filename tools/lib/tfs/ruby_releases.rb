# frozen_string_literal: true

module Tfs
  # The official ruby releases (the ruby-lang.org downloads/releases table)
  # and the diff against the versions.yml set. Each table row carries the
  # official tarball URL, so URLs come from the listing itself.
  class RubyReleases
    RELEASES_URL = "https://www.ruby-lang.org/en/downloads/releases/"
    ROW_FORMAT = %r{href="(https://cache\.ruby-lang\.org/pub/ruby/\d+\.\d+/ruby-(\d+\.\d+\.\d+)\.tar\.gz)"}.freeze

    # One official release.
    class Release
      def initialize(name:, url:)
        @name = name
        @url = url
        @line = name.split(".")[0..1].join(".")
      end

      attr_reader :name, :url, :line
    end

    # Fetches and parses the official releases page.
    def self.fetch(url = RELEASES_URL)
      new(Tfs::HttpGet.body(url))
    end

    def initialize(html)
      @releases = html.scan(ROW_FORMAT).map { |url, name| Release.new(name: name, url: url) }.uniq(&:name).freeze
    end

    attr_reader :releases

    def names
      @releases.map(&:name)
    end

    def entry(name)
      release = @releases.find { |candidate| candidate.name == name }
      raise KeyError, "ruby #{name} is not an official release" if release.nil?

      release
    end

    # Released versions that are not onboarded yet: a newer patch release
    # of a line versions.yml tracks, or the latest release of an untracked
    # line inside the support window (>= the oldest tracked line). Older
    # patch releases and lines below the window are not candidates.
    # Sorted ascending (onboard oldest first).
    def new_versions(versions)
      max_of_line = versions.each_with_object({}) do |entry, acc|
        name = entry.name
        if acc[entry.line].nil? || Gem::Version.new(name) > Gem::Version.new(acc[entry.line])
          acc[entry.line] = name
        end
      end
      min_line = max_of_line.keys.min_by { |line| Gem::Version.new(line) }
      latest_of_line = @releases.group_by(&:line).to_h do |line, releases|
        [line, releases.map(&:name).max_by { |name| Gem::Version.new(name) }]
      end
      @releases
        .select { |release| candidate?(release, max_of_line, min_line, latest_of_line) }
        .sort_by { |release| Gem::Version.new(release.name) }
    end

    private

    def candidate?(release, max_of_line, min_line, latest_of_line)
      return false if Gem::Version.new(release.line) < Gem::Version.new(min_line)

      if max_of_line.key?(release.line)
        Gem::Version.new(release.name) > Gem::Version.new(max_of_line[release.line])
      else
        release.name == latest_of_line[release.line]
      end
    end
  end
end
