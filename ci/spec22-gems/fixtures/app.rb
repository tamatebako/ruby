# frozen_string_literal: true

# app.rb — the FIXED classic-style sinatra app: the documented
# payload-side contract (spec 22 gem-kill notes) is `set :app_file,
# __FILE__`, which overrides the misdetected load-time value before
# `root`/`public_folder` are derived from it. Serves public/static.txt
# through sinatra's root-derived static handling (rack's file serving
# goes through ruby's patched IO, so the VFS path reads fine).

require "sinatra"

set :app_file, __FILE__

get "/hello" do
  "spec22-gems hello"
end
