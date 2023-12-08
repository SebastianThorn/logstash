ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..'))
$LOAD_PATH.unshift File.join(ROOT, 'logstash-core/lib')
FIXTURES_DIR = File.expand_path(File.join("..", "..", "fixtures"), __FILE__)

require 'logstash/version'
require 'json'
require 'stud/try'
require 'docker-api'
require_relative '../patches/excon/unix_socket'
require 'pry'

def version
  #@version ||= LOGSTASH_VERSION
  "8.11.1"
end

def qualified_version
  qualifier = ENV['VERSION_QUALIFIER']
  qualified_version = qualifier ? [version, qualifier].join("-") : version
  ENV["RELEASE"] == "1" ? qualified_version : [qualified_version, "SNAPSHOT"].join("-")
end

def find_image(flavor)
  Docker::Image.all.detect {
      |image| image.info['RepoTags'].detect {
        #|tag| tag == "docker.elastic.co/logstash/logstash-#{flavor}:#{qualified_version}"
        |tag| tag == "docker.elastic.co/sscs/logstash-cgr:20231208-pr-8"
    }}
end

def create_container(image, options = {})
  image.run(nil, options)
end

def start_container(image, options = {})
  container = create_container(image, options)
  wait_for_logstash(container)
  container
end

def wait_for_logstash(container)
  Stud.try(40.times, [NoMethodError, Docker::Error::ConflictError, RSpec::Expectations::ExpectationNotMetError, TypeError]) do
    expect(logstash_available?(container)).to be true
    expect(get_logstash_status(container)).to eql 'green'
  end
end

def wait_for_pipeline(container, pipeline = 'main')
  Stud.try(40.times, [NoMethodError, Docker::Error::ConflictError, RSpec::Expectations::ExpectationNotMetError, TypeError]) do
    expect(pipeline_stats_available?(container, pipeline)).to be true
  end
end

def cleanup_container(container)
  unless container.nil?
    begin
      container.stop
    ensure
      container.delete(:force => true)
    end
  end
end

def license_label_for_flavor(flavor)
  flavor.match(/oss/) ? 'Apache 2.0' : 'Elastic License'
end

def license_agreement_for_flavor(flavor)
  flavor.match(/oss/) ? 'Apache License' : 'ELASTIC LICENSE AGREEMENT!'
end

def get_logstash_status(container)
  make_request(container, 'curl -s http://localhost:9600/')['status']
end

def get_node_info(container)
  make_request(container, 'curl -s http://localhost:9600/_node/')
end

def get_node_stats(container)
  make_request(container, 'curl -s http://localhost:9600/_node/stats')
end

def get_pipeline_setting(container, property, pipeline = 'main')
  make_request(container, "curl -s http://localhost:9600/_node/pipelines/#{pipeline}")
          .dig('pipelines', pipeline, property)
end

def get_pipeline_stats(container, pipeline = 'main')
  make_request(container, "curl -s http://localhost:9600/_node/stats/pipelines").dig('pipelines', pipeline)
end

def get_plugin_info(container, type, id, pipeline = 'main')
  pipeline_info = make_request(container, "curl -s http://localhost:9600/_node/stats/pipelines")
  all_plugins = pipeline_info.dig('pipelines', pipeline, 'plugins', type)
  if all_plugins.nil?
    # This shouldn't happen, so if it does, let's figure out why
    puts container.logs(stdout: true)
    puts "Unable to find plugins from #{pipeline_info}, when looking for #{type} plugins in #{pipeline}"
    return nil
  end
  all_plugins.find {|plugin| plugin['id'] == id}
end

def logstash_available?(container)
  response = exec_in_container_full(container, 'curl -s http://localhost:9600')
  return false if response[:exitcode] != 0
  !(response[:stdout].nil? || response[:stdout].empty?)
end

def pipeline_stats_available?(container, pipeline)
  response = make_request(container, "curl -s http://localhost:9600/_node/stats/pipelines")
  plugins = response.dig('pipelines', pipeline, 'plugins')
  !(plugins.nil? || plugins.empty?)
end

def make_request(container, url)
  JSON.parse(exec_in_container(container, url))
end

def get_settings(container)
  YAML.load(container.read_file('/usr/share/logstash/config/logstash.yml'))
end

def java_process(container, column)
  lspid = exec_in_container(container, "pgrep java")

  lsuidresp = exec_in_container(container, "grep Uid: /proc/#{lspid}/status")
  lsuid = lsuidresp.split(/[ \t]+/)[1]

  lsgidresp = exec_in_container(container, "grep Gid: /proc/#{lspid}/status")
  lsgid = lsgidresp.split(/[ \t]+/)[1]

  lsusernameresp = exec_in_container(container, "grep #{lsuid} /etc/passwd")
  lsusername = lsusernameresp.split(/:/)[0]

  lsgroupnameresp = exec_in_container(container, "grep #{lsgid} /etc/group")
  lsgroupname = lsgroupnameresp.split(/:/)[0]

  lsargs = exec_in_container(container, "cat /proc/#{lspid}/cmdline")

  if column == "user" then
    return lsusername
  elsif column == "group" then
    return lsgroupname
  elsif column == "args" then
    return lsargs
  elsif column == "pid" then
    return lspid
  end
end

# Runs the given command in the given container. This method returns
# a hash including the `stdout` and `stderr` outputs and the exit code
def exec_in_container_full(container, command)
  response = container.exec(command.split)
  {
      :stdout => response[0],
      :stderr => response[1],
      :exitcode => response[2]
  }
end

# Runs the given command in the given container. This method returns
# only the stripped/chomped `stdout` output.
def exec_in_container(container, command)
  exec_in_container_full(container, command)[:stdout].join.chomp.strip
end

def running_architecture
    architecture = ENV['DOCKER_ARCHITECTURE']
    architecture = normalized_architecture(`uname -m`.strip) if architecture.nil?
    architecture
end

def normalized_architecture(cpu)
  case cpu
  when 'x86_64'
    'amd64'
  when 'aarch64'
    'arm64'
  else
    cpu
  end
end

RSpec::Matchers.define :have_correct_license_label do |expected|
  match do |actual|
    values_match? license_label_for_flavor(expected), actual
  end
  failure_message do |actual|
    "expected License:#{actual} to eq #{license_label_for_flavor(expected)}"
  end
end

RSpec::Matchers.define :have_correct_license_agreement do |expected|
  match do |actual|
    values_match? /#{license_agreement_for_flavor(expected)}/, actual
    true
  end
  failure_message do |actual|
    "expected License Agreement:#{actual} to contain #{license_agreement_for_flavor(expected)}"
  end
end

RSpec::Matchers.define :have_correct_architecture do
  match do |actual|
    values_match? running_architecture, actual
  end
  failure_message do |actual|
    "expected Architecture: #{actual} to be #{running_architecture}"
  end
end

shared_context 'image_context' do |flavor|
  before do
    @image = find_image(flavor)
    @image_config = @image.json['Config']
    @labels = @image_config['Labels']
  end
end
