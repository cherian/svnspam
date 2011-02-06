#!/usr/bin/ruby -w
#$Id: svn_post_commit_hook.rb 11 2009-02-03 23:49:28Z mark@g.foster.cc $
#$URL: http://svnspam.googlecode.com/svn/trunk/svn_post_commit_hook.rb $
$svnlook_exe = "svnlook"  # default assumes the program is in $PATH

def usage(msg)
  $stderr.puts(msg)
  exit(1)
end


$tmpdir = ENV["TMPDIR"] || "/tmp"
$dirtemplate = "#svnspam.#{Process.getpgrp}.#{Process.uid}"
# arguments to pass though to 'svnspam.rb'
$passthrough_args = []

def make_data_dir
  dir = "#{$tmpdir}/#{$dirtemplate}-#{rand(99999999)}"
  Dir.mkdir(dir, 0700)
  dir
end

def init
  $datadir = make_data_dir

  # set PWD so that svnlook can create its .svnlook directory
  Dir.chdir($datadir)
end

def cleanup
  File.unlink("#{$datadir}/logfile")
  Dir.rmdir($datadir)
end

def send_email
  cmd = File.dirname($0) + "/svnspam.rb"
  unless system(cmd, "#{$datadir}/logfile", *$passthrough_args)
    fail "problem running '#{cmd}'"
  end
end

# Like IO.popen, but accepts multiple arguments like Kernel.exec
# (So no need to escape shell metacharacters)
def safer_popen(*args)
  IO.popen("-") do |pipe|
    if pipe==nil
      exec(*args)
    else
      yield pipe
    end
  end
end


# Process the command-line arguments in the given list
def process_args
  require 'getoptlong'

  opts = GetoptLong.new(
    [ "--to",     "-t", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--config", "-c", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--debug",  "-d", GetoptLong::NO_ARGUMENT ],
    [ "--from",   "-u", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--charset",      GetoptLong::REQUIRED_ARGUMENT ]
  )

  opts.each do |opt, arg|
    if ["--to", "--config", "--from", "--charset"].include?(opt)
      $passthrough_args << opt << arg
    end
    if ["--debug"].include?(opt)
      $passthrough_args << opt
    end
    $config = arg if opt=="--config"
    $debug = true if opt == "--debug"
  end

  $repository = ARGV[0]
  $revision = ARGV[1]

  unless $revision =~ /^\d+$/
    usage("revision must be an integer: #{revision.inspect}")
  end
  $revision = $revision.to_i

  unless FileTest.directory?($repository)
    usage("no such directory: #{$repository.inspect}")
  end
end

# runs the given svnlook subcommand
def svnlook(cmd, revision, *args)
  rev = revision.to_s
  safer_popen($svnlook_exe, cmd, $repository, "-r", rev, *args) do |io|
    yield io
  end
end

class Change
  def initialize(filechange, propchange, path)
    @filechange = filechange
    @propchange = propchange
    @path = path
  end

  attr_accessor :filechange, :propchange, :path

  def property_change?
    @propchange != " "
  end

  def file_change?
    @filechange != "_"
  end

  def addition?
    @filechange == "A"
  end

  def deletion?
    @filechange == "D"
  end
end


def each_changed
  svnlook("changed", $revision) do |io|
    io.each_line do |line|
      line =~ /^(.)(.)  (.*)$/
      yield Change.new($1, $2, $3)
    end
  end
end



# Line-oriented access to an underlying IO object.  Remembers 'current' line
# for lookahead during parsing.
class LineReader
  def initialize(io)
    @io = io
  end

  def current
    @line
  end

  def next_line
    (@line = @io.gets) != nil
  end

  def assert_next(re=nil)
    raise "unexpected end of text" unless next_line
    unless re.nil?
      raise "unexpected #{lines.current.inspect}" unless @line =~ re
    end
    $~
  end
end


def read_modified_diff(out, lines, path)
  lines.assert_next(/^=+$/)
  m = lines.assert_next(/^---.*\(rev (\d+)\)$/)
  prev_rev = m[1].to_i
  diff1 = lines.current
  m = lines.assert_next(/^\+\+\+.*\(rev (\d+)\)$/)
  next_rev = m[1].to_i
  diff2 = lines.current
  out.puts "#V #{prev_rev},#{next_rev}"
  out.puts "#M #{path}"
  out.puts "#U #{diff1}"
  out.puts "#U #{diff2}"
  while lines.next_line && lines.current =~ /^[-\+ @\\]/
    out.puts "#U #{lines.current}"
  end
end

def read_added_diff(out, lines, path)
  lines.assert_next(/^=+$/)
  m = lines.assert_next(/^---.*\(rev (\d+)\)$/)
  prev_rev = m[1].to_i
  diff1 = lines.current
  m = lines.assert_next(/^\+\+\+.*\(rev (\d+)\)$/)
  next_rev = m[1].to_i
  diff2 = lines.current
  out.puts "#V NONE,#{next_rev}"
  out.puts "#A #{path}"
  out.puts "#U #{diff1}"
  out.puts "#U #{diff2}"
  while lines.next_line && lines.current =~ /^[-\+ @\\]/
    out.puts "#U #{lines.current}"
  end
end

def read_deleted_diff(out, lines, path)
  lines.assert_next(/^=+$/)
  m = lines.assert_next(/^---.*\(rev (\d+)\)$/)
  prev_rev = m[1].to_i
  diff1 = lines.current
  m = lines.assert_next(/^\+\+\+.*\(rev (\d+)\)$/)
  next_rev = m[1].to_i
  diff2 = lines.current
  out.puts "#V #{prev_rev},NONE"
  out.puts "#R #{path}"
  out.puts "#U #{diff1}"
  out.puts "#U #{diff2}"
  while lines.next_line && lines.current =~ /^[-\+ @\\]/
    out.puts "#U #{lines.current}"
  end
end

def read_property_lines(path, prop_name, revision)
  lines = []
  svnlook("propget", revision, prop_name, path) do |io|
    io.each_line do |line|
      lines << line.chomp
    end
  end
  lines
end

def assert_prop_match(a, b)
  if a != b
    raise "property mismatch: #{a.inspect}!=#{b.inspect}"
  end
end

def munch_prop_text(path, prop_name, revision, lines, line0)
  prop = read_property_lines(path, prop_name, revision)
  assert_prop_match(line0, prop.shift)
  prop.each do |prop_line|
    lines.assert_next
    assert_prop_match(lines.current.chomp, prop_line)
  end
end

def read_properties_changed(out, lines, path)
  lines.assert_next(/^_+$/)
  return unless lines.next_line
  while true
    break unless lines.current =~ /^Name: (.+)$/
    prop_name = $1
    m = lines.assert_next(/^   ([-+]) (.*)/)
    op = m[1]
    line0 = m[2]
    if op == "-"
      munch_prop_text(path, prop_name, $revision-1, lines, line0)
      if lines.next_line && lines.current =~ /^   \+ (.*)/
	munch_prop_text(path, prop_name, $revision, lines, $1)
	lines.next_line
      end
    else  # op == "+"
      munch_prop_text(path, prop_name, $revision, lines, line0)
      lines.next_line
    end
  end
end

def handle_copy(out, lines, path, from_ref, from_file)
  # TODO: handle file copies in email
end


def process_svnlook_log(file)
  svnlook("log", $revision) do |io|
    io.each_line do |line|
      file.puts("#> #{line}")
    end
  end
end

def process_svnlook_diff(file)
  svnlook("diff", $revision) do |io|
    lines = LineReader.new(io)
    while lines.next_line
      if lines.current =~ /^Modified:\s+(.*)/
	read_modified_diff(file, lines, $1)
      elsif lines.current =~ /^Added:\s+(.*)/
	read_added_diff(file, lines, $1)
      elsif lines.current =~ /^Copied:\s+(.*) \(from rev (\d+), (.*)\)$/
	handle_copy(file, lines, $1, $2, $3)
      elsif lines.current =~ /^Deleted:\s+(.*)/
	read_deleted_diff(file, lines, $1)
      elsif lines.current =~ /^Property changes on:\s+(.*)/
	read_properties_changed(file, lines, $1)
      #elsif lines.current == "\n"
	# ignore
      #elsif lines.current =~ "=====.*\n"
      #  # ignore
      # else
 	##raise "unable to parse line #{lines.current.inspect}"
	# just ignore
      end
    end
  end
end

def process_commit()
    File.open("#{$datadir}/logfile", File::WRONLY|File::CREAT) do |file|
      process_svnlook_log(file)
      process_svnlook_diff(file)
    end
end


def main
  init()
  process_args()
  process_commit()
  send_email()
  cleanup()
end


main
