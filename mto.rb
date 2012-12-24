#!/usr/bin/env ruby

$: << File.dirname(__FILE__)

require 'logger'
require 'mto-torrent.rb'
require 'optparse'
require 'pathname'

# Set up a global logger
$log = Logger.new('log.txt', 'daily')
$log.level = Logger::INFO

# Parse command-line options
dest_dir = nil
sandbox_create = sandbox_delete = false

option_parser = OptionParser.new do |opts|
  opts.on("-o", "--out dest_dir", "Output location for symlinks.") do |x|
    dest_dir = Pathname.new(File.realpath(x))
  end
  
  opts.on("-d", "--[no-]debug", "Show debug logs?") do
    $log.level = Logger::DEBUG
  end
  
  opts.on("-sc", "--[no-]sandbox-create", "Prevent filesystem modification?") do
    sandbox_create = true
  end
  
  opts.on("-sd", "--[no-]sandbox-delete", "Prevent filesystem modification?") do
    sandbox_delete = true
  end
  
  opts.on("-h", "--help", "Display this screen") do
    puts opts
    exit
  end
end
option_parser.parse!

$log.info { "MTO. Will link to #{ARGV.size.to_s} in #{dest_dir.to_s}" }

# Create Torrent objects from paths remaining in ARGV
all_torrent_paths = ARGV.each.map { |n| Pathname.new(File.realpath(n)) }
all_torrents = all_torrent_paths.map { |n| MTO::Torrent.new(n) }

$log.info { "Created torrent objects." }

# Tell each Torrent object to "sort" itself into dest_dir
have_created_file = false
have_deleted_file = false
files_to_spare = []

all_torrents.each do |n|
  n.sort_out_children!(dest_dir) do |create_at, target_relative, do_delete_existing, do_create_link|
    have_created_file ||= do_create_link
    have_deleted_file ||= do_delete_existing
    files_to_spare << create_at
    !sandbox_create # returning true allows changes to fs
  end
end

$log.info { "Created anything? " + have_created_file.to_s }
$log.info { "Deleted anything? " + have_deleted_file.to_s }
$log.info { "Count of symlinks: " + files_to_spare.size.to_s }

# Cull the directory structure
$log.info { "Culling directory structure: " + dest_dir.to_s }

unless sandbox_delete
  MTO::cull_directory(dest_dir) do |file|
    name = file.basename.to_s
    if files_to_spare.include?(file)
      :spare_dontwalk
    elsif ['Network Trash Folder', 'Temporary Items', '.mto', 'All'].include?(name)
      :spare_dontwalk
    elsif /\[.*\]/.match(name)
      :spare_dontwalk
    elsif ['Shows', 'Movies', 'Downloads'].include?(name)
      :spare_dowalk
    elsif ['.DS_Store', '.AppleDouble', '.AppleDesktop'].include?(name)
      :spare_ifparentlives
    elsif file.symlink?
      :delete
    else
      :delete_ifempty
    end
  end
end

$log.info { "Signing off." }