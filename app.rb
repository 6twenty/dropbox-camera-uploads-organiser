require 'bundler/setup'
require 'dotenv'
require 'rack/oauth2'
require 'exif'
require 'fileutils'

Dotenv.load

module AwaitJobs

  def await_jobs
    print "."

    @jobs.select! do |job_id|
      data = @client.post('move_batch/check', {
        async_job_id: job_id
      })

      if data['.tag'] == 'failed'
        @failed_jobs << job_id
      end

      # Only keep jobs that are still in progress
      data['.tag'] == 'in_progress'
    end

    if @jobs.any?
      sleep 5
      await_jobs
    else
      puts "\n-> All batch move jobs complete."
      if @failed_jobs.any?
        print " #{@failed_jobs.size} jobs failed:\n"
        @failed_jobs.each { |job_id| puts "   - #{job_id}" }
      end
    end
  end

end

class Client

  def initialize(host)
    @token = Rack::OAuth2::AccessToken::Bearer.new(access_token: ENV['AUTH_TOKEN'])
    @host = host
    @json = @host == 'api.dropboxapi.com'
  end

  def post(endpoint, data = {})
    if @json
      body = data.to_json
      headers = {
        "Content-Type" => "application/json"
      }
    else
      body = nil
      headers = {
        "Dropbox-API-Arg" => data.to_json
      }
    end

    response = @token.post("https://#{@host}/2/files/#{endpoint}", body, headers)

    @json ? JSON.parse(response.body) : response.body
  end

end

class DateOrganiser

  include AwaitJobs

  def initialize
    @client = Client.new('api.dropboxapi.com')

    @files = {}
    @folders = []
    @jobs = []
    @failed_jobs = []
  end

  def run!
    puts "DateOrganiser"
    puts "=============\n\n"

    get_files
    create_folders if (@files.keys - @folders).any?
    move_files if @files.values.flatten.any?

    if @jobs.any?
      puts "Awaiting #{@jobs.length} batch move jobs:"
      print "\n-> ."
      await_jobs
    end

    puts "Finished.\n\n"
  end

  def get_files
    print "Retrieving directory listing for 'Camera Uploads'..."

    data = @client.post('list_folder', {
      path: "/Camera Uploads",
      recursive: false,
      include_media_info: false,
      include_deleted: false,
      include_has_explicit_shared_members: false
    })

    parse_files_data(data)

    puts " Done."
    puts "-> Found #{@files.values.flatten.length} files to process, covering #{@files.keys.length} months."
    puts "-> #{(@files.keys - @folders).length} folders need to be created."
  end

  def get_more_files(cursor)
    data = @client.post('list_folder/continue', {
      cursor: cursor
    })

    parse_files_data(data)
  end

  def parse_files_data(data)
    data['entries'].each do |entry|
      if entry['.tag'] == 'file'
        # Parse the date group from the filename
        # Example: "2012-11-18 05.36.26.jpg"
        group = entry['name'][/^(\d{4}-\d{2})-\d{2}/, 1]
        @files[group] ||= []
        @files[group] << entry
      elsif entry['.tag'] == 'folder'
        @folders << entry['name']
      end
    end

    if data['has_more']
      get_more_files(data['cursor'])
    end
  end

  def create_folders
    (@files.keys - @folders).each do |folder_name|
      print "Creating folder '#{folder_name}'..."

      @client.post('create_folder', {
        path: "/Camera Uploads/#{folder_name}"
      })

      puts " Done."
    end
  end

  def move_files
    print "Moving #{@files.values.flatten.length} files..."

    entries = @files.reduce([]) do |entries, (group, files)|
      entries += files.map do |entry|
        {
          from_path: entry['path_display'],
          to_path: "/Camera Uploads/#{group}/#{entry['name']}"
        }
      end
    end

    data = @client.post('move_batch', {
      entries: entries
    })

    puts " Done."

    if data['.tag'] == 'async_job_id'
      puts "-> Job ID: #{data['async_job_id']}"
      @jobs << data['async_job_id']
    end
  end

end

class CameraOrganiser

  IPHONE_NAMES = [
    'iPhone SE',
    'iPhone 5c',
    'iPhone 3GS'
  ]

  FOLDER_NAMES = {
    iphone: 'iPhone',
    videos: 'Videos',
    other: 'Other'
  }

  include AwaitJobs

  def initialize
    @client = Client.new('api.dropboxapi.com')
    @dl_client = Client.new('content.dropboxapi.com')

    @jobs = []
    @failed_jobs = []
  end

  def run!
    puts "CameraOrganiser"
    puts "===============\n\n"

    get_folders
    process_folders

    if @jobs.any?
      puts "Awaiting #{@jobs.length} batch move jobs:"
      print "\n-> ."
      await_jobs
    end

    puts "Finished.\n\n"
  end

  def get_folders
    print "Retrieving list of folders in 'Camera Uploads'..."

    data = @client.post('list_folder', {
      path: '/Camera Uploads'
    })

    @folders = data['entries']
      .select { |entry| entry['.tag'] == 'folder' }
      .map { |entry| entry['path_display'] }
      .sort

    puts " Done."
  end

  def process_folders
    puts "-> Processing #{@folders.length} folders."

    @folders.each do |folder_path|
      process_folder(folder_path)
    end
  end

  def process_folder(folder_path)
    print "Retrieving directory listing for '#{folder_path}'..."

    data = @client.post('list_folder', {
      path: folder_path
    })

    puts " Done."
    puts "-> Scanning #{data['entries'].length} entries."

    files = []

    has_other_folder = false
    has_videos_folder = false
    has_iphone_folder = false

    data['entries'].each do |entry|
      if entry['.tag'] == 'folder'
        has_other_folder = true if entry['name'] == FOLDER_NAMES[:other]
        has_videos_folder = true if entry['name'] == FOLDER_NAMES[:videos]
        has_iphone_folder = true if entry['name'] == FOLDER_NAMES[:iphone]
      end

      files << entry if entry['.tag'] == 'file'
    end

    grouped_files = files.reduce({ iphone: [], videos: [], other: [] }) do |hash, entry|
      group = process_file(entry)
      hash[group] << entry
      hash
    end

    create_folder(folder_path, @other_folder_name) unless has_other_folder
    create_folder(folder_path, @videos_folder_name) unless has_videos_folder
    create_folder(folder_path, @iphone_folder_name) unless has_iphone_folder

    grouped_files.each do |group, files|
      destination = "#{folder_path}/#{FOLDER_NAMES[group]}"
      move_files(files, destination) if files.any?
    end
  end

  def process_file(entry)
    # return if @processed_files.include?(entry['path_display'])

    puts "Processing #{entry['name']}"

    ext = entry['name'].split('.').last

    if ext =~ /mov/i
      return :videos
    end

    download_and_save_file(entry)
    process_temp_file(entry)

    # @processed_files << entry['path_display']

    # File.open(@processed_file_path, 'a') do |file|
    #   file.puts entry['path_display']
    # end
  end

  def download_and_save_file(entry)
    body = @dl_client.post('download', {
      path: entry['path_display']
    })

    File.open('./temp', 'w') { |file| file.write(body) }
  end

  def process_temp_file(entry)
    exif = Exif::Data.new('./temp')
    IPHONE_NAMES.include?(exif.model) ? :iphone : :other
  rescue => e
    # Can't read EXIF - not likely to be an iPhone photo
    :other
  ensure
    File.unlink('./temp')
  end

  def move_files(files, folder_path)
    entries = files.map do |entry|
      {
        from_path: entry['path_display'],
        to_path: "#{folder_path}/#{entry['name']}"
      }
    end

    print "Moving #{files.length} files into '#{folder_path}'..."

    data = @client.post('move_batch', {
      entries: entries
    })

    puts " Done."

    if data['.tag'] == 'async_job_id'
      puts "-> Job ID: #{data['async_job_id']}"
      @jobs << data['async_job_id']
    end
  end

  def create_folder(folder_path, folder_name)
    print "Creating folder '#{folder_path}/#{folder_name}'..."

    @client.post('create_folder', {
      path: "#{folder_path}/#{folder_name}"
    })

    puts " Done."
  end

end

class Downloader

  include AwaitJobs

  def initialize
    @client = Client.new('api.dropboxapi.com')
    @dl_client = Client.new('content.dropboxapi.com')

    @target_directory = ENV['DOWNLOAD_ROOT']
    @other_folder_name = 'Other'
  end

  def run!
    puts "Downloader"
    puts "===============\n\n"

    get_folders
    process_folders

    puts "Finished.\n\n"
  end

  def get_folders
    print "Retrieving list of folders in 'Camera Uploads'..."

    data = @client.post('list_folder', {
      path: '/Camera Uploads'
    })

    @folders = data['entries']
      .select { |entry| entry['.tag'] == 'folder' }
      .map { |entry| entry['path_display'] }
      .sort

    puts " Done."
    puts "-> Found #{@folders.length} folders."
  end

  def process_folders
    @folders.each do |folder_path|
      process_folder(folder_path)
    end
  end

  def process_folder(folder_path)
    download_files(folder_path)
    download_files("#{folder_path}/#{@other_folder_name}")
  end

  def download_files(folder_path)
    files = get_files(folder_path)

    print "Downloading #{files.length} files in '#{folder_path}'..."

    files.each do |entry|
      download_file(entry)
    end

    puts " Done."
  end

  def get_files(folder_path)
    data = @client.post('list_folder', {
      path: folder_path
    })

    if data['error']
      return []
    end

    data['entries'].select { |entry| entry['.tag'] == 'file' }
  end

  def download_file(entry)
    body = @dl_client.post('download', {
      path: entry['path_display']
    })

    target_path = "#{@target_directory}#{entry['path_display']}"
    target_directory = target_path.split('/').tap(&:pop).join('/')

    FileUtils.mkdir_p(target_directory)
    File.open(target_path, 'a') # Create the file
    File.open(target_path, 'w') { |file| file.write(body) }
  end

end
