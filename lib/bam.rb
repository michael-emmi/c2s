#!/usr/bin/env ruby

require 'set'
require 'optparse'
require_relative 'bam/version'
require_relative 'bam/prelude'
require_relative 'bam/frontend'
require_relative 'bpl/parser.tab'
require_relative 'bpl/ast/scope'
require_relative 'bpl/ast/binding'
require_relative 'bpl/ast/trace'
require_relative 'bpl/pass'
require_relative 'z3/model'


PASSES = [:analysis, :transformation]


def load_passes
  root = File.expand_path(File.dirname(__FILE__))
  Dir.glob(File.join(root,'bpl',"{#{PASSES * ","}}",'*.rb')).each do |lib|
    require_relative lib
    name = File.basename(lib,'.rb')
    kind = File.basename File.dirname(lib)
    klass = "Bpl::#{kind.capitalize}::#{name.classify}"
    @passes[name.to_sym] = Object.const_get(klass)
  end
end


def source_file_options(files)
  # parse @bam-options comments in the source file(s) for additional options
  opts = []
  files.each do |f|
    next unless File.exist?(f)
    File.readlines(f).grep(/@bam-options (.*)/) do |line|
      line.gsub(/.* @bam-options (.*)/,'\1').split.reverse.each do |arg|
        opts << arg
      end
    end
  end
  opts
end


def dependencies(pass)
  pass.class.depends.map do |p|
    fail "Unknown pass #{p}" unless @passes[p]
    dependencies(@passes[p].new)
  end.flatten + [pass]
end


def command_line_options
  arguments = {}

  OptionParser.new do |opts|

    opts.banner = "Usage: #{File.basename $0} [options] FILE(s)"

    opts.separator ""
    opts.separator "Basic options:"

    opts.on("-h", "--help", "Show this message") do |v|
      puts opts
      exit
    end

    opts.on("--version", "Show version") do
      puts "#{File.basename $0} version #{BAM::VERSION || "??"}"
      exit
    end

    opts.on("-v", "--[no-]verbose", "Run verbosely? (default #{$verbose})") do |v|
      $verbose = v
      $quiet = !v
    end

    opts.on("-q", "--[no-]quiet", "Run quietly? (default #{$quiet})") do |q|
      $quiet = q
      $verbose = !q
    end

    opts.on("-w", "--[no-]warnings", "Show warnings? (default #{$show_warnings})") do |w|
      $show_warnings = w
    end

    opts.on("-k", "--[no-]keep-files", "Keep intermediate files? (default #{$keep})") do |v|
      $keep = v
    end

    opts.on("-o", "--output-file FILENAME") do |f|
      @output_file = f
    end

    PASSES.each do |kind|
      opts.separator ""
      opts.separator "#{kind.to_s.capitalize} passes:"

      @passes.each do |name,klass|
        next unless klass.name.split("::")[0..-2].last.downcase.to_sym == kind
        klass.flags.each do |f|
          opts.on(*f[:args]) do |*args|
            f[:blk].call(*args) if f[:blk]
            @stages << name if f == klass.flags.first
          end
        end
      end
    end

    opts.separator ""
  end
end

begin

  @passes = {}
  @stages = []
  @output_file = nil

  unless $quiet
    info "BAM! BAM! Boogieman version #{BAM::VERSION}".bold,
      "#{" " * 20}copyright (c) 2015, Michael Emmi".bold
    info
  end

  load_passes
  ARGV.unshift(*source_file_options(ARGV.select{|f| File.extname(f) == '.bpl'}))
  command_line_options.parse!

  abort "Must specify a single source file." unless ARGV.size == 1
  src = ARGV[0]
  abort "Source file '#{src}' does not exist." unless File.exists?(src)

  src = timed 'Front-end' do
    BAM::process_source_file(src)
  end

  programs = []
  programs << (timed('Parsing') {BoogieLanguage.new.parse(File.read(src))})
  programs.first.source_file = src

  analysis_cache = Hash.new
  transformation_cache = Hash.new
  args = Hash.new # TODO from the command line

  until @stages.empty? do
    name = @stages.shift
    next if analysis_cache.include?(name)
    next if transformation_cache.include?(name)
    klass = @passes[name]
    deps = klass.depends - analysis_cache.keys - transformation_cache.keys
    if deps.empty?
      timed name do
        pass = klass.new(
          args.merge(analysis_cache.select{|a| klass.depends.include?(a)})
        )
        updated = false
        programs.dup.each do |program|
          res = pass.run!(program)
          if res.nil?

          elsif res.is_a?(Array) && res.first.is_a?(Program)
            programs = res

          elsif res.is_a?(Array) && res.first.is_a?(Symbol)
            @stages.unshift(*res)

          else
            updated |= res
          end
        end
        transformation_cache[name] = pass if pass.destructive?
        analysis_cache.clear if pass.destructive? && updated
        analysis_cache[name] = pass
      end
    else
      @stages.unshift(name)
      @stages.unshift(*deps.reject{|d| @passes[d].destructive?})
      @stages.unshift(*deps.select{|d| @passes[d].destructive?})
    end
  end

  if @output_file
    timed('Writing transformed program') do
      $temp.delete @output_file
      File.write(@output_file, programs * "---\n")
    end
  elsif $stdout.tty?
    programs.each do |program|
      puts "--- "
      puts program.hilite
    end
  else
    program.each do |program|
      puts "--- ".comment
      puts program
    end
  end

rescue Interrupt

rescue ParseError => e
  unless e.message.match(/parse error on value \#<.* @line=(?<line>\d+)> \("(?<token>.*)"\)/) do |m|
    line_no = m[:line].to_i
    File.open(src) do |f|
      line_no.times { f.gets }
      abort("parse error at token \"#{m[:token]}\" on line #{line_no}:\n\n  #{$_}")
    end
  end
    abort("unidentified parse error: #{e.message.strip}")
  end

ensure
  $temp.each{|f| File.unlink(f) if File.exists?(f)} unless $keep
end
