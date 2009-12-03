#!/usr/bin/ruby

# TODOS:
#  - Other reports have different sorting of fields in the CSV, this script assumes a specific
#    order (i.e. that of report 1)
#
require 'rubygems'
require 'fastercsv'
require 'optparse'
require 'fileutils'
require 'activeresource'

def git_all_branches
  `git branch -a | colrm 1 2`.split(/\n/)
end

def git_exists?
  system('git branch 2>/dev/null >/dev/null')
end

def git_branch_name(idx, story)
  _,_,branch_name = (cnt, all_branches, branch_name_base = 
    1, git_all_branches, "story%03d_%s" % [idx, 
                                           story.name.gsub(/[^[:alpha:][:digit:]]/,'_')])
  while all_branches.include?(branch_name)
    branch_name = "%s.v%02d" % [branch_name_base, cnt += 1]
  end
  branch_name
end

def exit_if_story_not_open(story)
  if story.nil?
    puts 'story not open or not available'
    exit
  end
end

DEFAULT_PROJECT_SETTINGS = { 
  :user              => nil,         :password           => nil, 
  :server            => "localhost", :report_id  => 1,
  :ssl               => true,        :url_trac_prefix    => "trac",
  :path_regexp       => nil,         :component          => nil,
  :pivotal_api_token => nil,         :pivotal_project_id => nil,
}

# before merging the default values, need to convert the keys to symbols.
PROJECTS = (c=YAML.load(File.open(File.expand_path("~/.trac-tickets")).read)).
  inject({}) do |t, (key,value)| 
  key == "default_project" ? t : t.merge!(key => DEFAULT_PROJECT_SETTINGS.merge(value))
end
DEFAULT_PROJECT=c["default_project"]

@project_name    = nil
@report_id       = nil
@password        = nil
@show_tickets    = [] # this is actually show ticket details
@debug           = false
@filter          = /./
@notassigned     = false
@gitticket       = nil
@gitrename       = nil
@open_with_app   = nil

opts = OptionParser.new do |o|
  o.program_name = 'ruby pivotal-tickets.rb'
  o.separator 'Options:'
  o.on('--project PROJECTNAME', '-p', 'Project name') { |@project_name| }
  o.on('--report REPORT_NUM',   '-r', 'Report id') { |@report_id| }
  o.on('--password PASSWORD',   '-u', 'Report id') { |@password| }
  o.on('--debug',               '-d', 'activate debug') { @debug   = true }
  
  o.on('--gitrename NUM',       '-m', 'rename current git branch to ticket') {|@gitrename| }
  o.on('--branch NUM',          '-b', 'create a git branch for ticket num') { |@gitticket| }
#   o.on('--show-ticket NUM',     '-s', 'show all info on ticket. Comma separated') do |t| 
#     @show_tickets << t.split(',').collect { |a| a.to_i }
#   end
#   o.on('--filter-on REGEXP',    '-f', 'filter string') { |a| @filter = eval a }
#   o.on('--not-assigned',        '-x', 'show tickets that are not assigned') { |@notassigned| }
  o.on('--open APP',            '-o', 'open ticket with the app. App is passed the URL of the ticket') {  |@open_with_app| }
  o.on('--safari',            nil, 'Open tickets with Safari') { @open_with_app = "Safari" }
#   o.on('--only-tickets NUM',    '-t', 'show only these ticket numbers. good in combinatin with open') do |tickets|
#     @filter = eval(t=("/^#(%s)/" % tickets.split(',').
#                    collect {|a| "%03d" % a.to_i }.join('|')))
#   end
  
  o.on_tail('--help', '-h', 'Show this message') do
    puts opts
    exit
  end
end

opts.parse!(ARGV)
@show_tickets.flatten!

# if no project name was given on the command line, then try to work it out according to
# the current path. If that isn't possible, use the default project
@project_name ||= begin
  when_stmts = PROJECTS.collect do |key, value|
    "when #{value[:path_regexp]} then '#{key}'" unless value[:path_regexp].nil?
  end.join("\n")
  eval(<<-EOF)
    case FileUtils.pwd
      #{when_stmts}
    else
      DEFAULT_PROJECT
    end
  EOF
end
opts = PROJECTS[@project_name]
raise "No project specified" if opts.nil? || opts.empty?

@component_filter = opts[:component]
@password = @password || opts[:password]

# if password wasn't defined in the options and wasn't set on the command line,
# then prompt for one IFF we have a username
if opts[:user] && @password.nil?
  printf(STDERR, "[#{@project_name}] Password: ") ; STDERR.flush
  system "stty -echo"
  @password = STDIN.readline.strip
  system "stty echo"
end

report_id = @report_id || opts[:report_id]

tickets,summaries,ticket_rows = [],[],[]

# incase descriptoin or summary contain a double-quote (which faster csv assumes 
# is a quote char) replace it with a single quote.
# It seems that trac does not escape nor escape itself therefore double quotes will
# not appear in trac CSV. .gsub(/"/,"'")
puts content.split("\n")[0] if @debug

module ToOutput
  def charlimit(str,to=50)
    str_len = (str || "").length
    str = (str ? str[0..(to-1)].gsub(/[\n\r]/," ") : "")
    str_len > to ? str.gsub(/...$/,"...") : str
  end

  def to_row( overrides = { })
    # 060 does not limit the string to max 60, chars therefore the substring below.
    sprintf("#%07d - (%s) (%s) (%s) [%s] %s\n", 
      self.id, 
      charlimit((overrides[:milestone]  || self.current_state|| ""),10) .ljust(10, ' '), 
      charlimit((overrides[:component]  || self.story_type|| ""),8).ljust(8, ' '), 
      charlimit((overrides[:owner]      || self.requested_by || ""),9).ljust(9, ' '), 
      charlimit((overrides[:summary]    || self.name || ""),60).ljust(60, ' '),
      charlimit(overrides[:description] || self.description), 50)
  end
end

PT_BASE_URL = "http://www.pivotaltracker.com"
# create the required story class
["Story", "Note", "Task"].each do |class_name|
  eval(<<-EOF % [opts[:pivotal_project_id], opts[:pivotal_api_token]])
    class #{class_name} < ActiveResource::Base
      self.site = "#{PT_BASE_URL}/services/v2/projects/%s"
      headers['X-TrackerToken'] = '%s'
    end
  EOF
end
Story.send(:include, ToOutput)

puts "====>>> Active Story for: #{@project_name} <<<===="
(stories = Story.
 find(:all, :params => {:project_id => opts[:pivotal_project_id]}).
 select do |story|
   true
 end).each do |story|
  y story if @debug
  puts story.to_row
  system("open -a %s %s/stories/%s" % [@open_with_app, 
                                       PT_BASE_URL, story.id]) if !@open_with_app.nil?

end

cnt=0
puts "====>>> Tickets for: %s Total %d <<<====" % [@project_name, stories.size]

## git stuff. either check out with new branch or rename current branch.
if @gitticket and git_exists?
  idx = @gitticket.to_i
  story = Story.find(idx, :params => {:project_id => opts[:pivotal_project_id]})
  exit_if_story_not_open(story)
  `git co -b #{git_branch_name(idx,story)}`
  exit
end

if @gitrename and git_exists?
  idx = @gitrename.to_i
  story = Story.find(idx, :params => {:project_id => opts[:pivotal_project_id]})
  exit_if_story_not_open(story)
  `git branch -m #{git_branch_name(idx,story)}`
  exit
end

