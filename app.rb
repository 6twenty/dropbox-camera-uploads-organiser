require 'bundler/setup'
require 'dotenv'
require 'rack/oauth2'
require 'exif'

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
    get_files
    create_folders
    move_files
    self
  end

  def get_files
    data = @client.post('list_folder', {
      path: "/Camera Uploads",
      recursive: false,
      include_media_info: false,
      include_deleted: false,
      include_has_explicit_shared_members: false
    })

    parse_files_data(data)
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
      @client.post('create_folder', {
        path: "/Camera Uploads/#{folder_name}"
      })
    end
  end

  def move_files
    @files.each do |group, files|
      entries = files.map do |entry|
        {
          from_path: entry['path_display'],
          to_path: "/Camera Uploads/#{group}/#{entry['name']}"
        }
      end

      puts "Moving #{files.length} files into '#{group}'"

      data = @client.post('move_batch', {
        entries: entries
      })
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
    get_folders
    process_folders # TODO: remove
    # process_folder(@folder) # TODO: add
  end

  def get_folders
    data = @client.post('list_folder', {
      path: '/Camera Uploads'
    })

    folders = data['entries'].map { |entry| entry['path_display'] }.sort

    @folder = folders.last
    @folders = folders # TODO: remove
  end

  def process_folders
    @folders.each do |folder_path|
      process_folder(folder_path)
    end
  end

  def process_folder(folder_path)
    data = @client.post('list_folder', {
      path: folder_path
    })

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

    create_other_folder(folder_path) unless has_other_folder

    move_files(files_to_move, folder_path)
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

    puts "Moving #{files.length} files into '#{folder_path}/#{@other_folder_name}'"

    data = @client.post('move_batch', {
      entries: entries
    })
  end

  def create_other_folder(folder_path)
    @client.post('create_folder', {
      path: "#{folder_path}/#{@other_folder_name}"
    })
  end

end
