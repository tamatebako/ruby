# frozen_string_literal: true

# The msys spawn variant is a MECHANICAL fork, not a content divergence:
# patch selection (Tfs::PatchSelection#filter_platform) drops a neutral
# patch on msys when any msys-suffixed patch shares its target file, and
# process_c_clock_guard_msys targets process.c on the 3.2/3.3/3.4 lines.
# The msys carrier exists so the spawn hook survives that shadowing; its
# diff payload (from the `diff --git` line onward) must stay
# byte-identical to the neutral patch's.
#
# The failure this pins: the fork predated the spec 30 spawn-plan
# machinery, and ruby#107 updated only the neutral patch — so runtime
# 0.16.20 shipped 3.2/3.3/3.4 windows builds with NO spawn planner and
# NO shell-form plan head (packed-mn#254 windows: `'"java"' is not
# recognized`). Nothing in the source factory compiles the neutral
# patch's windows half, so only this byte-level gate sees the drift.
RSpec.describe "spawn patch msys parity" do
  patches_root = File.expand_path("../../patches", __dir__)

  def diff_payload(path)
    lines = File.readlines(path)
    start = lines.index { |line| line.start_with?("diff --git") }
    raise "#{path}: no diff --git line" if start.nil?

    lines[start..]
  end

  Dir[File.join(patches_root, "*", "process_c_tebako_spawn_msys.patch")].sort.each do |msys_path|
    line = File.basename(File.dirname(msys_path))

    it "#{line}: the msys carrier's diff payload is byte-identical to the neutral patch's" do
      neutral_path = File.join(patches_root, line, "process_c_tebako_spawn.patch")
      expect(File).to exist(neutral_path)
      expect(diff_payload(msys_path)).to eq(diff_payload(neutral_path))
    end
  end

  # The shadowing trap in the other direction: a line whose process.c
  # carries an msys-suffixed patch MUST have the spawn carrier, or the
  # whole hook silently drops out of that line's windows builds.
  Dir[File.join(patches_root, "*", "process_c_clock_guard_msys.patch")].sort.each do |guard_path|
    line = File.basename(File.dirname(guard_path))

    it "#{line}: the clock guard's process.c shadowing has a spawn carrier" do
      carrier = File.join(patches_root, line, "process_c_tebako_spawn_msys.patch")
      expect(File).to exist(carrier)
    end
  end
end
