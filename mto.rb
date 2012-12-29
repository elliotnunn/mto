#!/usr/bin/env ruby

$: << File.dirname(__FILE__)

require 'logger'
require 'mto-torrent.rb'
require 'pathname'
require 'fileutils'

# Set up a global logger

$log = Logger.new(File.open('log.txt', File::WRONLY | File::APPEND | File::CREAT))
$log.level = Logger::DEBUG

# Parse command-line options
creation_sandbox = deletion_sandbox = false
dest_dirs = Hash.new { |hash, key| hash[key] = Pathname.new(FileUtils::mkdir_p(key)[0]).realpath }
edited_args = ARGV.clone

while edited_args.size > 0
  case
  when edited_args[0] == "--creation-sandbox"
    creation_sandbox = true
    used_arg_count = 1
  when edited_args[0] == "--deletion-sandbox"
    deletion_sandbox = true
    used_arg_count = 1
  when edited_args[0].match(/^--out-dir-(.+)$/)
    dest_dirs[$1] = Pathname.new(FileUtils::mkdir_p(edited_args[1])[0]).realpath
    used_arg_count = 2
  else
    break # no more recognisable options, so assume remaining args are paths to torrents
  end
  
  used_arg_count.times { edited_args.delete_at(0) }
end

$log.info { "MTO: #{edited_args.size} input paths, #{dest_dirs.size} output directories." }

# Create Torrent objects from paths remaining in edited_args
all_torrents = edited_args.map { |n| MTO::Torrent.new(Pathname.new(n).realpath) }

$log.info { "Created torrent objects." }

# Tell each Torrent object to "sort" itself into dest_dir
files_to_spare = []

all_torrents.each do |n|
  n.sort_out_children!(dest_dirs) do |create_at, target_relative, do_delete_existing, do_create_link|
    files_to_spare << create_at
    !creation_sandbox # returning true allows changes to fs
  end
end

$log.info { "Count of symlinks: " + files_to_spare.size.to_s }

# Cull the directory structure
unless deletion_sandbox
  $log.info { "Culling directory structure." }
  
  dest_dirs.each_value do |this_dir|
    
    MTO::cull_directory(this_dir) do |file| # this block returns policy as a Symbol for each file (Pathname) passed to it
      name = file.basename.to_s
      case
      when this_dir == file
        :spare_dowalk
      when files_to_spare.include?(file)
        :spare_dontwalk
      when ['.DS_Store', '.AppleDouble', '.AppleDesktop', 'Network Trash Folder', 'Temporary Items'].include?(name)
        :spare_ifparentlives
      when file.symlink?
        :delete
      else
        :delete_ifempty
      end # of case
    end # of cull_directory
    
  end # of dest_dirs.each_value
  
end # of unless deletion_sandbox

$log.info { "Signing off." }