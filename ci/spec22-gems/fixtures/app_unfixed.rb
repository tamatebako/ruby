# frozen_string_literal: true

# app_unfixed.rb — the same classic-style sinatra app WITHOUT
# `set :app_file, __FILE__`. When the tebako-runtime gem is loaded at
# boot, its Kernel#require hook frame is on the stack while sinatra 4.x
# runs its load-time caller_files app_file detection, so app_file is
# misdetected as the gem's lib/tebako-runtime.rb and root is derived
# under the gem's lib/ — public/static.txt is not there and the static
# fetch misses. This is the oracle pin for the documented payload-side
# fix; see README.md.

require "sinatra"

get "/hello" do
  "spec22-gems hello"
end
