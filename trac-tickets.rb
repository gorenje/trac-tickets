#!/usr/bin/ruby

# TODOS:
#  - Other reports have different sorting of fields in the CSV, this script assumes a specific
#    order (i.e. that of report 1)
#
require 'rubygems'
require 'fastercsv'
require 'optparse'
require 'fileutils'
require 'curb'
require 'activeresource'

class FasterCSV::Row  
  def to_row( overrides = { })
    # 060 does not limit the string to max 60, chars therefore the substring below.
    sprintf("#%03d - (%s) (%s) (%s) [%s] %s\n", 
            self["ticket"], 
            (overrides[:milestone]  || self["milestone"] || "").ljust(10, ' '), 
            (overrides[:component]  || self["component"]|| "").ljust(10, ' '), 
            (overrides[:owner]      || self["owner"]).ljust(7, ' '), 
            (overrides[:summary]    || self["summary"]).ljust(60, ' '),
            overrides[:description] || self["_description"])  
  end
end

def charlimit(str,to=50)
  str_len = (str || "").length
  str = (str ? str[0..(to-1)].gsub(/[\n\r]/," ") : "")
  str_len > to ? str.gsub(/...$/,"...") : str
end

def git_all_branches
  `git branch -a | colrm 1 2`.split(/\n/)
end

def git_exists?
  system('git branch 2>/dev/null >/dev/null')
end

def git_branch_name(idx, ticket)
  _,_,branch_name = (cnt, all_branches, branch_name_base = 
    1, git_all_branches, "tick%03d_%s" % [idx, ticket.gsub(/[^[:alpha:][:digit:]]/,'_')])
  while all_branches.include?(branch_name)
    branch_name = "%s.v%02d" % [branch_name_base, cnt += 1]
  end
  branch_name
end

def exit_if_ticket_not_open(ticket)
  if ticket.nil?
    puts 'ticket not open or not available'
    exit
  end
end

DEFAULT_PROJECT_SETTINGS = { 
  :user              => nil,         :password           => nil, 
  :server            => "localhost", :report_id  => 1,
  :ssl               => true,        :url_trac_prefix    => "trac",
  :quote_quotes      => false,       :get_login_cookie   => false,
  :path_regexp       => nil,         :component          => nil,

  :pivotal_api_token => nil,         :pivotal_project_id => nil,
  :pivotal_team_mapping => { },
  :pivotal_ticket_type_mapping => { 
    "task"        => "chore",
    "enhancement" => "feature",
    "defect"      => "bug",
  },
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
@quote_quotes    = false
@debug           = false
@filter          = /./
@notassigned     = false
@gitticket       = nil
@gitrename       = nil
@open_with_app   = nil
@post_to_pivotal = nil

opts = OptionParser.new do |o|
  o.program_name = 'ruby fb.rb'
  o.separator 'Options:'
  o.on('--project PROJECTNAME', '-p', 'Project name') { |@project_name| }
  o.on('--report REPORT_NUM',   '-r', 'Report id') { |@report_id| }
  o.on('--password PASSWORD',   '-u', 'Report id') { |@password| }
  o.on('--quote-quotes',        '-q', 'Report id') { @quote_quotes = true }
  o.on('--debug',               '-d', 'activate debug') { @debug   = true }
  
  o.on('--gitrename NUM',       '-m', 'rename current git branch to ticket') {|@gitrename| }
  o.on('--branch NUM',          '-b', 'create a git branch for ticket num') { |@gitticket| }
  o.on('--show-ticket NUM',     '-s', 'show all info on ticket. Comma separated') do |t| 
    @show_tickets << t.split(',').collect { |a| a.to_i }
  end
  o.on('--filter-on REGEXP',    '-f', 'filter string') { |a| @filter = eval a }
  o.on('--not-assigned',        '-x', 'show tickets that are not assigned') { |@notassigned| }
  o.on('--open APP',            '-o', 'open ticket with the app. App is passed the URL of the ticket') {  |@open_with_app| }
  o.on('--safari',            nil, 'Open tickets with Safari') { @open_with_app = "Safari" }
  o.on('--only-tickets NUM',    '-t', 'show only these ticket numbers. good in combinatin with open') do |tickets|
    @filter = eval(t=("/^#(%s)/" % tickets.split(',').
                   collect {|a| "%03d" % a.to_i }.join('|')))
  end
  o.on('--make-story NUM,NUM,...', '-v', 'make a story out of the ticket') do |t| 
    @show_tickets << t.split(',').collect { |a| a.to_i } unless t.empty?
    @post_to_pivotal = true
  end
  
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

TRAC_BASE_URL = 
  ("http%s://%s/%s" % [opts[:ssl] ? 's' : '',opts[:server], opts[:url_trac_prefix]])

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

browser = Curl::Easy.new("") do |curl|
  curl.verbose = @debug
  curl.timeout = 10
  curl.enable_cookies = true
  curl.http_auth_types = Curl::CURLAUTH_BASIC
  curl.userpwd = "%s:%s" % [opts[:user], @password] if opts[:user]
  curl.ssl_verify_peer = curl.ssl_verify_host = false
end

if opts[:get_login_cookie]
  browser.url = "%s/login" % TRAC_BASE_URL
  browser.perform
end

browser.url = ("%s/report/%d?format=csv" % [TRAC_BASE_URL,report_id])
puts browser.url if @debug
tickets,summaries,ticket_rows = [],[],[]

@quote_quotes = @quote_quotes || opts[:quote_quotes]
# incase descriptoin or summary contain a double-quote (which faster csv assumes 
# is a quote char) replace it with a single quote.
# It seems that trac does not escape nor escape itself therefore double quotes will
# not appear in trac CSV. .gsub(/"/,"'")
browser.perform
content = browser.body_str
@quote_quotes ? content.gsub!(/"/,"'") : nil
puts content.split("\n")[0] if @debug

FasterCSV.parse( content, :headers => true).each do |row|
  puts row if @debug
  idx, ov = row["ticket"].to_i, { }
  unless @show_tickets.empty?
    if @show_tickets.include?(idx)
      ticket_rows[idx], tickets[idx] = row.dup, row.to_row 
    end
  else
    ov[:description] = charlimit(row["_description"], 50)
    ov[:component]   = charlimit(row["component"], 10)
    ov[:milestone]   = charlimit(row["milestone"], 10)
    summaries[idx]   = ov[:summary]     = charlimit(row["summary"], 60)
    ov[:owner]       = charlimit((row["owner"].nil? || row["owner"]=="somebody") ? "" : \
                                                                        row["owner"],7)
    next if @component_filter and @component_filter != row["component"]
    line = row.to_row(ov)
    next unless @filter.match(line)
    
    tickets[idx], ticket_rows[idx] = if @notassigned 
                                       if ov[:owner].empty?
                                         [line,row.dup]
                                       else
                                         [nil,nil]
                                       end
                                     else
                                       [line,row.dup]
                                     end
  end
end

cnt=0
puts "====>>> Active Tickets for: #{@project_name} <<<===="
tickets.compact.each do |line| 
  cnt+=1
  puts line
  # rather unfortunate but this is now the only way to get the ticket number
  system("open -a %s %s/ticket/%s" % [@open_with_app, TRAC_BASE_URL,
                                      $1]) if !@open_with_app.nil? and (line =~ /^.(...)/)
end
puts "====>>> Tickets for: %s Total %d <<<====" % [@project_name, cnt]

## git stuff. either check out with new branch or rename current branch.
if @gitticket and git_exists?
  idx = @gitticket.to_i
  ticket = summaries[idx]
  exit_if_ticket_not_open(ticket)
  `git co -b #{git_branch_name(idx,ticket)}`
  exit
end

if @gitrename and git_exists?
  idx = @gitrename.to_i
  ticket = summaries[idx]
  exit_if_ticket_not_open(ticket)
  `git branch -m #{git_branch_name(idx,ticket)}`
  exit
end

if @post_to_pivotal
  # create the required story class
  eval(<<-EOF % [opts[:pivotal_project_id], opts[:pivotal_api_token]])
    class Story < ActiveResource::Base
      self.site = "http://www.pivotaltracker.com/services/v2/projects/%s"
      headers['X-TrackerToken'] = '%s'
    end
  EOF

  ticket_rows.compact.each do |ticket|
    story = Story.
      create({ 
        :requested_by => opts[:pivotal_team_mapping][ticket["owner"]],
        :estimate     => ticket["points"],
        #:story_type   => opts[:pivotal_ticket_type_mapping][ticket["type"]],
        :name         => ticket["summary"],
        :project_id   => opts[:pivotal_project_id],
        :description  => "%s\n\nReference: %s/ticket/%s" % [ticket["_description"],
                                                           TRAC_BASE_URL, 
                                                           ticket["ticket"]],
      })
    puts "Ticket %s was %ssaved" % [ ticket["ticket"], story.save ? "" : "not "]
  end
end
