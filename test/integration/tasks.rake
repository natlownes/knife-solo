class EC2IntegrationTest
  KEY_FILE = "#{ENV['HOME']}/.ssh/knife-solo.pem"

  attr_accessor :type, :info

  def self.run(type, info)
    Thread.start do
      EC2IntegrationTest.new(type, info).run
    end
  end

  def initialize(type, info)
    @type = type
    @info = info
  end

  def compute
    @compute ||= Fog::Compute.new({:provider => 'AWS',
                                   :aws_access_key_id => ENV['AWS_ACCESS_KEY'],
                                   :aws_secret_access_key => ENV['AWS_SECRET_KEY']})
  end

  def run
    begin
      puts "Starting test run for #{type}..."
      server = compute.servers.create(:image_id => info[:image_id],
                                      :flavor_id => 'm1.small',
                                      :key_name => "knife-solo")
      server.wait_for { ready? }
      puts "Server reported ready, trying to connect to ssh..."
      server.wait_for {
        `nc #{server.public_ip_address} 22 -w 1 -q 0 </dev/null`
        $?.success?
      }
      puts "Sleeping 10s to avoid Net::SSH locking up by connecting too early..."
      puts "  (if you know a better way, please send me a note at https://github.com/matschaffer/knife-solo)"
      sleep 10
      Dir.chdir KITCHEN do
        prepare(info[:user], server)
        cook(info[:user], server)
      end
    ensure
      if server && ENV['SKIP_DESTROY'] != "true"
        puts "Destroying #{server}"
        server.destroy
      end
    end
  end

  def prepare(user, server)
    system "knife prepare -i #{KEY_FILE} #{user}@#{server.public_ip_address}"
  end

  def cook(user, server)
    system "knife cook -i #{KEY_FILE} #{user}@#{server.public_ip_address}"
  end
end

namespace :test do
  KITCHEN = "test/integration/kitchen"
  # TODO (mat): include AMI that uses root login and omits sudo (ala Centos 5.5 minimal install)
  AMIS = {
    'Ubuntu 10.04' => {
      :user => 'ubuntu',
      :image_id => 'ami-6936fb00'
    },
    'SUSE Linux Enterprise Server 11 32-bit' => {
      :user     => "root",
      :image_id => "ami-e0a35789"
    }
  }

  file KITCHEN do
    system "knife kitchen #{KITCHEN}"
  end

  namespace :integration do
    task :preflight do
      message = StringIO.new
      message.puts " - AWS_ACCESS_KEY environment variable must be set to your AWS access key" unless ENV['AWS_ACCESS_KEY']
      message.puts " - AWS_SECRET_KEY environment variable must be set to your AWS secret key" unless ENV['AWS_SECRET_KEY']
      if File.exist?(EC2IntegrationTest::KEY_FILE)
        File.new(EC2IntegrationTest::KEY_FILE).chmod(0600)
      else
        message.puts " - Create an EC2 keypair called knife-solo and place the private key at #{EC2IntegrationTest::KEY_FILE}"
      end
      raise message.string unless message.string.empty?
    end
  end

  desc "Run integration tests (requires EC2)"
  task :integration => ['integration:preflight', 'test/integration/kitchen'] do
    require 'bundler'
    Bundler.require(:test)
    require 'socket'

    if type = ENV['SYSTEM']
      EC2IntegrationTest.new(type, AMIS[type]).run
    else
      AMIS.map do |type, info|
        EC2IntegrationTest.run(type, info)
      end.each do |thread|
        thread.join
      end
    end
  end
end
