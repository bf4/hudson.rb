require 'rubygems'
require 'grit'
include Grit

####  Wanna add a job manually?  drop into irb in this directory 
#
# app = "Express"
# branch = "master"
#
# require 'branch_watcher'
# MetromixProject.init_projects
# builder = HudsonJobBuilder.new
# project = MetromixProject.all_projects.detect {|project| project.name == app}
# # Now add a job for that branch to that project 
# builder.build_job_for(project, branch)
#
# Other notes
# project.job_name("master") returns e.g. Affiliate master
# builder.current_hudson_jobs # see current jobs if you want
#
class MetromixProject
  
  attr_accessor :name, :directory, :ruby, :gemset 
  
  PROJECT_DATA = [
    ["Express", "metromix-express", "ruby-1.8.6-p399"],
    ["Deals", "deals", "ruby-1.8.6-p399"],
    ["Deals Management", "deals-mgmt", "ruby-1.8.6-p399"],
    ["Affiliate", "metromix.com", "ruby-1.8.6-p399"],
    ["URN", "urn_identifiable", "ruby-1.8.6-p399"]
  ]
  
  class << self
    def init_projects
      @projects = PROJECT_DATA.map do |name, dir, ruby| 
        MetromixProject.new(name, dir, ruby) 
      end
      @project_hash = {}
      @projects.each do |project|
        @project_hash[project.name] = project
      end
    end
    
    def all_projects
      @projects
    end
    
    def by_name(name)
      @project_hash[name]
    end
    
  end
  
  def initialize(name, directory, ruby)
    @name = name
    @directory = directory
    @ruby = ruby
  end
  
  def rvm_string
    "#{ruby}@#{directory}"
  end
  
  def dir_name
    "/Users/continuum/Sites/#{directory}"
  end
  
  def repo
    @repo ||= Repo.new(dir_name)
  end
  
  def github_url
    "git@github.com:metromix/#{directory}.git"
  end
  
  def set_rvmrc
    `rm .rvmrc*`
    `rvm --create --rvmrc "#{rvm_string}"`
  rescue Exception => e
    puts "Failed to set rvmrc, error #{e.message}"
  end
 
  def delete_gemfile_lock
    puts "Deleting Gemfile.lock"
    `rm -rf Gemfile.lock`
  rescue Exception => e
    puts "Failed deleting Gemfile.lock. Did you delete it already? Error: #{e.message}"
  end

  def active_branches
    @active_branches ||= begin
      p dir_name
      Dir.chdir(dir_name) do
        `git remote prune origin`
        `git pull`
        set_rvmrc
        delete_gemfile_lock
      end
      result = []
      repo.remotes.each do |remote|
        next if remote.commit.id == "ref:"
        last_commit = remote.commit.committed_date
        days_ago = (Time.now - last_commit) / (60 * 60 * 24)
        p "#{remote.name.to_s} #{days_ago}" 
        result << remote.name.to_s.split("/")[-1] if days_ago < 10
      end
      result
    end
  end
  
  def active?(branch)
    active_branches.include?(branch)
  end
  
  def job_name(branch)
    "#{name} #{branch}"
  end
  
end

class HudsonJobBuilder
  
  def current_hudson_jobs
    @current_hudson_jobs ||= begin
      response = `hudson list --port 3001 --nocolor`
      result = response.split("\n").select { |l| l[0,1] == "*" }
      result.map { |s| s[2..-1] }
    end
  end
  
  def build_jobs_for(project)
    project.active_branches.each do |branch|
      build_job_for(project, branch)
    end
  end
  
  def remove_jobs
    current_hudson_jobs.each do |job_name|
      project_branch = job_name.split[-1]
      project_name = job_name.split[0 .. -2].join(" ")
      project = MetromixProject.by_name(project_name)
      next if project.nil?
      unless project.active?(project_branch)
        p "removing branch #{project_branch} of #{project_name}"
        result = `hudson remove "/Users/continuum/.hudson/server/jobs/#{job_name}"`
        p result
      end
    end
  end
  
  def build_job_for(project, branch)
    job_name = project.job_name(branch)
    if current_hudson_jobs.include?(job_name)
      p "#{job_name} already exists"
    else
      p "About to build a job for #{job_name}"
      `hudson create "#{project.dir_name}" --name "#{job_name}"  --port 3001 --scm #{project.github_url} --template metromix --scm-branches #{branch} --gemset #{project.rvm_string} --email dev@metromix.com`
    end
  end

  # wouldn't it be nice if these worked? -BF
  # def params
  #   "#{hudson_sounds} #{hudson_speaks}"
  # end
 
  # def hudson_sounds
  #   #%q%--net-hurstfrost-hudson-sounds-HudsonSoundsNotifier {"soundEvents": [{"toResult": "SUCCESS", "fromNotBuilt": false, "fromAborted": false, "fromFailure": false, "fromUnstable": false, "fromSuccess": true, "soundId": "alleluia"}, {"toResult": "SUCCESS", "fromNotBuilt": false, "fromAborted": false, "fromFailure": false, "fromUnstable": true, "fromSuccess": false, "soundId": "jamesbrown"}, {"toResult": "FAILURE", "fromNotBuilt": false, "fromAborted": false, "fromFailure": false, "fromUnstable": false, "fromSuccess": true, "soundId": "argh"}, {"toResult": "FAILURE", "fromNotBuilt": false, "fromAborted": false, "fromFailure": true, "fromUnstable": false, "fromSuccess": false, "soundId": "sad_trombone"}]}%
  # end

  # def hudson_speaks
  #   #%q%--net-hurstfrost-hudson-speaks-HudsonSpeaksNotifier {"speaks_projectTemplate": "<j:choose>\n<j:when test=\"${build.result!='SUCCESS' || build.project.lastBuild.result!='SUCCESS'}\">\nYour attention please. Project ${build.project.name}, build number ${build.number}: ${build.result} in ${duration}.\n<j:if test=\"${build.result!='SUCCESS'}\"> Get fixing those bugs team!</j:if>\n</j:when>\n<j:otherwise><!-- Say nothing --></j:otherwise>\n</j:choose>"}% 
  # end
  
end



if __FILE__ == $0
  MetromixProject.init_projects
  builder = HudsonJobBuilder.new
  builder.remove_jobs
  MetromixProject.all_projects.each do |project| 
   builder.build_jobs_for(project)
  end
end



