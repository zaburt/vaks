$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "logger"
require "stringio"
require "tmpdir"
require "vaks"

def null_logger = Logger.new(File::NULL)
