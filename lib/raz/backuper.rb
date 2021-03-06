
require 'yaml'
require 'colorize'
require_relative 'file_operations'
require_relative 'entries'


module Raz
  class Backuper
    # @return [String]
    #
    attr_reader :destination_path

    # @return [Array<DirEntry | FileEntry>]
    #
    attr_reader :parsed_entries

    # @param [Config] config
    #
    def initialize(config, destination_path)
      @config = config
      @destination_path = File.expand_path(destination_path)
    end

    def investigate
      @file_system = FileSystem.new
      @parsed_entries = []

      # process all items from configuration file
      @config.items.each do |item|
        process_item(item)
      end
    end

    # Main method to back all files from configuration
    #
    def backup
      FileUtils.mkdir_p(@destination_path)

      dest_contents = FileOperations.dir_entries(@destination_path)

      unless dest_contents.empty?
        raise "Can only operate on empty or non-existing directory! Directory #{@destination_path} contains: #{dest_contents}"
      end

      # run before procs
      (@config.procs[:before_backup] || []).each do |proc|
        instance_eval(&proc)
      end

      investigate if @parsed_entries.nil?

      @copied_paths = []

      @parsed_entries.each do |entry|
        copy_entry_to_dest(entry)
      end

      # save info for restorer
      save_info

      # backup config folder
      FileOperations.copy_item(File.dirname(@config.path), @destination_path)
      FileUtils.mv(File.join(@destination_path, CONFIG_FOLDER_BASE_PATH), File.join(@destination_path, BACKUP_CONFIG_FOLDER_BASE_PATH))

      # run after procs
      (@config.procs[:after_backup] || []).each do |proc|
        instance_eval(&proc)
      end
    end

    private

    # @param item [Raz::Items::Group] item to process
    #
    def process_item(item)
      @current_item = item
      @ignored_items = (@config.ignored_paths + @current_item.ignored_paths).uniq.map { |p| File.expand_path(p) }

      puts "Processing group #{item.name}"

      item.paths.each do |requirement_path|
        _process_path(requirement_path)
      end

      @ignored_items = nil
      @current_item = nil
    end

    # @param [String] path
    #
    def _process_path(path)
      print "  Processing requirement path #{path} ... "

      abs_path = File.expand_path(path)

      if File.directory?(abs_path)
        process_directory(abs_path)
        puts 'Success'.green
      elsif File.file?(abs_path)
        process_file(abs_path)
        puts 'Success'.green
      elsif %w(* ? { } [ ]).any? { |sym| abs_path.include?(sym) }
        found = Dir.glob(abs_path)
        found.each do |file|
          process_file(file)
        end

        puts 'Success'.green unless found.empty?
        puts 'Nothing found'.yellow if found.empty?
      else
        puts "Doesn't exist -> skipping".yellow
      end
    end

    def _ok_path?(path)
      @ignored_items.all? do |ignore_path|
        !File.fnmatch(ignore_path, path, File::FNM_PATHNAME)
      end
    end

    def _process_directory(path)
      return unless File.directory?(path)

      dir = @file_system.add_dir(path)

      FileOperations.dir_entries(path).each do |subitem|
        subitem_abs_path = File.join(path, subitem)

        if File.directory?(subitem_abs_path)
          dir[subitem] = _process_directory(subitem_abs_path)
        elsif File.file?(subitem_abs_path)
          file_entry = _process_file(subitem_abs_path)

          if file_entry.nil?
            dir.ignored_entries[subitem] = FileEntry.new(subitem, subitem_abs_path)
          else
            dir[subitem] = file_entry
          end
        end
      end

      dir
    end

    # @param [String] path
    #
    def process_directory(path)
      entry = _process_directory(path)
      @parsed_entries << entry unless entry.nil?
    end

    # @param [String] path
    #
    def _process_file(path)
      return unless File.file?(path)

      @file_system.add_file(path) if _ok_path?(path)
    end

    # @param [String] path
    #
    def process_file(path)
      entry = _process_file(path)
      @parsed_entries << entry unless entry.nil?
    end

    def copy_entry_to_dest(entry)
      dest_path = destination_path_from(entry.absolute_path)
      dest_dir  = File.dirname(dest_path)
      src_path  = entry.absolute_path
      FileUtils.mkdir_p(dest_dir)

      case entry
      when FileEntry
        puts "Copying file #{src_path}".green
        FileOperations.copy_item(src_path, dest_path)
        @copied_paths << src_path
      when DirEntry
        if entry.recursive_ignored_empty?
          puts "Copying directory #{src_path}".green
          FileOperations.copy_item(src_path, dest_path)
          @copied_paths << src_path
        else
          sub_entries = entry.recursive_entries
          return if sub_entries.empty?

          puts "Start copying all files in directory #{src_path}".green
          sub_entries.each do |sub_entry|
            copy_entry_to_dest(sub_entry)
          end
        end
      end
    end

    # @param source_path [String] path to file/folder
    #
    # @return [String]
    #
    def destination_path_from(source_path)
      File.join(@destination_path, BACKUP_DATA_BASE_PATH, source_path)
    end

    def save_info
      info = {
        env: ENV.to_hash,
        copied_paths: @copied_paths,
        orig_config_path: @config.path,
      }

      File.write(File.join(@destination_path, BACKUP_INFO_BASE_PATH), info.to_yaml)
    end
  end
end
