#! /usr/bin/env ruby

require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'lib/github'

include BioGemInfo::GitHub

IS_NEW_IN_DAYS = 7*6   # 6 weeks

is_testing = ARGV[0] == '--test'
is_rubygems = ARGV[0] == '--rubygems'
is_biogems = !is_rubygems

# list of biogems not starting with bio- (bio dash)
ADD = %w{ bio ruby-ensembl-api genfrag eutils dna_sequence_aligner intermine intermine-bio scaffolder biodiversity goruby sequenceserver 
}

print "# Generated by #{__FILE__} #{Time.now}\n"
print "# Using Ruby ",RUBY_VERSION,"\n"

projects = Hash.new

$stderr.print "Querying gem list\n"
list = []
if is_biogems
  if is_testing
    list = ['bio-logger', 'bio-nexml']
  else
    list = `gem list -r --no-versions bio-`.split(/\n/)
    prerelease = `gem search -r --prerelease --no-versions bio-`.split(/\n/)
    list += prerelease
    list += ADD
  end
end

if is_rubygems
  list = Dir.glob("./etc/rubygems/*.yaml").map { |fn| File.basename(fn).sub(/.yaml$/,'') }
end

# Return the working URL, otherwise nil
def check_url url
  if url =~ /^http:\/\/github/
    url = url.sub(/^http:\/\/github\.com/,"https://github.com")
  end
  if url =~ /^http:\/\//
    $stderr.print "Checking #{url}..."
    begin
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      if response.code.to_i == 200 and response.body !~ /301 Moved/
        $stderr.print "pass!\n"
        return url
      end
    rescue
      $stderr.print $!
    end
    $stderr.print "check_url failed!\n"
  end
  nil
end

def get_http_body url
  uri = URI.parse(url)
  $stderr.print "Fetching #{url}\n"
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(request)
  if response.code.to_i != 200
    $stderr.print "get_http_body not found for "+url
    return "{}"
  end
  response.body
end

def get_https_body url
  uri = URI.parse(url)
  $stderr.print "Fetching #{url}\n"
  https = Net::HTTP.new(uri.host, 443)
  https.use_ssl = true
  https.verify_mode = OpenSSL::SSL::VERIFY_PEER
  https.ca_path = '/etc/ssl/certs' if File.exists?('/etc/ssl/certs') # Ubuntu
  https.ca_file = '/opt/local/share/curl/curl-ca-bundle.crt' if File.exists?('/opt/local/share/curl/curl-ca-bundle.crt') # Mac OS X
  request = Net::HTTP::Get.new(uri.request_uri)
  response = https.request(request)
  if response.code.to_i != 200
    $stderr.print "get_https_body not found for "+url
    return "{}"
  end
  response.body
end

def get_versions name
  url = "http://rubygems.org/api/v1/versions/#{name}.json"
  versions = JSON.parse(get_http_body(url))
  versions
end

def get_downloads90 name, versions
  version_numbers = versions.map { | ver | ver['number'] }
  total = 0
  version_numbers.each do | ver |
    url="http://rubygems.org/api/v1/versions/#{name}-#{ver}/downloads.yaml"
    text = get_http_body(url)
    dated_stats = YAML::load(text)
    stats = dated_stats.map { | i | i[1] }
    ver_total90 = stats.inject {|sum, n| sum + n } 
    total += ver_total90 if ver_total90;
  end
  total
end

def get_github_commit_stats github_uri
  user,project = get_github_user_project(github_uri)
  url = "https://github.com/#{user}/#{project}/graphs/participation"
  $stderr.print url
  body = get_https_body(url)
  if body.strip == "" || body.nil? || body == "{}"
    # try once more
    body = get_https_body(url)
  end
  if body.strip == "" || body.nil?
    # data not retrieved, set safe default for JSON parsing
    body = "{}"
  end
  stats = JSON.parse(body)
  if stats.empty?
    return nil
  else
    return stats['all']
  end
end

def update_status(projects)
  for biogem in ['bio-biolinux','bio-core-ext','bio-core','bio'] do 
    $stderr.print "Getting status of #{biogem}\n"
    uri = URI.parse("http://rubygems.org/api/v1/gems/#{biogem}.yaml")
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    if response.code.to_i==200
      # print response.body       
      biogems = YAML::load(response.body)
      biogems["dependencies"]["runtime"].each do | runtime |
        n = runtime["name"]
        if projects[n]
          projects[n][:status] = biogem
        else
          $stderr.print "Warning: can not find #{n} for #{biogem}\n"
        end
      end
    else
      raise Exception.new("Response code for #{name} is "+response.code)
    end
  end
end

list.each do | name |
  $stderr.print name,"\n"
  info = Hash.new
  # Fetch the gem YAML definition of the project
  fetch = `bundle exec gem specification -r #{name.strip}`
  if fetch != ''
    spec = YAML::load(fetch)
    # print fetch
    # p spec
    ivars = spec.ivars
    info[:authors] = ivars["authors"]
    info[:summary] = ivars["summary"]
    ver = ivars["version"].ivars['version']
    info[:version] = ver
    info[:release_date] = ivars["date"] # can not fix the time, it comes from rubygems
    # set homepage
    info[:homepage] = ivars["homepage"]
    info[:licenses] = ivars["licenses"]
    info[:description] = ivars["description"]
  else
    info[:version] = 'pre'
    info[:status]  = 'pre'
  end
  # Query rubygems.org directly
  uri = URI.parse("http://rubygems.org/api/v1/gems/#{name}.yaml")
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(request)
  if response.code.to_i==200
    # print response.body       
    biogems = YAML::load(response.body)
    info[:downloads] = biogems["downloads"]
    info[:version_downloads] = biogems["version_downloads"]
    info[:gem_uri] = biogems["gem_uri"]
    info[:homepage_uri] = check_url(biogems["homepage_uri"])
    info[:project_uri] = check_url(biogems["project_uri"])
    info[:source_code_uri] = biogems["sourcecode_uri"]
    info[:docs_uri] = check_url(biogems["documentation_uri"])
    info[:dependencies] = biogems["dependencies"]
    # query for recent downloads
  else
    raise Exception.new("Response code for #{name} is "+response.code)
  end
  info[:docs_uri] = "http://rubydoc.info/gems/#{name}/#{ver}/frames" if not info[:docs_uri]
  versions = get_versions(name)
  info[:downloads90] = get_downloads90(name, versions)
  # if a gem is less than one month old, mark it as new
  if versions.size <= 5
    is_new = true
    versions.each do | ver |
      date = ver['built_at']
      date.to_s =~ /^(\d\d\d\d)\-(\d\d)\-(\d\d)/
      t = Time.new($1.to_i,$2.to_i,$3.to_i)
      if Time.now - t > IS_NEW_IN_DAYS*24*3600
        is_new = false
        break
      end
    end
    info[:status] = 'new' if is_new
  end
  # Now parse etc/biogems/name.yaml
  fn = "./etc/biogems/#{name}.yaml" if is_biogems
  fn = "./etc/rubygems/#{name}.yaml" if is_rubygems
  if File.exist?(fn)
    added = YAML::load(File.new(fn).read)
    added = {} if not added 
    info = info.merge(added)
  end
  # Replace http with https
  for uri in [:source_code_uri, :homepage, :homepage_uri, :project_uri] do
    if info[uri] =~ /^http:\/\/github/
      info[uri] = info[uri].sub(/^http:\/\/github\.com/,"https://github.com")
    end
  end

  # Check github issues
  # print info
  for uri in [:source_code_uri, :homepage, :homepage_uri, :project_uri] do
    if info[uri] =~ /^https:\/\/github\.com/
      info[:num_issues] = get_github_issues(info[uri]).size
      user,project = get_github_user_project(info[uri])
      info[:github_user] = user
      info[:github_project] = project
      info[:commit_stats] = get_github_commit_stats(info[uri])
      break if info[:num_issues] > 0
    end
  end

  projects[name] = info
end
# Read the status of bio-core, bio-core-ext and bio-biolinux
# packages
update_status(projects) if is_biogems

print projects.to_yaml
