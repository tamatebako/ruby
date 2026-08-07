# frozen_string_literal: true

RSpec.describe Tfs::SmokePlan do
  subject(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  # A real ReleaseDiff over a fake git: publishing v2, previous release v1.
  def diff_for(paths, tags: %w[v2 v1])
    git = lambda do |*args|
      case args[0]
      when "tag" then tags.empty? ? "" : "#{tags.join("\n")}\n"
      when "diff" then paths.join("\n")
      else raise Tfs::ReleaseDiff::Error, "unexpected git #{args.join(' ')}"
      end
    end
    Tfs::ReleaseDiff.new("v2", git: git)
  end

  it "smokes every line's newest version per shipped scenario on the first release" do
    legs = described_class.new(versions: versions, diff: diff_for([], tags: [])).legs
    expect(legs).to contain_exactly(
      { line: "3.3", version: "3.3.7", platform: "linux-gnu" },
      { line: "3.3", version: "3.3.7", platform: "linux-musl" },
      { line: "3.3", version: "3.3.7", platform: "msys" },
      { line: "3.4", version: "3.4.1", platform: "linux-gnu" },
      { line: "9.9", version: "9.9.9", platform: "linux-gnu" }
    )
  end

  it "smokes only the msys leg on an msys-only patch change" do
    legs = described_class.new(versions: versions, diff: diff_for(["patches/3.3/dir_c_memfs_msys.patch"])).legs
    expect(legs).to eq([{ line: "3.3", version: "3.3.7", platform: "msys" }])
  end

  it "smokes every scenario the line ships on a base patch change" do
    legs = described_class.new(versions: versions, diff: diff_for(["patches/3.3/io_c_tebako_includes.patch"])).legs
    expect(legs.map { |leg| leg[:platform] }).to contain_exactly("linux-gnu", "linux-musl", "msys")
    expect(legs.map { |leg| leg[:version] }.uniq).to eq(["3.3.7"])
  end

  it "smokes nothing on a darwin-only change (no shipped scenario)" do
    legs = described_class.new(versions: versions, diff: diff_for(["patches/3.3/configure_extstatic_bundle_loader_darwin.patch"])).legs
    expect(legs).to eq([])
  end

  it "narrows to one line with the line filter" do
    diff = diff_for(["patches/3.3/io_c_tebako_includes.patch", "patches/3.4/prism_compile_memfs.patch"])
    legs = described_class.new(versions: versions, diff: diff, line: "3.4").legs
    expect(legs).to eq([{ line: "3.4", version: "3.4.1", platform: "linux-gnu" }])
  end

  it "plans nothing when no patch set changed" do
    legs = described_class.new(versions: versions, diff: diff_for([])).legs
    expect(legs).to eq([])
  end
end
