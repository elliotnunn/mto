#!/usr/bin/env ruby

require 'pathname'
require 'yaml'
require 'fileutils'
require 'logger'

module MTO
  class TorrentChild
    REGEXEN = [
      # FOR explicitly SEASONED EPISODES (show name optional for all): S02E03, 2x03, Season 2 Episode 3
      #   The West Wing       S               02                      E               03                                            The Midterms
      /^  (?<show_name>.+?)?  S               (?<seas_no>\d{1,2}).*?  E               (?<ep_no>\d{1,2}(E\d{1,2})*)(?!\d)            (?<ep_name>.+)? /ix,
      #   The West Wing                       2                       x               03                                            The Midterms
      /^  (?<show_name>.+?)?           (?<!\d)(?<seas_no>\d{1,2})     x               (?<ep_no>\d{1,2}(x\d{1,2})*)(?!\d)            (?<ep_name>.+)? /ix,
      #   The West Wing       Season          2                       Episode         3                                             The Midterms
      /^  (?<show_name>.+?)?  Season.         (?<seas_no>\d{1,2}).*?  Episode.        (?<ep_no>\d{1,2})(?!\d)                       (?<ep_name>.+)? /ix,
    
      # FOR YEARED MOVIES (year must be sane. we prevent false-pos for more "liberal" tv show labelling)
      /^  (?<mov_name>.+?)      (?<!\d)  (?<year>(19\d\d|20[01]\d))  (?!\d) /ix,
    
      # FOR SEASONED EPISODES (show name optional): catches 3 digits, so exclude special cases of H.264, x264, 720p, etc
      #   Scrubs                              5                                       20                                            My Lunch
      /^  (?<show_name>.+?)?   (?<![a-z0-9]|h\.)(?<seas_no>\d)                       (?<ep_no>\d{2})(?![a-z0-9])                  (?<ep_name>.+)? /ix,
    
      # FOR ABSOLUTE-NUMBERED EPISODES (show name optional): pleeeease do not catch a tv series starting with digits!
      #   Firefly                                                     Episode/E       1                                             Serenity
      /^  (?<show_name>.+?)?                                          (Episode.|E)    (?<ep_no>\d{1,2}(?:E\d{1,2})*)(?!\d)          (?<ep_name>.+)? /ix,
      #                                                                               01                                            Serenity
      /^                                                                              (?<ep_no>\d{1,2})(?!\d)                       (?<ep_name>.+)  /ix,
    
      # FOR SEASON FOLDERS (show name optional)
      #   The West Wing       Season                  2
      /^  (?<show_name>.+?)?  (Season.|S)             (?<!\d)(?<seas_no>\d{1,2})(?!\d)                                                            /ix,
    ]
  
    attr_reader :path, :readable_name, :extname, :parent_attribs, :raw_attribs, :clean_attribs, :kind
    
    def initialize(path, root_parent, parent)
      $log.debug { path.to_s + ": Creating TorrentChild." }
      
      @path = path
      @root_parent = root_parent # might be nil
      @parent = parent # might be nil
      
      # slice up the name into extension and "bit-before-extension" in a reasonable fashion
      if !@path.directory? && %w(.avi .mp4 .m4v .mkv .rmvb).include?(@path.extname.to_s)
        @readable_name = File.basename(@path.to_s, @path.extname.to_s)
        @extname = @path.extname.to_s
      else
        @readable_name = @path.basename.to_s
        @extname = ""
      end
      
    end
    
    def get_parent_attribs!
      if @parent
        @parent_attribs = @parent.raw_attribs.clone
      else
        @parent_attribs = {}
      end
    end
    
    # Matches the filename to Regexps in REGEXEN until a match is found, then loads named captures into a Hash which is merged with @parent_attribs.
    # The resulting hash is saved to @raw_attribs and returned.
    def get_raw_attribs!
      hash = {}
      REGEXEN.each do |this_regexp|
        match = this_regexp.match(@readable_name)
        if match
          hash = Hash[match.names.map { |n| n.to_sym }.zip(match.captures)]
          hash.delete_if { |key, val| val == nil }
          break
        end
      end
      
      @raw_attribs = @parent_attribs.merge(hash)
      @raw_attribs
    end
  
    # Clones Hash @raw_attribs, and manipulates the value Strings to make them nice and readable. The result is saved in @clean_attribs and returned.
    # Cleaning policy for a value is determined by the key (a Symbol, e.g. :mov_name) only.
    def get_clean_attribs!
      @clean_attribs = @raw_attribs.clone # we want to leave @raw_attribs alone (for debugging) and modify @clean_attribs in place as a clone
      @clean_attribs.each { |key, val| @clean_attribs[key] = val.clone if val.class==String } # also want to modify each value in @clean_attribs in place as a clone
      
      ws = /[\.\-_ ]+/ # "whitespace"
      wsd = /[\.\-_ \(\)\[\]\{\}]+/ # "whitespace" + dirt
      word = /(?<= |^).+?(?= |$)/ # a word, surrounded by spaces/string boundaries
      
      # NB: positive lookbehind (?<= |^) and lookahead (?= |$) are more selective for word boundaries than \b
      
      # specific to movies
      unless @clean_attribs.include?(:mov_name) || @clean_attribs.include?(:ep_no)
        @clean_attribs[:mov_name] = @readable_name.clone
        @clean_attribs[:mov_name].sub!(/(hdtv|xvid|divx|dvd|tvrip|[xh].?264|\d{3,4}[pi]).+$/i, '')
        @clean_attribs[:mov_name].sub!(/[A-Z]{3}.+$/,'')
      end
      
      if @clean_attribs.include?(:mov_name)
        @clean_attribs[:mov_name].gsub!(wsd, ' ')
        @clean_attribs[:mov_name].strip!
        @clean_attribs[:mov_name].gsub!(word) { |n| n.capitalize }
      end
      
      # specific to shows
      if @clean_attribs.include?(:ep_no) && !@clean_attribs.include?(:show_name) && @root_parent != nil
        @clean_attribs[:show_name] = @root_parent.readable_name.clone
        @clean_attribs[:show_name].sub!(/(the[\.-_ ])?(complete[\.-_ ])?series.+/i, '')
        @clean_attribs[:show_name].sub!(/[\(\[\{].+/, '')
      end
      
      if @clean_attribs.include?(:show_name)
        @clean_attribs[:show_name].gsub!(wsd, ' ')
        @clean_attribs[:show_name].strip!
        @clean_attribs[:show_name].gsub!(/(?<= |^)[[:alpha:]]( [[:alpha:]])*(?= |$)/) { |n| n.gsub(' ', '') }
        @clean_attribs[:show_name].gsub!(word) { |n| n.capitalize }
        @clean_attribs[:show_name].sub!(/\d{4}$/) { |n| "(" + n + ")" }
      end
      
      if @clean_attribs.include?(:seas_no)
        @clean_attribs[:seas_no].sub!(/^0+/, '')
        # @clean_attribs[:seas_no] = @clean_attribs[:seas_no].rjust(2, '0')
      end
      
      if @clean_attribs.include?(:ep_no)
        @clean_attribs[:ep_no] = @clean_attribs[:ep_no].scan(/\d+/).map { |n| n.rjust(2, '0') }.join('x')
      end
      
      if @clean_attribs.include?(:ep_name)
        @clean_attribs[:ep_name].sub!(/^[\.\-_ \(\)\[\]\{\}]+/, '')
      end
      
      @clean_attribs
    end
    
    # Determines the kind  of the file based on its @clean_attribs hash, saves it to @kind (as a Symbol, e.g. :movie, :episode_absolute) and returns it.
    # Uses @clean_attribs (a hash produced by get_clean_attribs!).
    def get_kind!
      if %w(.avi .mp4 .m4v .mkv .rmvb).include?(@extname) &&  # a video file
        
        if @clean_attribs.include?(:ep_no) && @clean_attribs.include?(:seas_no) && @clean_attribs.include?(:show_name)
          @kind = :episode_season
        elsif @clean_attribs.include?(:ep_no) && @clean_attribs.include?(:show_name)
          @kind = :episode_absolute
        elsif @clean_attribs.include?(:ep_no) || @clean_attribs.include?(:seas_no) || @clean_attribs.include?(:show_name)
          @kind = nil
        elsif @clean_attribs.include?(:mov_name) && @clean_attribs.include?(:year)
          @kind = :movie_year
        elsif @clean_attribs.include?(:mov_name)
          @kind = :movie_noyear
        else
          @kind = nil
        end
        
      else
        @kind = nil
      end
    
      @kind
    end
    
    def get_out_paths!(dest_dirs)
      @out_paths = []
    
      case @kind
      when :movie_year
        @out_paths << dest_dirs['movies'] + "%s (%s)%s" % [@clean_attribs[:mov_name], @clean_attribs[:year], @extname]
      when :movie_noyear
        @out_paths << dest_dirs['movies'] + "%s%s"      % [@clean_attribs[:mov_name], @extname]
      when :episode_season
        @out_paths << dest_dirs['shows'] + "%s/%s %sx%s - \"%s\"%s"  % [@clean_attribs[:show_name], @clean_attribs[:show_name], @clean_attribs[:seas_no], @clean_attribs[:ep_no], @clean_attribs[:ep_name], @extname]
      when :episode_absolute
        @out_paths << dest_dirs['shows'] + "%s/%s E%s - \"%s\"%s"    % [@clean_attribs[:show_name], @clean_attribs[:show_name],                             @clean_attribs[:ep_no], @clean_attribs[:ep_name], @extname]
      end
      
      @out_paths
    end
  
    # Ensures that a relative symlink exists at each path in @out_paths (calculated by get_out_paths!).
    # Will delete a pre-existing file at the destination unless it is a symlink with the correct path. If a block is given then
    # it will be called after each path is iterated over, with the symlink path, relative target path, whether a pre-existing file was deleted and whether the
    # link needed to be created. No action is taken on the filesystem if a block is given that does not return true.
    def create_links!()
      @out_paths.each do |create_at|
        target_relative = @path.relative_path_from(create_at.parent)
      
        # Pathname#exist? follows symlinks, so a dangling symlink gives false!
        already_symlink = create_at.symlink?
        already_exist = create_at.exist?
      
        if (already_exist && !already_symlink) # || (already_symlink && create_at.readlink != target_relative)
          # already a non-symlink or a symlink with the wrong target
          do_delete_existing = true
          do_create_link = true
          $log.debug { "  already exists and is wrong... should delete" }
        elsif already_symlink
          # already the right symlink
          do_delete_existing = false
          do_create_link = false
          $log.debug { "  already exists and is right" }
        else
          # nothing there at all
          do_delete_existing = false
          do_create_link = true
          $log.debug { "  should create" }
        end
      
        # only proceed with irreversible operations if there is no block, or the block returns true explicitly
        go_ahead = yield(create_at, target_relative, do_delete_existing, do_create_link) == true
      
        if go_ahead
          create_at.parent.mkpath
          FileUtils::rm_rf(create_at.to_s) if do_delete_existing
          create_at.make_symlink(target_relative) if do_create_link # TO-DO: hard links and copying!
        end
      end
    end
  
    # Wraps get_kind!, get_clean_attribs!, get_out_paths! and create_links!(dest_dir, &block), to fully classify self and create
    # links to self based on parent_attribs. Takes dest_dirs (Hash) and optionally a block to pass to create_links!.
    def sort_out!(dest_dirs, &block)
      $log.debug { "Sorting out " + @path.to_s }
      
      get_parent_attribs!
      $log.debug { "  @parent_attribs = " + @parent_attribs.to_s }
      
      get_raw_attribs!
      $log.debug { "  @raw_attribs    = " + @raw_attribs.to_s }
      
      get_clean_attribs!
      $log.debug { "  @clean_attribs  = " + @clean_attribs.to_s }
      
      get_kind!
      $log.debug { "  @kind           = " + @kind.to_s }
      
      get_out_paths!(dest_dirs)
      $log.debug { "  @out_paths[0]   = " + @out_paths[0].to_s }
      
      if block_given?
        create_links!(&block)
      else
        create_links!
      end
    end
  
  end


  class Torrent
    attr_reader :path, :children
    
    # Class constructor. Takes a path for the new instance to encapsulate. Creates child TorrentChild objects, with the raw_attribs calculated for each.
    def initialize(path)
      $log = Logger.new(STDOUT) if $log == nil
      
      @path = Pathname.new(path)
    
      escaped_path = @path.to_s.gsub(/[\*\?\[\{]/) { |n| "\\" + n } # escape any glob-control characters
      child_paths = [@path] + Pathname.glob(escaped_path + "/**/*")
    
      hash_path_to_child = {}
      hash_path_to_child.default = nil
      
      # filter out certain children!
      blacklist = []
      bad_words = [/sample/i, /extra/i]
      child_paths.delete_if do |n|
        if n == @path
          false
        elsif blacklist.include?(n.parent)
          blacklist << n
          true
        else
          has_bad_word = false
          bad_words.each do |bad_word|
            has_bad_word ||= (n.basename.to_s.scan(bad_word).size > n.parent.basename.to_s.scan(bad_word).size)
            break if has_bad_word
          end
          blacklist << n if has_bad_word
          has_bad_word
        end
      end
      
      @children = child_paths.map do |child_path|
        parent = hash_path_to_child[child_path.parent] # might be nil
        root_parent = hash_path_to_child[@path] # might be nil
        
        child = TorrentChild.new(child_path, root_parent, parent)
        hash_path_to_child[child_path] = child
        
        child
      end
    end
  
    def sort_out_children!(dest_dirs, &block)
      @children.each { |this_child| this_child.sort_out!(dest_dirs, &block) }
    end
  end
  
  
  # Takes a directory (Pathname) and a block. Walks through the directory structure recursively, calls the block for each directory, and takes action specified by the block.
  # The block should return one of: :spare_dontwalk, :spare_dowalk, :spare_ifparentlives, :delete_ifempty, :delete.
  # This method returns true if the passed path was deleted; otherwise false.
  def self.cull_directory(start_at, &block)
    report_kind = yield start_at
    
    case report_kind
    when :spare_dontwalk
      can_delete, parent_can_be_deleted, can_check_children = false, false, false
    when :spare_dowalk
      can_delete, parent_can_be_deleted, can_check_children = false, false, true
    when :spare_ifparentlives
      can_delete, parent_can_be_deleted, can_check_children = false, true, false
    when :delete_ifempty
      can_delete, parent_can_be_deleted, can_check_children = true, true, true
    when :delete
      can_delete, parent_can_be_deleted, can_check_children = true, true, false
    end
    
    # can_check_children: can override previously-set values, and ensure that self and parent aren't deleted
    if can_check_children and start_at.directory?
      start_at.children.each do |child|
        child_not_deleted = !cull_directory(child, &block) # RECURSION!
        
        if child_not_deleted
          can_delete = false
          parent_can_be_deleted = false
          report_kind = :spare_notempty if report_kind == :delete_ifempty
        end
      end
    end
  
    report_kind = :delete_empty if report_kind == :delete_ifempty
    $log.debug { report_kind.to_s.ljust(20) + start_at.to_s }
    
    FileUtils.rm_rf(start_at.to_s) if can_delete
    
    return parent_can_be_deleted
  end
end