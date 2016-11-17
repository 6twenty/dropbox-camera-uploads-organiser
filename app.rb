require 'bundler/setup'
require 'dotenv'
require 'rack/oauth2'
require 'exif'
require 'fileutils'

Dotenv.load

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

  def initialize
    @client = Client.new('api.dropboxapi.com')

    @files = {}
    @folders = []
  end

  def run!
    puts "DateOrganiser"
    puts "=============\n\n"

    get_files
    create_folders if (@files.keys - @folders).any?
    move_files if @files.values.flatten.any?

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
    end
  end

end

class CameraOrganiser

  def initialize
    @client = Client.new('api.dropboxapi.com')
    @dl_client = Client.new('content.dropboxapi.com')

    @other_folder_name = 'Other'
    @iphone_5c_name = 'iPhone 5c'
    @processed_file_path = './processed'

    # Create the 'processed' file if it doesn't exist
    File.open(@processed_file_path, 'a')

    File.open(@processed_file_path, 'r') do |file|
      @processed_files = file.read.split("\n")
    end
  end

  def run!
    puts "CameraOrganiser"
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

    # Only the 2 most recent folders need to be processed
    @folders = @folders.last(2)

    puts " Done."
    puts "-> Found '#{@folders.first}' and '#{@folders.last}' for processing."
  end

  def process_folders
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
    print "Scanning #{data['entries'].length} files..."

    files = []

    has_other_folder = false

    data['entries'].each do |entry|
      if entry['.tag'] == 'folder' && entry['name'] == @other_folder_name
        has_other_folder = true
      end

      files << entry if entry['.tag'] == 'file'
    end

    files_to_move = files.reduce([]) do |files, entry|
      files.tap { |files| process_file(entry, files) }
    end

    puts " Done."

    create_other_folder(folder_path) unless has_other_folder

    move_files(files_to_move, folder_path) if files_to_move.any?
  end

  def process_file(entry, files)
    # Download the file
    # Save it as a (temp) file
    # Read the exif data
    # If it was taken on an iPhone 5c leave it;
    # otherwise move it to the "Other" folder

    return if @processed_files.include?(entry['path_display'])

    # For now, only images are processed, not movies since
    # they'd take a long time to download. Also movies are
    # much more likely to be keepers anyway.
    ext = entry['name'].split('.').last
    return if ext =~ /mov/i

    puts "Processing #{entry['name']}"

    download_and_save_file(entry)
    process_temp_file(entry, files)

    @processed_files << entry['path_display']

    File.open(@processed_file_path, 'a') do |file|
      file.puts entry['path_display']
    end
  end

  def download_and_save_file(entry)
    body = @dl_client.post('download', {
      path: entry['path_display']
    })

    File.open('./temp', 'w') { |file| file.write(body) }
  end

  def process_temp_file(entry, files)
    exif = Exif::Data.new('./temp')

    unless exif.model == @iphone_5c_name
      files << entry
    end
  rescue => e
    # Can't read EXIF - not likely to be an iPhone 5c photo
    files << entry
  ensure
    File.unlink('./temp')
  end

  def move_files(files, folder_path)
    entries = files.map do |entry|
      {
        from_path: entry['path_display'],
        to_path: "#{folder_path}/#{@other_folder_name}/#{entry['name']}"
      }
    end

    print "Moving #{files.length} files into '#{folder_path}/#{@other_folder_name}'..."

    data = @client.post('move_batch', {
      entries: entries
    })

    puts " Done."
  end

  def create_other_folder(folder_path)
    print "Creating folder 'Camera Uploads/#{folder_path}'..."

    @client.post('create_folder', {
      path: "#{folder_path}/#{@other_folder_name}"
    })

    puts " Done."
  end

end

class Downloader

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
