require 'sinatra'
require 'tempfile'
require 'dotenv/load'
require 'yaml'
require 'find'
require 'pathname'

class TrueClass
    def passfail
        'PASS'
    end
end

class FalseClass
    def passfail
        'FAIL'
    end
end

SIZES = [80, 128, 160, 250, 256, 500, 1000].freeze

def findImagesFor(manufacturer, folder, hash)
    dirHash = hash.clone
    path = "#{manufacturer}/#{folder}"
    locationArray = path.split('/')
    puts locationArray
    locationArray.each do |dir|
        dirHash = dirHash.select { |x| x['text'] == dir }[0][:children]
    end
    dirHash
end

def directory_hash(path, name = nil, exclude = [])
    exclude.concat(['..', '.', '.git', '__MACOSX', '.DS_Store', '._.DS_Store', 'All'])
    data = { 'image' => 'false', 'text' => (name || path) }
    data[:children] = children = []
    Dir.foreach(path) do |entry|
        next if exclude.include?(entry)
        full_path = File.join(path, entry)
        children << if File.directory?(full_path)
                        if Dir[full_path + '/sda-pt.sf'].empty?
                            directory_hash(full_path, entry)
                        else
                            { 'image' => 'true', 'text' => entry }
                          end
                    end
    end
    data
end

def findImagesInFolder(folder)
    Dir[ENV['IMAGES_DIR'] + '/' + folder + '/*'].select { |entry| File.directory?(entry) }
  end

if ENV['IMAGES_DIR']
    manufacturers = Dir.entries(ENV['IMAGES_DIR']).select { |entry| File.directory?(File.join(ENV['IMAGES_DIR'], entry)) && !(entry == '.' || entry == '..') }
    manufacturers.concat ['All']
    manufacturers.sort_by!(&:downcase)

    globalImageList = Dir[ENV['IMAGES_DIR'] + '/**/*'].select { |entry| File.directory?(entry) && !Dir[entry + '/sda-pt.sf'].empty? }
end
def getSysInfo
    sysInfo = {}
    sysInfo[:serial] = `sudo dmidecode --type 1 | grep Serial | sed 's/\tSerial Number: //'`.chomp
    sysInfo[:mfr] = `sudo dmidecode --type 1 | grep Manufacturer | sed 's/\tManufacturer: //'`.chomp
    sysInfo[:model] = `sudo dmidecode --type 1 | grep "Product Name:" | sed 's/\tProduct Name: //'`.chomp
    sysInfo[:version] = `sudo dmidecode --type 1 | grep "Version:" | sed 's/\tVersion: //'`.chomp
    sysInfo[:proc] = `lscpu | grep "Model name:" | sed 's/Model name: *//'`.chomp
    sysInfo
end

def getFreeMemory
    freeMem = `cat /proc/meminfo | grep MemFree`
    freeMem = freeMem.scan(/\d*/).join('').to_i / 1024.0
    freeMem
end

memTestAmt = (getFreeMemory * 0.7).floor

# enable SMART on drive
smartSupport = system('sudo smartctl --smart=on /dev/sda')
# run Conveyance SMART test

if !ENV['DEBUG']
    memTestAmt = (getFreeMemory * 0.7).floor
    totalRam = `cat /proc/meminfo | grep MemTotal | sed 's/MemTotal: *//' | sed 's/ kB//'`.chomp.to_i / 1024.0 / 1024
    totalRam = totalRam.round
    memoryStatus = Tempfile.new('memStatus')
    memoryStatus.write('Testing In Progress')
    memTestPID = fork do
        status = system("sudo memtester #{memTestAmt} 1").passfail
        memoryStatus.rewind
        memoryStatus.write(status.to_s)
        memoryStatus.truncate(status.length)
        exit
    end

    driveSize = `lsblk -b | grep "sda " | grep -oE '[0-9]{3,}'`.chomp.to_i
    humanReadableSize = driveSize / 1000.0 / 1000 / 1000
    humanReadableSize = SIZES.map { |x| [x, (x - humanReadableSize).abs] }.to_h.min_by { |_size, distance| distance }[0]
    hddStatus = Tempfile.new('hddStatus')
    hddStatus.write('Testing In Progress')
    if smartSupport == true
        hddTestPID = fork do
            hddTestStatus = true.passfail
            waitForShortTest = `sudo smartctl -t short /dev/sda | grep Please | sed 's/Please wait //' | sed 's/ minutes for test to complete.//'`.chomp.to_i
            sleep(150)
            smartShortStatus = `sudo smartctl -l selftest /dev/sda | grep Short | grep "# 1 "`
            smartShortPass = smartShortStatus.include? 'Completed without error'
            if smartShortPass == false
                puts 'FAILED AT SHORT SELFTEST'
                hddTestStatus = false.passfail
                hddStatus.rewind
                hddStatus.write(hddTestStatus)
                hddStatus.truncate(hddTestStatus.length)
                exit
            end

            selfHealthTest = `sudo smartctl -H /dev/sda | grep overall | sed 's/.*: //'`.chomp
            if selfHealthTest != 'PASSED'
                puts 'FAILED AT HEALTH CHECK'
                hddTestStatus = false.passfail
                hddStatus.rewind
                hddStatus.write(hddTestStatus)
                hddStatus.truncate(hddTestStatus.length)
                exit
            end

            seekTestResults = system('sudo seeker /dev/sda')
            if seekTestResults == false
                hddStatus.rewind
                hddStatus.write(false.passfail)
                hddStatus.truncate(false.passfail.length)
            end

            hddStatus.rewind
            hddStatus.write(hddTestStatus)
            hddStatus.truncate(hddTestStatus.length)
            exit
        end
    else
        hddStatus.rewind
        hddStatus.write('ERROR: SMART Not Supported by Drive')
    end
else
    driveSize = ENV["SIZE"]
    memoryStatus = Tempfile.new('memStatus')
    memoryStatus.write('PASS')
    hddStatus = Tempfile.new('hddStatus')
    hddStatus.write('PASS')
  end

sysInfo = getSysInfo

get '/' do
    memoryStatus.rewind
    hddStatus.rewind
    erb :test, locals: {
        totalRam: totalRam,
        memoryStatus: memoryStatus.read,
        hddStatus: hddStatus.read,
        sysInfo: sysInfo,
        humanReadableSize: humanReadableSize
    }
end
get '/clone' do
    erb :clone, locals: {
        sysInfo: sysInfo
    }
end
get '/images' do
    erb :images, locals: {
        sysInfo: sysInfo,
        globalImageList: globalImageList,
        dir_listing: directory_hash(ENV['IMAGES_DIR'], nil, [])[:children],
        size: driveSize
    }
end

class Hash
    def nested_each_pair
        each_pair do |k, v|
            if v.is_a?(Hash)
                v.nested_each_pair { |k, v| yield k, v }
            else
                yield(k, v)
            end
        end
    end
end