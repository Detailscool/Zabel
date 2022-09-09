# frozen_string_literal: true

require 'zabel/version'

require 'xcodeproj'
require 'digest'
require 'set'
require 'open3'
require 'find'
require 'yaml'
require 'pathname'

module Zabel
  class Error < StandardError; end

  BUILD_KEY_SYMROOT = 'SYMROOT'
  BUILD_KEY_CONFIGURATION_BUILD_DIR = 'CONFIGURATION_BUILD_DIR'
  BUILD_KEY_TARGET_BUILD_DIR = 'TARGET_BUILD_DIR'
  BUILD_KEY_OBJROOT = 'OBJROOT'
  BUILD_KEY_TARGET_TEMP_DIR = 'TARGET_TEMP_DIR'
  BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR = 'PODS_XCFRAMEWORKS_BUILD_DIR'
  BUILD_KEY_MODULEMAP_FILE = 'MODULEMAP_FILE'
  BUILD_KEY_SRCROOT = 'SRCROOT'
  BUILD_KEY_FULL_PRODUCT_NAME = 'FULL_PRODUCT_NAME'

  STATUS_HIT = 'hit'
  STATUS_MISS = 'miss'
  STATUS_MISS_AND_READY = 'miss_ready'

  STAGE_CLEAN = 'clean'
  STAGE_EXTRACT = 'extract'
  STAGE_PRINTENV = 'printenv'
  STAGE_PRE = 'pre'
  STAGE_POST = 'post'

  FILE_NAME_MESSAGE = 'message.txt'
  FILE_NAME_CONTEXT = 'context.yml'
  FILE_NAME_PRODUCT = 'product.tar'
  FILE_NAME_TARGET_CONTEXT = 'xcodecache_target_context.yml'

  BACKUP_PBXPROJ = 'project.xcodecache_backup_pbxproj'

  $SRC_ROOT = ''

  def self.zabel_get_cache_root
    cache_root = ENV['XcodeCache_CACHE_ROOT']
    return cache_root if cache_root&.size&.positive?

    "#{Dir.home}/XcodeCache"
  end

  def self.zabel_get_cache_count
    cache_count = ENV['XcodeCache_CACHE_COUNT']
    return cache_count.to_i if cache_count && (cache_count.to_i.to_s == cache_count)

    10000
  end

  def self.zabel_should_not_detect_module_map_dependency
    # By default, zabel detects module map dependency.
    # However, there are bugs of xcodebuild or swift-frontend, which emits unnecessary and incorrect modulemap dependencies.
    # To test by run "ruby test/one.rb test/todo/modulemap_file/Podfile"
    # To avoid by set "export ZABEL_NOT_DETECT_MODULE_MAP_DEPENDENCY=YES"
    zabel_should_not_detect_module_map_dependency = ENV['XcodeCache_NOT_DETECT_MODULE_MAP_DEPENDENCY']
    return true if zabel_should_not_detect_module_map_dependency == 'YES'

    false
  end

  def self.zabel_get_min_source_file_count
    # By default, zable caches targets which count of source files is greater than or equal 1.
    # You can set this value to 0 or more than 1 to achieve higher speed.
    min_source_file_count = ENV['XcodeCache_MIN_SOURCE_FILE_COUNT']
    if min_source_file_count && (min_source_file_count.to_i.to_s == min_source_file_count)
      return min_source_file_count.to_i
    end

    1
  end

  def self.zabel_get_projects
    # TODO: to support more project, not only Pods
    pods_project = Xcodeproj::Project.open('Pods/Pods.xcodeproj')
    wrapper_project_paths = zabel_get_wrapper_project_paths(pods_project)
    wrapper_projects = []
    wrapper_project_paths.each do |path|
      next if path.end_with? 'Pods/Pods.xcodeproj'

      project = Xcodeproj::Project.open(path)
      wrapper_projects.push project
    end
    (wrapper_projects + [pods_project])
  end

  def self.zabel_get_wrapper_project_paths(project)
    wrapper_projects = project.files.select { |file| file.last_known_file_type == 'wrapper.pb-project' }
    wrapper_project_paths = []
    wrapper_projects.each do |wrapper_project_file|
      wrapper_project_file_path = wrapper_project_file.real_path.to_s
      wrapper_project_paths.push wrapper_project_file_path
    end
    wrapper_project_paths.uniq
  end

  def self.zabel_can_cache_target(target)
    if target.name.start_with? 'Pods-'
      puts "[XcodeCache] skip #{target.name}"
      return false
    end
    if target.instance_of?(Xcodeproj::Project::Object::PBXNativeTarget)
      # see https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/constants.rb#L145
      if (target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:bundle]) ||
         (target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:static_library]) ||
         (target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:framework])
        return true
      else
        puts "[XcodeCache] skip #{target.name} #{target.class} #{target.product_type}"
      end
    else
      puts "[XcodeCache] skip #{target.name} #{target.class}"
    end
    false
  end

  # def self.zabel_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
  #   dependency_files = []
  #   Dir.glob("#{intermediate_dir}/**/*.d").each do |dependency_file|
  #     content = File.read(dependency_file)
  #     # see https://github.com/ccache/ccache/blob/master/src/Depfile.cpp#L141
  #     # and this is a simple regex parser enough to get all files, as far as I know.
  #     files = content.scan(/(?:\S(?:\\ )*)+/).flatten.uniq
  #     files -= ['dependencies:', '\\', ':']
  #
  #     files.each do |file|
  #       file = file.gsub('\\ ', ' ')
  #
  #       unless File.exist? file
  #         unless File.exist? "#{$SRC_ROOT}/#{file}"
  #           puts "[XcodeCache/E] #{target.name} #{file} should exist in dependency file #{dependency_file} in #{intermediate_dir}/**/*.d"
  #           return []
  #         end
  #       end
  #
  #       if file.start_with?("#{intermediate_dir}/") ||
  #          file.start_with?("#{product_dir}/")
  #         next
  #       end
  #
  #       next if xcframeworks_build_dir&.size&.positive? && file.start_with?("#{xcframeworks_build_dir}/")
  #
  #       dependency_files.push file
  #     end
  #   end
  #   dependency_files.uniq
  # end

  def self.zabel_get_target_source_files(target)
    files = []
    target.source_build_phase.files.each do |file|
      file_path = file.file_ref.real_path.to_s
      files.push file_path
    end
    target.headers_build_phase.files.each do |file|
      file_path = file.file_ref.real_path.to_s
      files.push file_path
    end
    target.resources_build_phase.files.each do |file|
      file_path = file.file_ref.real_path.to_s
      files.push file_path
    end
    expand_files = []
    files.uniq.each do |file|
      next unless File.exist? file

      if File.file? file
        expand_files.push file
      else
        Find.find(file).each do |file_in_dir|
          expand_files.push file_in_dir if File.file? file_in_dir
        end
      end
    end
    expand_files.uniq
  end

  def self.zabel_get_content_without_pwd(content)
    content.gsub("#{Dir.pwd}/", '').gsub(/#{Dir.pwd}(\W|$)/, '\1')
  end

  $zabel_file_md5_hash = {}

  def self.zabel_get_file_md5(file)
    return $zabel_file_md5_hash[file] if $zabel_file_md5_hash.key? file

    if File.exist? file
      md5 = Digest::MD5.hexdigest(File.read(file))
      $zabel_file_md5_hash[file] = md5
      md5
    elsif File.exist? "#{$SRC_ROOT}/#{file}"
      md5 = Digest::MD5.hexdigest(File.read("#{$SRC_ROOT}/#{file}"))
      $zabel_file_md5_hash[file] = md5
      md5
    else
      raise "no file #{file}"
    end
  end

  def self.zabel_keep
    file_list = Dir.glob("#{zabel_get_cache_root}/*")
    file_time_hash = {}
    file_list.each do |file|
      file_time_hash[file] = File.mtime(file)
    end
    file_list = file_list.sort_by { |file| - file_time_hash[file].to_f }
    puts "[XcodeCache] keep cache #{file_list.size} #{Open3.capture3("du -sh #{zabel_get_cache_root}")[0]}"

    if file_list.size > 1
      puts "[XcodeCache] keep oldest #{file_time_hash[file_list.last]} #{file_list.last}"
      puts "[XcodeCache] keep newest #{file_time_hash[file_list.first]} #{file_list.first}"
    end

    if file_list.size > zabel_get_cache_count
      file_list_remove = file_list[zabel_get_cache_count..(file_list.size - 1)]
      file_list_remove.each do |file|
        raise unless system "rm -rf \"#{file}\""
      end
    end
  end

  def self.zabel_clean_backup_project(project)
    command = "rm -rf \"#{project.path}/#{BACKUP_PBXPROJ}\""
    raise unless system command
  end

  def self.zabel_backup_project(project)
    command = "cp \"#{project.path}/project.pbxproj\" \"#{project.path}/#{BACKUP_PBXPROJ}\""
    raise unless system command
  end

  def self.zabel_restore_project(project)
    if File.exist? "#{project.path}/#{BACKUP_PBXPROJ}"
      command = "mv \"#{project.path}/#{BACKUP_PBXPROJ}\" \"#{project.path}/project.pbxproj\""
      raise unless system command
    end
  end

  $zabel_podfile_spec_checksums = nil

  def self.zabel_get_target_md5_content(project, target, configuration_name, argv, source_files)
    if !$zabel_podfile_spec_checksums && (File.exist? 'Podfile.lock')
      podfile_lock = YAML.load(File.read('Podfile.lock'))
      $zabel_podfile_spec_checksums = podfile_lock['SPEC CHECKSUMS']
    end

    project_configuration = project.build_configurations.detect { |config| config.name == configuration_name }
    project_configuration_content = project_configuration.pretty_print.to_yaml
    project_xcconfig = ''
    if project_configuration.base_configuration_reference
      config_file_path = project_configuration.base_configuration_reference.real_path.to_s
      if File.exist? config_file_path
        project_xcconfig = File.read(config_file_path).lines.reject do |line|
          line.include? '_SEARCH_PATHS'
        end.sort.join('')
      end
    end

    target_configuration = target.build_configurations.detect { |config| config.name == configuration_name }
    target_configuration_content = target_configuration.pretty_print.to_yaml
    target_xcconfig = ''
    if target_configuration.base_configuration_reference
      config_file_path = target_configuration.base_configuration_reference.real_path.to_s
      if File.exist? config_file_path
        target_xcconfig = File.read(config_file_path).lines.reject do |line|
          line.include? '_SEARCH_PATHS'
        end.sort.join('')
      end
    end

    first_configuration = []
    build_phases = []
    build_phases.push target.source_build_phase if target.methods.include? :source_build_phase
    build_phases.push target.resources_build_phase if target.methods.include? :resources_build_phase
    build_phases.each do |_|
      target.source_build_phase.files_references.each do |files_reference|
        if files_reference.instance_of?(Xcodeproj::Project::Object::PBXVariantGroup)
          files_reference.files.each do |file_ref_in_group|
            file_ref_in_group.build_files.each do |build_file|
              if build_file.settings.instance_of?(Hash)
                first_configuration.push "#{File.basename(build_file.file_ref.real_path.to_s)}\n#{build_file.settings.to_yaml}"
              end
            end
          end
        elsif files_reference.instance_of?(Xcodeproj::Project::PBXFileReference)
          files_reference.build_files.each do |build_file|
            if build_file.settings.instance_of?(Hash)
              first_configuration.push "#{File.basename(build_file.file_ref.real_path.to_s)}\n#{build_file.settings.to_yaml}"
            end
          end
        elsif files_reference.instance_of?(Xcodeproj::Project::Object::XCVersionGroup)
          first_configuration.push files_reference.to_s
        else
          puts "can't find type: #{files_reference}"
        end
      end
    end
    first_configuration_content = first_configuration.sort.uniq.join("\n")

    key_argv = []

    # TODO: to add more and test more
    # However, you can control your cache keys manually by using pre and post.
    temp_path_list = ['-derivedDataPath', '-archivePath', '--derived_data_path', '--archive_path', '--build_path']
    argv.each_with_index do |arg, index|
      next if temp_path_list.include? arg
      next if index.positive? && temp_path_list.include?(argv[index - 1])
      next if arg.start_with? 'DSTROOT='
      next if arg.start_with? 'OBJROOT='
      next if arg.start_with? 'SYMROOT='

      key_argv.push arg
    end

    source_md5_list = []
    # zabel built-in verison, which will be changed for incompatibility in the future
    source_md5_list.push "XcodeCache cache version : #{Zabel::CACHE_VERSION}"
    source_md5_list.push "ARGV : #{key_argv}"

    # TODO: to get a explicit spec name from a target.
    target_possible_spec_names = []
    if target_configuration.build_settings['PRODUCT_NAME']
      target_possible_spec_names.push target_configuration.build_settings['PRODUCT_NAME']
    end
    if target_configuration.build_settings['IBSC_MODULE']
      target_possible_spec_names.push target_configuration.build_settings['IBSC_MODULE']
    end
    if target_configuration.build_settings['CONFIGURATION_BUILD_DIR']
      target_possible_spec_names.push File.basename(target_configuration.build_settings['CONFIGURATION_BUILD_DIR'])
    end
    if target_xcconfig.lines.detect { |line| line.start_with? 'CONFIGURATION_BUILD_DIR = ' }
      target_possible_spec_names.push File.basename(target_xcconfig.lines.detect do |line|
                                                      line.start_with? 'CONFIGURATION_BUILD_DIR = '
                                                    end.strip)
    end
    if target_xcconfig.lines.detect { |line| line.start_with? 'PODS_TARGET_SRCROOT = ' }
      target_possible_spec_names.push File.basename(target_xcconfig.lines.detect do |line|
                                                      line.start_with? 'PODS_TARGET_SRCROOT = '
                                                    end.strip)
    end

    target_match_spec_names = []
    target_possible_spec_names.uniq.sort.each do |spec_name|
      if spec_name.size.positive? && $zabel_podfile_spec_checksums.key?(spec_name)
        source_md5_list.push "SPEC CHECKSUM : #{spec_name} #{$zabel_podfile_spec_checksums[spec_name]}"
        target_match_spec_names.push spec_name
      end
    end

    unless target_match_spec_names.size == 1
      puts "[XcodeCache/E] #{target.name} #{target_possible_spec_names} #{target_match_spec_names} SPEC CHECKSUM should be found"
      puts target_configuration.build_settings.to_s
      puts target_xcconfig
    end

    source_md5_list.push "Project : #{File.basename(project.path)}"
    source_md5_list.push 'Project configuration : '
    source_md5_list.push project_configuration_content.strip
    source_md5_list.push 'Project xcconfig : '
    source_md5_list.push project_xcconfig.strip
    source_md5_list.push "Target : #{target.name}"
    source_md5_list.push "Target type : #{target.product_type}"
    source_md5_list.push 'Target configuration : '
    source_md5_list.push target_configuration_content.strip
    source_md5_list.push 'Target xcconfig : '
    source_md5_list.push target_xcconfig.strip
    source_md5_list.push 'Files settings : '
    source_md5_list.push first_configuration_content.strip

    source_md5_list.push 'Files MD5 : '
    source_files.uniq.sort.each do |file|
      source_md5_list.push "#{zabel_get_content_without_pwd(file)} : #{zabel_get_file_md5(file)}"
    end

    source_md5_list.join("\n")
  end

  def self.zabel_clean_temp_files
    command = "rm -rf Pods/*.xcodeproj/#{BACKUP_PBXPROJ}"
    puts "[XcodeCache] #{command}"
    raise unless system command

    command = "rm -rf Pods/*.xcodeproj/*.#{FILE_NAME_TARGET_CONTEXT}"
    puts "[XcodeCache] #{command}"
    raise unless system command
  end

  def self.zabel_add_cache(target, target_context, message)
    target_md5 = target_context[:target_md5]

    product_dir = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]
    intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
    full_product_name = target_context[BUILD_KEY_FULL_PRODUCT_NAME]

    target_cache_dir = "#{zabel_get_cache_root}/#{target.name}-#{target_md5}-#{(Time.now.to_f * 1000).to_i}"

    Dir.glob("#{product_dir}/**/*.modulemap").each do |modulemap|
      modulemap_content = File.read(modulemap)
      if modulemap_content.include? "#{File.dirname(modulemap)}/"
        modulemap_content = modulemap_content.gsub("#{File.dirname(modulemap)}/", '')
        File.write(modulemap, modulemap_content)
      end
    end

    unless full_product_name&.size&.positive? && File.exist?("#{product_dir}/#{full_product_name}")
      puts "[XcodeCache/E] #{target.name} #{product_dir}/#{full_product_name} should exist"
      return false
    end

    zip_start_time = Time.now

    command = "cd \"#{File.dirname(product_dir)}\" && tar -L -c -f #{target.name}.#{FILE_NAME_PRODUCT} #{File.basename(product_dir)}/#{full_product_name}"
    if target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:static_library]
      command = "cd \"#{File.dirname(product_dir)}\" && tar --exclude=*.bundle --exclude=*.framework -L -c -f #{target.name}.#{FILE_NAME_PRODUCT} #{File.basename(product_dir)}"
    end

    puts "[XcodeCache] #{command} -- time: #{(Time.now - zip_start_time).to_i}"
    unless system command
      puts "[XcodeCache/E] #{command} should succeed"
      return false
    end

    if File.exist? target_cache_dir
      puts "[XcodeCache/E] #{target_cache_dir} should not exist"
      raise unless system "rm -rf \"#{target_cache_dir}\""

      return false
    end

    command = "mkdir -p \"#{target_cache_dir}\""
    unless system command
      puts "[XcodeCache/E] #{command} should succeed"
      return false
    end

    cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"

    command = "mv \"#{File.dirname(product_dir)}/#{target.name}.#{FILE_NAME_PRODUCT}\" \"#{cache_product_path}\""
    unless system command
      puts "[XcodeCache/E] #{command} should succeed"
      return false
    end
    unless File.exist? cache_product_path
      puts "[XcodeCache/E] #{cache_product_path} should exist after mv"
      return false
    end

    target_context[:product_md5] = zabel_get_file_md5(cache_product_path)
    target_context[:build_product_dir] =
      target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR].gsub("#{target_context[BUILD_KEY_SYMROOT]}/", '')
    target_context[:build_intermediate_dir] =
      target_context[BUILD_KEY_TARGET_TEMP_DIR].gsub("#{target_context[BUILD_KEY_OBJROOT]}/", '')
    if target_context[BUILD_KEY_MODULEMAP_FILE]
      target_context[BUILD_KEY_MODULEMAP_FILE] =
        zabel_get_content_without_pwd target_context[BUILD_KEY_MODULEMAP_FILE]
    end

    target_context = target_context.clone
    target_context.delete(:dependency_files)
    target_context.delete(:target_status)
    target_context.delete(:potential_hit_target_cache_dirs)
    target_context.delete(:target_md5_content)
    target_context.delete(:miss_dependency_list)
    [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR,
     BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_SRCROOT].each do |key|
      target_context.delete(key)
    end

    File.write("#{target_cache_dir}/#{FILE_NAME_CONTEXT}", target_context.to_yaml)
    File.write("#{target_cache_dir}/#{FILE_NAME_MESSAGE}", message)

    true
  end

  def self.zabel_post(argv)
    configuration_name = nil

    if argv.include?('-configuration')
      configuration_name = argv[argv.index('-configuration') + 1]
    elsif argv.include?('--configuration')
      configuration_name = argv[argv.index('--configuration') + 1]
    end
    raise '[XcodeCache/E] -configuration or --configuration should be set' unless configuration_name&.size&.positive?

    start_time = Time.now

    add_count = 0

    projects = zabel_get_projects

    post_targets_context = {}

    projects.each do |project|
      project_configuration = project.build_configurations.detect { |config| config.name == configuration_name }
      unless project_configuration
        puts "[XcodeCache/E] #{project.path} should have config #{configuration_name}"
        next
      end
      project.native_targets.each do |target|
        target_context_file = "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
        next unless File.exist? target_context_file

        next unless zabel_can_cache_target(target)

        target_context = YAML.load(File.read(target_context_file))

        case target_context[:target_status]
        when STATUS_MISS_AND_READY
          $SRC_ROOT = target_context[BUILD_KEY_SRCROOT]
          environment_valid = true
          [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT,
           BUILD_KEY_TARGET_TEMP_DIR, BUILD_KEY_SRCROOT, BUILD_KEY_FULL_PRODUCT_NAME].sort.each do |key|
            next if target_context.key?(key) && target_context[key] && target_context[key].size.positive?

            puts "[XcodeCache/E] #{target.name} should have #{key} in #{target_context}"
            environment_valid = false
            break
          end
          next unless environment_valid

          source_files = zabel_get_target_source_files(target)

          # product_dir = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]
          # intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
          # xcframeworks_build_dir = target_context[BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR]
          #
          # puts "[XcodeCache] Getting dependency: #{target.name} start"
          # dependency_time = Time.now
          # dependency_files = zabel_get_dependency_files(target, intermediate_dir, product_dir,
          #                                               xcframeworks_build_dir)
          # puts "[XcodeCache] Getting dependency: #{target.name} end -- time: #{(Time.now - dependency_time).to_i}"
          # if source_files.size.positive? && dependency_files.size.zero? && (target.product_type != Xcodeproj::Constants::PRODUCT_TYPE_UTI[:bundle])
          #   puts "[XcodeCache/E] #{target.name} should have dependent files"
          #   next
          # end
          # target_context[:dependency_files] = dependency_files - source_files
          target_md5_content = zabel_get_target_md5_content(project, target, configuration_name, argv,
                                                            source_files)
          target_context[:target_md5_content] = target_md5_content
          target_md5 = Digest::MD5.hexdigest(target_md5_content)
          unless target_context[:target_md5] == target_md5
            puts "[XcodeCache/E] #{target.name} md5 should not be changed after build"
            next
          end
          if target_context[BUILD_KEY_SRCROOT]&.size&.positive? &&
             target_context[BUILD_KEY_MODULEMAP_FILE] && target_context[BUILD_KEY_MODULEMAP_FILE].size.positive?
            if File.exist? "#{Dir.pwd}/#{zabel_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")}"
              target_context[BUILD_KEY_MODULEMAP_FILE] =
                zabel_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
            else
              puts "[XcodeCache/E] #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
              next
            end
          end
        when STATUS_HIT
          if target_context[BUILD_KEY_MODULEMAP_FILE]&.size&.positive? && !(File.exist? "#{Dir.pwd}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
            puts "[XcodeCache/E] #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
            next
          end
        else
          puts "[XcodeCache/E] #{target.name} should be hit or miss"
          next
        end

        post_targets_context[target] = target_context
      end
    end

    projects.each do |project|
      project.native_targets.each do |target|
        next unless post_targets_context.key? target

        target_context = post_targets_context[target]
        next unless target_context[:target_status] == STATUS_MISS_AND_READY

        # dependency_targets_set = Set.new
        # implicit_dependencies = []
        #
        # post_targets_context.each do |other_target, other_target_context|
        #   next if other_target == target
        #
        #   next if target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:bundle]
        #   next if other_target.product_type == Xcodeproj::Constants::PRODUCT_TYPE_UTI[:bundle]
        #
          # target_context[:dependency_files].each do |dependency|
          #   if other_target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]&.size&.positive? &&
          #      dependency.start_with?("#{other_target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]}/")
          #     dependency_targets_set.add other_target
          #     implicit_dependencies.push dependency
          #   elsif other_target_context[BUILD_KEY_TARGET_TEMP_DIR]&.size&.positive? &&
          #         dependency.start_with?("#{other_target_context[BUILD_KEY_TARGET_TEMP_DIR]}/")
          #     dependency_targets_set.add other_target
          #     implicit_dependencies.push dependency
          #   elsif other_target_context[:build_product_dir]&.size&.positive? &&
          #         dependency.start_with?("#{target_context[BUILD_KEY_SYMROOT]}/#{other_target_context[:build_product_dir]}/")
          #     dependency_targets_set.add other_target
          #     implicit_dependencies.push dependency
          #   elsif other_target_context[:build_intermediate_dir]&.size&.positive? &&
          #         dependency.start_with?("#{target_context[BUILD_KEY_OBJROOT]}/#{other_target_context[:build_intermediate_dir]}/")
          #     dependency_targets_set.add other_target
          #     implicit_dependencies.push dependency
          #   end
          #
          #   if !zabel_should_not_detect_module_map_dependency && (other_target_context[BUILD_KEY_MODULEMAP_FILE]&.size&.positive? &&
          #          (dependency == "#{Dir.pwd}/#{other_target_context[BUILD_KEY_MODULEMAP_FILE]}"))
          #     dependency_targets_set.add other_target
          #   end
          # end
        #
        #   target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies
        # end
        #
        # target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies
        # dependency_files_md5 = []
        # should_not_cache = false
        # target_context[:dependency_files].each do |file|
        #   if file.start_with?("#{target_context[BUILD_KEY_OBJROOT]}/") || file.start_with?("#{target_context[BUILD_KEY_SYMROOT]}/")
        #     puts "[XcodeCache/W] #{target.name} #{file} dependecy should not include build path"
        #     should_not_cache = true
        #     break
        #   end
        #   dependency_files_md5.push [zabel_get_content_without_pwd(file), zabel_get_file_md5(file)]
        # end
        # next if should_not_cache
        #
        # target_context[:dependency_files_md5] = dependency_files_md5.sort.uniq
        #
        # dependency_targets_md5 = dependency_targets_set.to_a.map do |target|
        #   [target.name, post_targets_context[target][:target_md5]]
        # end
        # target_context[:dependency_targets_md5] = dependency_targets_md5

        message = target_context[:target_md5_content]

        add_count += 1 if zabel_add_cache(target, target_context, message)
      end
    end

    projects.each do |project|
      zabel_restore_project(project)
    end

    zabel_keep

    puts "[XcodeCache] total add #{add_count}"

    puts "[XcodeCache] duration = #{(Time.now - start_time).to_i} s in stage post"
  end

  def self.zabel_get_potential_hit_target_cache_dirs(target, target_md5, miss_dependency_list)
    # dependency_start_time = Time.now
    target_cache_dirs = Dir.glob("#{zabel_get_cache_root}/#{target.name}-#{target_md5}-*")
    file_time_hash = {}
    target_cache_dirs.each do |file|
      file_time_hash[file] = File.mtime(file)
    end
    target_cache_dirs = target_cache_dirs.sort_by { |file| - file_time_hash[file].to_f }
    potential_hit_target_cache_dirs = []
    target_cache_dirs.each do |target_cache_dir|
      next unless File.exist? "#{target_cache_dir}/#{FILE_NAME_PRODUCT}"
      next unless File.exist? "#{target_cache_dir}/#{FILE_NAME_CONTEXT}"

      target_context = YAML.load(File.read("#{target_cache_dir}/#{FILE_NAME_CONTEXT}"))
      dependency_miss = false
      # target_context[:dependency_files_md5].each do |item|
      #   dependency_file = item[0]
      #   dependency_md5 = item[1]
      #
      #   unless File.exist? dependency_file
      #     unless File.exist? "#{$SRC_ROOT}/#{dependency_file}"
      #       miss_dependency_list.push "[XcodeCache/W] #{target.name} #{dependency_file} file should exist to be hit"
      #       dependency_miss = true
      #       break
      #     end
      #   end
      #   next if zabel_get_file_md5(dependency_file) == dependency_md5
      #
      #   miss_dependency_list.push "[XcodeCache/W] #{target.name} #{dependency_file} md5 #{zabel_get_file_md5(dependency_file)} should match #{dependency_md5} to be hit"
      #   dependency_miss = true
      #   break
      # end
      # next if dependency_miss

      if target_context[:target_md5] != target_md5
        command = "rm -rf \"#{target_cache_dir}\""
        raise unless system command

        puts "[XcodeCache/E] #{target.name} #{target_cache_dir} target md5 should match to be verified"
        dependency_miss = false
        next
      end
      if target_context[:product_md5] != zabel_get_file_md5("#{target_cache_dir}/#{FILE_NAME_PRODUCT}")
        command = "rm -rf \"#{target_cache_dir}\""
        raise unless system command

        puts "[XcodeCache/E] #{target.name} #{target_cache_dir} product md5 should match to be verified"
        dependency_miss = false
        next
      end

      potential_hit_target_cache_dirs.push target_cache_dir
      break if target_context[:dependency_targets_md5].size.zero?
      break if potential_hit_target_cache_dirs.size > 10
    end
    potential_hit_target_cache_dirs
  end

  def self.zabel_disable_build_and_inject_extract(_project, target, target_context)
    target_cache_dir = target_context[:hit_target_cache_dir]

    # touch to update mtime
    raise unless system "touch \"#{target_cache_dir}\""

    # delete build phases to disable build command
    target.build_phases.delete_if do |build_phase|
      build_phase.instance_of?(Xcodeproj::Project::Object::PBXHeadersBuildPhase) or
        build_phase.instance_of?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) or
        build_phase.instance_of?(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
    end

    zabel_exec = "\"#{$PROGRAM_NAME}\""
    if ENV['BUNDLE_BIN_PATH']&.size&.positive? && ENV['BUNDLE_GEMFILE'] && ENV['BUNDLE_GEMFILE'].size.positive?
      zabel_exec = "source ~/.bash_profile\ncd \"#{File.dirname(ENV['BUNDLE_GEMFILE'])}\" && \"#{ENV['BUNDLE_BIN_PATH']}\" exe zabel"
    end
    extract_script = "#{zabel_exec} #{STAGE_EXTRACT} \"#{target_cache_dir}\" \"#{target_context[:build_product_dir]}\" \"#{target_context[:build_intermediate_dir]}\""

    inject_phase = target.new_shell_script_build_phase("xcodecache_extract_#{target.name}")
    inject_phase.shell_script = extract_script
    inject_phase.show_env_vars_in_log = '1'
  end

  def self.zabel_inject_printenv(project, target)
    zabel_exec = "\"#{$PROGRAM_NAME}\""
    if ENV['BUNDLE_BIN_PATH']&.size&.positive? && ENV['BUNDLE_GEMFILE'] && ENV['BUNDLE_GEMFILE'].size.positive?
      zabel_exec = "source ~/.bash_profile\ncd \"#{File.dirname(ENV['BUNDLE_GEMFILE'])}\" && \"#{ENV['BUNDLE_BIN_PATH']}\" exe zabel"
    end
    inject_phase = target.new_shell_script_build_phase("xcodecache_printenv_#{target.name}")
    inject_phase.shell_script = "#{zabel_exec} #{STAGE_PRINTENV} #{target.name} \"#{project.path}\""
    inject_phase.show_env_vars_in_log = '1'
  end

  def self.zabel_pre(argv)
    configuration_name = nil

    if argv.include?('-configuration')
      configuration_name = argv[argv.index('-configuration') + 1]
    elsif argv.include?('--configuration')
      configuration_name = argv[argv.index('--configuration') + 1]
    end
    raise '[XcodeCache/E] -configuration or --configuration should be set' unless configuration_name&.size&.positive?

    start_time = Time.now

    if ENV['XcodeCache_CLEAR_ALL'] == 'YES'
      command = "rm -rf \"#{zabel_get_cache_root}\""
      puts "[XcodeCache] #{command}"
      raise unless system command
    end

    zabel_clean_temp_files

    projects = zabel_get_projects

    pre_targets_context = {}

    hit_count = 0
    miss_count = 0
    hit_target_md5_cache_set = Set.new
    iteration_count = 0

    projects.each do |project|
      project_configuration = project.build_configurations.detect { |config| config.name == configuration_name }
      unless project_configuration
        puts "[XcodeCache/E] #{project.path} should have config #{configuration_name}"
        next
      end
      # puts "[XcodeCache] #{File.basename(project.path)} - target count:#{project.native_targets.size}"
      $SRC_ROOT = File.dirname(project.path)

      project.native_targets.each do |target|
        next unless zabel_can_cache_target(target)

        source_files = zabel_get_target_source_files(target)
        unless source_files.size >= zabel_get_min_source_file_count
          puts "[XcodeCache] skip #{target.name} #{source_files.size} < #{zabel_get_min_source_file_count}"
          next
        end
        target_md5_content = zabel_get_target_md5_content(project, target, configuration_name, argv,
                                                          source_files)
        target_md5 = Digest::MD5.hexdigest(target_md5_content)
        miss_dependency_list = []
        potential_hit_target_cache_dirs = zabel_get_potential_hit_target_cache_dirs(target, target_md5,
                                                                                    miss_dependency_list)

        target_context = {}
        target_context[:target_md5] = target_md5
        target_context[:potential_hit_target_cache_dirs] = potential_hit_target_cache_dirs
        target_context[:miss_dependency_list] = miss_dependency_list
        if potential_hit_target_cache_dirs.size.zero?
          puts miss_dependency_list.uniq.join("\n") if miss_dependency_list.size.positive?
          puts "[XcodeCache] miss #{target.name} #{target_md5} in iteration #{iteration_count}"
          target_context[:target_status] = STATUS_MISS
          miss_count += 1
        end
        pre_targets_context[target] = target_context
      end
    end

    loop do
      iteration_count += 1
      confirm_count = hit_count + miss_count
      projects.each do |project|
        project.native_targets.each do |target|
          next unless pre_targets_context.key? target

          target_context = pre_targets_context[target]
          next if target_context[:target_status] == STATUS_MISS
          next if target_context[:target_status] == STATUS_HIT

          potential_hit_target_cache_dirs = target_context[:potential_hit_target_cache_dirs]
          next if potential_hit_target_cache_dirs.size.zero?

          hit_target_cache_dir = nil
          potential_hit_target_cache_dirs.each do |target_cache_dir|
            next unless File.exist? "#{target_cache_dir}/#{FILE_NAME_CONTEXT}"

            hit_target_context = YAML.load(File.read("#{target_cache_dir}/#{FILE_NAME_CONTEXT}"))
            hit_target_cache_dir = target_cache_dir
            # hit_target_context[:dependency_targets_md5].each do |item|
            #   dependency_target = item[0]
            #   dependency_target_md5 = item[1]
            #
            #   # cycle dependency targets will be miss every time.
            #   # TODO: to detect cycle dependency so that cache will not be added,
            #   # or to hit cache together with some kind of algorithms.
            #   unless hit_target_md5_cache_set.include? "#{dependency_target}-#{dependency_target_md5}"
            #     hit_target_cache_dir = nil
            #     break
            #   end
            # end
            if hit_target_cache_dir
              target_context.merge!(hit_target_context)
              break
            end
          end
          next unless hit_target_cache_dir

          puts "[XcodeCache] hit #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count} potential #{potential_hit_target_cache_dirs.size}"
          target_context[:target_status] = STATUS_HIT
          target_context[:hit_target_cache_dir] = hit_target_cache_dir
          hit_count += 1
          hit_target_md5_cache_set.add "#{target.name}-#{target_context[:target_md5]}"
        end
      end
      break if hit_count + miss_count == confirm_count
    end

    projects.each do |project|
      should_save = false
      project.native_targets.each do |target|
        next unless pre_targets_context.key? target

        target_context = pre_targets_context[target]

        if target_context[:target_status] == STATUS_HIT
          puts "[XcodeCache] inject target: #{target.name}"
          zabel_disable_build_and_inject_extract(project, target, target_context)
        else
          unless target_context[:target_status] == STATUS_MISS
            target_context[:target_status] = STATUS_MISS
            miss_dependency_list = target_context[:miss_dependency_list]
            puts miss_dependency_list.uniq.join("\n") if miss_dependency_list.size.positive?
            puts "[XcodeCache] miss #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count}"
            miss_count += 1
          end
          zabel_inject_printenv(project, target)
        end
        File.write("#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)

        should_save = true
      end

      if should_save
        zabel_backup_project(project)
        project.save
      else
        zabel_clean_backup_project(project)
      end
    end

    puts "[XcodeCache] total #{hit_count + miss_count} hit #{hit_count} miss #{miss_count} iteration #{iteration_count}"

    puts "[XcodeCache] duration = #{(Time.now - start_time).to_i} s in stage pre"
  end

  def self.zabel_extract
    start_time = Time.now

    target_cache_dir = ARGV[1]

    cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"

    [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR,
     BUILD_KEY_SRCROOT, BUILD_KEY_FULL_PRODUCT_NAME].sort.each do |key|
      unless ENV.key?(key) && ENV[key] && ENV[key].size.positive?
        raise "[XcodeCache/E] #{target.name} should have #{key}"
        break
      end
    end

    if ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR] != ENV[BUILD_KEY_TARGET_BUILD_DIR]
      command = "mkdir -p \"#{ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR]}\" && cd \"#{File.dirname(ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR])}/\" && tar -xf \"#{cache_product_path}\""
      puts "[XcodeCache] #{command}"
      raise unless system command

      command = "rm -rf \"#{"#{ENV[BUILD_KEY_TARGET_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}"}\""
      puts "[XcodeCache] #{command}"
      raise unless system command

      command = "mkdir -p \"#{File.dirname("#{ENV[BUILD_KEY_TARGET_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}")}\""
      puts "[XcodeCache] #{command}"
      raise unless system command

      command = "mv \"#{"#{ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}"}\" \"#{"#{ENV[BUILD_KEY_TARGET_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}"}\""
      puts "[XcodeCache] #{command}"
      raise unless system command

      command = "/bin/ln -sfh \"#{"#{ENV[BUILD_KEY_TARGET_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}"}\" \"#{"#{ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR]}/#{ENV[BUILD_KEY_FULL_PRODUCT_NAME]}"}\""
      puts "[XcodeCache] #{command}"
      raise unless system command
    else
      command = "mkdir -p \"#{ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR]}\" && cd \"#{File.dirname(ENV[BUILD_KEY_CONFIGURATION_BUILD_DIR])}/\" && tar -xf \"#{cache_product_path}\""
      puts "[XcodeCache] #{command}"
      raise unless system command
    end

    puts "[XcodeCache] duration = #{(Time.now - start_time).to_i} s in stage extract"
  end

  def self.zabel_printenv
    puts ARGV.to_s
    target_name = ARGV[1]
    project_path = ARGV[2]

    target_context = YAML.load(File.read("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}"))

    # see https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/XcodeBuildSettingRef/1-Build_Setting_Reference/build_setting_ref.html
    [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR,
     BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_MODULEMAP_FILE, BUILD_KEY_SRCROOT, BUILD_KEY_FULL_PRODUCT_NAME].sort.each do |key|
      target_context[key] = ENV[key] if ENV[key]
    end
    target_context[:target_status] = STATUS_MISS_AND_READY
    File.write("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)
  end

  def self.zabel_clean
    zabel_clean_temp_files
  end
end
